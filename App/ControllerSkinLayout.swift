// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// One retained RGBA snapshot per gameplay controller, bounded to about 16 MiB.
// UIKit supplies displayScale; layout tests can verify the budget without an SDK.
enum SkinRasterBudget {
    static let maxPixels: CGFloat = 4_000_000
    static func scale(for size: CGSize, displayScale: CGFloat) -> CGFloat? {
        guard size.width.isFinite, size.height.isFinite, displayScale.isFinite,
              size.width > 0, size.height > 0, displayScale > 0 else { return nil }
        let area = size.width * size.height
        guard area.isFinite, area > 0 else { return nil }
        return min(displayScale, 3, sqrt(maxPixels / area))
    }
}

struct SkinRect: Codable, Sendable {
    let x, y, width, height: Double
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
struct SkinControl: Decodable {
    let key, asset: String
    let frame: SkinRect
}
struct ControllerSkin: Decodable {
    struct Size: Decodable { let width, height: Double }
    let name, creator, background: String
    let mappingSize: Size
    let screens: [SkinRect]
    let controls: [SkinControl]
    let quickSave, quickLoad: SkinRect

    static let bundled: ControllerSkin? = {
        guard let url = Bundle.main.url(forResource: "control-deck", withExtension: "json",
                                        subdirectory: "ControllerSkin"),
              let data = try? Data(contentsOf: url),
              let skin = try? JSONDecoder().decode(ControllerSkin.self, from: data),
              skin.isValid else { return nil }
        return skin
    }()
    var isValid: Bool {
        let keys = Set(controls.map(\.key))
        let required = Set(["circle", "dpad", "a", "b", "x", "y", "l", "r", "select", "start"])
        guard mappingSize.width.isFinite, mappingSize.height.isFinite,
              mappingSize.width > 0, mappingSize.height > 0, screens.count == 2,
              keys == required, controls.count == required.count else { return false }
        let canvas = CGRect(x: 0, y: 0, width: mappingSize.width, height: mappingSize.height)
        return (screens + controls.map(\.frame) + [quickSave, quickLoad]).allSatisfy {
            let r = $0.rect
            return r.minX.isFinite && r.minY.isFinite && r.width.isFinite && r.height.isFinite &&
                r.width > 0 && r.height > 0 && canvas.contains(r)
        }
    }
}

struct ControllerSkinLayout: Equatable {
    let canvas: CGRect
    let gameplay: GameplayLayout
    let artFrames: [String: CGRect]
    let hitFrames: [String: CGRect]
    let quickSave, quickLoad: CGRect
    // Imported skins may contain more than one visual region for the same
    // input. This array preserves every region in author order for drawing;
    // artFrames/hitFrames still provide one primary frame per gameplay control.
    let importedFrames: [CGRect]

    init(canvas: CGRect, gameplay: GameplayLayout, artFrames: [String: CGRect],
         hitFrames: [String: CGRect], quickSave: CGRect, quickLoad: CGRect,
         importedFrames: [CGRect] = []) {
        self.canvas = canvas
        self.gameplay = gameplay
        self.artFrames = artFrames
        self.hitFrames = hitFrames
        self.quickSave = quickSave
        self.quickLoad = quickLoad
        self.importedFrames = importedFrames
    }

