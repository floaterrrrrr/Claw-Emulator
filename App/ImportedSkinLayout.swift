// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// A bounded preview raster in author coordinates. Core Graphics has a bottom-
// left origin; skin manifests use a top-left origin. No view transforms needed.
struct ImportedSkinPreviewLayout {
    let size: CGSize
    private let source: CGSize
    init?(width: Double, height: Double, maximumDimension: Int) {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 4096, height <= 4096, maximumDimension > 0 else { return nil }
        let limit = Double(min(1600, maximumDimension))
        let scale = limit / max(width, height)
        size = CGSize(width: max(1, (width * scale).rounded()), height: max(1, (height * scale).rounded()))
        source = CGSize(width: width, height: height)
    }
    func drawingRect(_ frame: SkinRect) -> CGRect {
        let x = size.width / source.width, y = size.height / source.height
        return CGRect(x: frame.x * x, y: size.height - (frame.y + frame.height) * y,
                      width: frame.width * x, height: frame.height * y)
    }
}

extension DeltaSkinVariant {
    // Preserve the entire authored canvas, including decorative edges and
    // controls. Edge-to-edge selects the physical display as the fitting area;
    // it must never mean aspect-fill, which clips the top/bottom on phones
    // whose aspect ratio differs from the author's device.
    func layout(in safe: CGRect, bounds: CGRect? = nil, mainAspect: CGFloat,
                hasSecondScreen: Bool, edgeToEdge: Bool = false) -> ControllerSkinLayout? {
        guard safe.width > 0, safe.height > 0, safe.width.isFinite, safe.height.isFinite,
              width > 0, height > 0, width.isFinite, height.isFinite,
              screens.count == (hasSecondScreen ? 2 : 1) else { return nil }
        let area = edgeToEdge ? (bounds ?? safe) : safe
        guard area.width > 0, area.height > 0, area.width.isFinite, area.height.isFinite else { return nil }
        let sourceWidth = CGFloat(width), sourceHeight = CGFloat(height)
        let fit = min(area.width / sourceWidth, area.height / sourceHeight)
        let scales = [fit]

        for scale in scales where scale.isFinite && scale > 0 {
            let canvas = CGRect(x: area.midX - sourceWidth * scale / 2,
                                y: area.midY - sourceHeight * scale / 2,
                                width: sourceWidth * scale, height: sourceHeight * scale)
            func converted(_ frame: SkinRect) -> CGRect {
                CGRect(x: canvas.minX + CGFloat(frame.x) * scale,
                       y: canvas.minY + CGFloat(frame.y) * scale,
                       width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale)
            }
            func fitted(_ frame: CGRect, _ aspect: CGFloat) -> CGRect {
                let w = min(frame.width, frame.height * aspect)
                return CGRect(x: frame.midX - w / 2, y: frame.midY - w / aspect / 2,
                              width: w, height: w / aspect)
            }
            let screenFrames = screens.map(converted)
            let top = fitted(screenFrames[0], mainAspect)
            let bottom = hasSecondScreen ? fitted(screenFrames[1], 4 / 3) : .zero

            // The first occurrence of a key is the primary hit target. Every
            // occurrence remains in importedFrames for artwork drawing.
            var frames: [String: CGRect] = [:]
            let importedFrames = controls.map { converted($0.frame) }
            for (control, frame) in zip(controls, importedFrames) where frames[control.key] == nil {
                frames[control.key] = frame
            }
            guard let dpad = frames["dpad"], let a = frames["a"], let b = frames["b"],
                  let start = frames["start"], let select = frames["select"] else { continue }
            var face = a.union(b)
            for key in ["x", "y"] { if let frame = frames[key] { face = face.union(frame) } }
            // A menu mapping is preferred. Valid skins that omit it still get
            // a reachable built-in menu in the safe-area corner.
            let gear = frames["menu"] ?? CGRect(x: safe.maxX - 48, y: safe.minY + 4,
                                                width: 44, height: 44)
            let quickSave = frames["save"] ?? .zero
            let quickLoad = frames["load"] ?? .zero
            let gameplay = GameplayLayout(landscape: area.width > area.height, top: top, bottom: bottom,
                circle: frames["circle"] ?? .zero, dpad: dpad, face: face,
                leftShoulder: frames["l"] ?? .zero, rightShoulder: frames["r"] ?? .zero,
                select: select, start: start, hud: .zero, gear: gear)

            let visible = area.insetBy(dx: -0.001, dy: -0.001)
            guard visible.contains(canvas), screenFrames.allSatisfy({ visible.contains($0) }),
                  importedFrames.allSatisfy({ visible.contains($0) }),
                  safe.contains(gear) || visible.contains(gear) else { continue }
            return ControllerSkinLayout(canvas: canvas, gameplay: gameplay,
                artFrames: frames, hitFrames: frames, quickSave: quickSave, quickLoad: quickLoad,
                importedFrames: importedFrames)
        }
        return nil
    }
}

#if canImport(UIKit)
import UIKit
import ImageIO
// Immutable decoded images are prepared off-main once per chosen skin, never
// during a frame update. UIKit only reads them for artwork and input feedback.
struct ImportedSkinSession: @unchecked Sendable {
    let variant: DeltaSkinVariant
    let images: [String: UIImage]
    // Whether the actual selected variant was an edge-to-edge canvas. A
    // standard fallback must stay fitted even on a tall phone.
    let edgeToEdge: Bool
    static func load(id: String, orientation: String, edgeToEdge: Bool) async throws -> ImportedSkinSession? {
        guard let definition = try await ImportedSkinStore.shared.load(id),
              let key = definition.variantKey(orientation: orientation, edgeToEdge: edgeToEdge),
              let variant = definition.variants[key] else { return nil }
        let usesEdgeToEdge = key.hasPrefix("edgeToEdge.")
        let directory = await ImportedSkinStore.shared.directory(id)
        return try await Task.detached(priority: .utility) {
            var images: [String: UIImage] = [:]
            for name in Set([variant.background] + variant.controls.compactMap(\.asset)) {
                let url = directory.appendingPathComponent(name)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                    throw SkinImportError("The selected skin is missing an image. Import it again.")
                }
                images[name] = UIImage(cgImage: cg)
            }
            return ImportedSkinSession(variant: variant, images: images, edgeToEdge: usesEdgeToEdge)
        }.value
    }
}
#endif