    static func make(skin: ControllerSkin, in safe: CGRect, bounds: CGRect? = nil,
                     mainAspect: CGFloat = 5 / 3, hasSecondScreen: Bool = true,
                     largerTouchScreen: Bool = false, hasAnalog: Bool = true) -> ControllerSkinLayout? {
        let canvas = bounds ?? safe
        guard skin.isValid, safe.width.isFinite, safe.height.isFinite,
              safe.minX.isFinite, safe.minY.isFinite, canvas.contains(safe) else { return nil }
        if safe.width <= safe.height {
            return portrait(in: safe, canvas: canvas, mainAspect: mainAspect, hasSecondScreen: hasSecondScreen, hasAnalog: hasAnalog)
        }
        // The shell fills the physical display. Only interactive content avoids
        // the cutout and home indicator; fitting the entire old 896x414 drawing
        // inside that rectangle creates a second, unnecessary border on phones.
        let content = safe.insetBy(dx: 8, dy: 4)
        let leftWidth = min(104, max(100, content.height * 0.26))
        let rightWidth = min(largerTouchScreen ? 216 : 204,
                             max(largerTouchScreen ? 192 : 180, content.height * 0.51))
        let center = CGRect(x: content.minX + leftWidth + 8, y: content.minY,
                            width: content.width - leftWidth - rightWidth - 16, height: content.height)
        guard content.height >= 310, center.width >= 3 * 44 + 24 else { return nil }
        func fitted(_ area: CGRect, aspect: CGFloat) -> CGRect {
            let width = min(area.width, area.height * aspect), height = width / aspect
            return CGRect(x: area.midX - width / 2, y: area.midY - height / 2,
                          width: width, height: height)
        }
        let rightX = content.maxX - rightWidth
        let headerY = content.minY
        let movement = min(leftWidth, (content.height - 60) / 2)
        // One vertical centerline for both movement controls. Bias the stack
        // toward the outer edge as in the reference, keeping its hit areas safe.
        let movementCenterX = max(safe.minX + movement / 2 + 2,
                                  content.minX + leftWidth / 2 - 12)
        let movementX = movementCenterX - movement / 2
        // Group the two movement controls around the thumb's resting area,
        // instead of pinning one to the header and the other to the bottom.
        let movementGap: CGFloat = 24
        let movementY = headerY + 56 + max(0, (content.height - 68 - movement * 2 - movementGap) / 2)
        let bottomY = content.maxY - rightWidth * 0.75
        // Lower ABXY while preserving an 8pt gap above the enlarged touch
        // screen. Compact phones clamp the shift to avoid losing touch area.
        let controlsY = min(headerY + 76, bottomY - 132 - 8)
        let shoulderWidth = min(64, leftWidth - 48)
        // Independent of the touch screen size: larger touch artwork must not
        // push ABXY into it or shrink the physical buttons below 44pt.
        let faceButton: CGFloat = 44
        let face = CGRect(x: rightX + (rightWidth - 132) / 2, y: controlsY, width: 132, height: 132)
        var hits: [String: CGRect] = [
            "l": CGRect(x: content.minX, y: headerY, width: shoulderWidth, height: 44),
            "select": CGRect(x: content.minX + leftWidth - 44, y: headerY, width: 44, height: 44),
            "start": CGRect(x: rightX, y: headerY, width: 44, height: 44),
            "r": CGRect(x: content.maxX - 68, y: headerY, width: 68, height: 44),
            "dpad": CGRect(x: movementX, y: movementY,
                           width: movement, height: movement),
            "circle": CGRect(x: movementX, y: movementY + movement + movementGap,
                             width: movement, height: movement),
            "x": CGRect(x: face.minX + faceButton, y: controlsY, width: faceButton, height: faceButton),
            "y": CGRect(x: face.minX, y: controlsY + faceButton, width: faceButton, height: faceButton),
            "a": CGRect(x: face.minX + 2 * faceButton, y: controlsY + faceButton, width: faceButton, height: faceButton),
            "b": CGRect(x: face.minX + faceButton, y: controlsY + 2 * faceButton, width: faceButton, height: faceButton)
        ]
        if !hasAnalog {
            hits.removeValue(forKey: "circle")
            hits["dpad"] = CGRect(x: movementX, y: content.midY - movement / 2, width: movement, height: movement)
        }
        if !hasSecondScreen { compactAB(in: face, frames: &hits) }
        let mainArea = CGRect(x: center.minX, y: center.minY + 52,
                              width: center.width, height: content.height - 56)
        let top = fitted(mainArea, aspect: mainAspect)
        let bottom = hasSecondScreen ? CGRect(x: rightX, y: bottomY,
                            width: rightWidth, height: rightWidth * 0.75) : .zero
        let save = CGRect(x: center.maxX - 144, y: headerY, width: 44, height: 44)
        let gear = CGRect(x: center.maxX - 94, y: headerY, width: 44, height: 44)
        let load = CGRect(x: center.maxX - 44, y: headerY, width: 44, height: 44)
        let gameplay = GameplayLayout(landscape: true, top: top, bottom: bottom,
            circle: hits["circle"] ?? .zero, dpad: hits["dpad"]!, face: face,
            leftShoulder: hits["l"]!, rightShoulder: hits["r"]!,
            select: hits["select"]!, start: hits["start"]!,
            hud: CGRect(x: center.minX, y: center.minY, width: max(0, center.width - 152), height: 22), gear: gear)
        var targets = hits
        targets["topScreen"] = top
        if hasSecondScreen { targets["bottomScreen"] = bottom }
        targets["gear"] = gear; targets["quickSave"] = save; targets["quickLoad"] = load
        let frames = Array(targets)
        let circular = Set(["a", "b", "x", "y"])
        guard frames.allSatisfy({ safe.contains($0.value) }) else { return nil }
        for (index, target) in frames.enumerated() {
            for other in frames.dropFirst(index + 1) {
                let frame = target.value
                if circular.contains(target.key) && circular.contains(other.key) {
                    // Face buttons use circles, not overlapping 44pt squares.
                    let distance = hypot(frame.midX - other.value.midX, frame.midY - other.value.midY)
                    if distance < (frame.width + other.value.width) / 2 - 0.01 { return nil }
                    continue
                }
                let overlap = frame.intersection(other.value)
                if !overlap.isNull && overlap.width > 0.01 && overlap.height > 0.01 { return nil }
            }
        }
        return ControllerSkinLayout(canvas: canvas, gameplay: gameplay, artFrames: hits,
                                    hitFrames: hits, quickSave: save, quickLoad: load)
    }

    private static func compactAB(in area: CGRect, frames: inout [String: CGRect]) {
        let side: CGFloat = 56
        frames["a"] = CGRect(x: area.maxX - side, y: area.minY + 8, width: side, height: side)
        frames["b"] = CGRect(x: area.minX, y: area.maxY - side - 8, width: side, height: side)
        frames.removeValue(forKey: "x"); frames.removeValue(forKey: "y")
    }

    private static func portrait(in safe: CGRect, canvas: CGRect, mainAspect: CGFloat,
                                 hasSecondScreen: Bool, hasAnalog: Bool) -> ControllerSkinLayout? {
        guard safe.width >= 320, safe.height >= 560 else { return nil }
        // Fit screens into the space above a stable control deck and footer.
        // A 3DS pair keeps equal display heights (400:240 and 320:240), with
        // no stretching, and can grow now that gameplay hides the status bar.
        let content = safe.insetBy(dx: 12, dy: 6)
        let footerY = content.maxY - 44
        let save = CGRect(x: content.minX, y: footerY, width: 80, height: 44)
        let load = CGRect(x: content.maxX - 80, y: footerY, width: 80, height: 44)
        let gear = CGRect(x: content.midX - 22, y: footerY, width: 44, height: 44)
        let faceSide: CGFloat = 132
        let controlY = footerY - 12 - faceSide - 12 - 44
        let face = CGRect(x: content.maxX - faceSide, y: controlY + 56, width: faceSide, height: faceSide)
        let movement = min(100, (content.width - faceSide - 24) / 2)
        let circle = hasAnalog ? CGRect(x: content.minX, y: face.midY - movement / 2, width: movement, height: movement) : .zero
        let dpadSide = hasAnalog ? movement : min(132, content.width - faceSide - 12)
        let dpad = CGRect(x: hasAnalog ? circle.maxX + 12 : content.minX,
                          y: face.midY - dpadSide / 2, width: dpadSide, height: dpadSide)
        let screenArea = CGRect(x: content.minX, y: content.minY + 28,
                                width: content.width, height: controlY - 12 - content.minY - 28)
        let screenGap: CGFloat = hasSecondScreen ? 10 : 0
        let screenHeight = min(content.width / mainAspect, (screenArea.height - screenGap) / (hasSecondScreen ? 2 : 1))
        let topWidth = screenHeight * mainAspect
        let top = CGRect(x: content.midX - topWidth / 2,
                         y: screenArea.midY - (screenHeight * (hasSecondScreen ? 2 : 1) + screenGap) / 2,
                         width: topWidth, height: screenHeight)
        let bottom = hasSecondScreen ? CGRect(x: content.midX - screenHeight * (4 / 3) / 2,
                                              y: top.maxY + screenGap, width: screenHeight * (4 / 3), height: screenHeight) : .zero
        let leftShoulder = CGRect(x: content.minX, y: controlY, width: 64, height: 44)
        let rightShoulder = CGRect(x: content.maxX - 64, y: controlY, width: 64, height: 44)
        let select = CGRect(x: content.midX - 76, y: controlY, width: 68, height: 44)
        let start = CGRect(x: content.midX + 8, y: controlY, width: 68, height: 44)
        let gameplay = GameplayLayout(landscape: false, top: top, bottom: bottom,
            circle: circle, dpad: dpad, face: face,
            leftShoulder: leftShoulder, rightShoulder: rightShoulder,
            select: select, start: start,
            hud: CGRect(x: content.minX, y: content.minY, width: content.width, height: 22), gear: gear)
        let side = face.width / 3
        var hits: [String: CGRect] = [
            "circle": circle, "dpad": dpad,
            "l": leftShoulder, "r": rightShoulder,
            "select": select, "start": start,
            "x": CGRect(x: face.minX + side, y: face.minY, width: side, height: side),
            "y": CGRect(x: face.minX, y: face.minY + side, width: side, height: side),
            "a": CGRect(x: face.minX + 2 * side, y: face.minY + side, width: side, height: side),
            "b": CGRect(x: face.minX + side, y: face.minY + 2 * side, width: side, height: side)
        ]
        if !hasAnalog { hits.removeValue(forKey: "circle") }
        if !hasSecondScreen { compactAB(in: face, frames: &hits) }
        let targets = Array(hits.values) + [top, gear, save, load] + (hasSecondScreen ? [bottom] : [])
        guard targets.allSatisfy({ safe.contains($0) && $0.width >= 44 && $0.height >= 44 }) else { return nil }
        let occupied = targets + [gameplay.hud]
        for i in occupied.indices {
            for j in occupied.indices where j > i {
                let overlap = occupied[i].intersection(occupied[j])
                if !overlap.isNull && overlap.width > 0.01 && overlap.height > 0.01 { return nil }
            }
        }
        return ControllerSkinLayout(canvas: canvas, gameplay: gameplay, artFrames: hits,
                                    hitFrames: hits, quickSave: save, quickLoad: load)
    }
}
