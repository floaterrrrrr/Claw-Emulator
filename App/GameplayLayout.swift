// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

enum GameplayOrientation: String, CaseIterable, Identifiable {
    case automatic, landscape, portrait
    var id: String { rawValue }
    var title: String {
        switch self { case .automatic: return "Auto"; case .landscape: return "Landscape"; case .portrait: return "Portrait" }
    }
}

struct GameplayLayout: Equatable {
    let landscape: Bool
    let top, bottom, circle, dpad, face, leftShoulder, rightShoulder, select, start, hud, gear: CGRect

    static func make(in safe: CGRect, largerTouchScreen: Bool = false,
                     mainAspect: CGFloat = 5 / 3, hasSecondScreen: Bool = true) -> GameplayLayout {
        let landscape = safe.width > safe.height
        let b = safe.insetBy(dx: landscape ? 8 : 12, dy: 6)
        if landscape {
            let leftWidth = min(120, max(104, b.height * 0.30))
            let rightWidth = min(largerTouchScreen ? 160 : 144,
                                 max(132, b.height * (largerTouchScreen ? 0.42 : 0.36)))
            let center = CGRect(x: b.minX + leftWidth + 12, y: b.minY,
                                width: b.width - leftWidth - rightWidth - 24, height: b.height)
            // Fit the complete 5:3 main image into its own column. The touch
            // display uses the space below ABXY, never covers the main image.
            let mainArea = CGRect(x: center.minX, y: b.minY + 28,
                                  width: center.width, height: b.height - 80)
            let mainWidth = min(mainArea.width, mainArea.height * mainAspect)
            let mainHeight = mainWidth / mainAspect
            let top = CGRect(x: mainArea.midX - mainWidth / 2, y: mainArea.midY - mainHeight / 2,
                             width: mainWidth, height: mainHeight)
            let movement = min(leftWidth, (b.height - 68) / 2)
            let rightX = b.maxX - rightWidth
            let bottom = hasSecondScreen ? CGRect(x: rightX, y: b.maxY - rightWidth * 0.75,
                                width: rightWidth, height: rightWidth * 0.75) : .zero
            return GameplayLayout(landscape: true, top: top, bottom: bottom,
                circle: CGRect(x: b.minX + (leftWidth - movement) / 2, y: b.maxY - movement - 6, width: movement, height: movement),
                dpad: CGRect(x: b.minX + (leftWidth - movement) / 2, y: b.minY + 52, width: movement, height: movement),
                face: CGRect(x: rightX, y: b.minY + 52, width: rightWidth, height: rightWidth),
                leftShoulder: CGRect(x: b.minX, y: b.minY, width: leftWidth, height: 44),
                rightShoulder: CGRect(x: rightX, y: b.minY, width: rightWidth - 52, height: 44),
                select: CGRect(x: center.midX - 76, y: b.maxY - 44, width: 68, height: 44),
                start: CGRect(x: center.midX + 8, y: b.maxY - 44, width: 68, height: 44),
                hud: CGRect(x: center.minX, y: b.minY, width: center.width, height: 22),
                gear: CGRect(x: b.maxX - 44, y: b.minY, width: 44, height: 44))
        }
        let faceSide: CGFloat = 132
        let movement = min(136, max(60, (b.width - faceSide - 24) / 2))
        let controlsHeight: CGFloat = 44 + 12 + max(faceSide, movement) + 6
        let secondScale = hasSecondScreen ? (4 / 3) / mainAspect : 0
        let heightPerWidth = 1 / mainAspect + secondScale * 0.75
        let width = min(b.width, max(100, (b.height - 52 - 24 - controlsHeight) / heightPerWidth))
        let top = CGRect(x: b.midX - width / 2, y: b.minY + 52, width: width, height: width / mainAspect)
        let secondaryWidth = min(width, width * secondScale)
        let bottom = hasSecondScreen ? CGRect(x: b.midX - secondaryWidth / 2, y: top.maxY + 12,
                                              width: secondaryWidth, height: secondaryWidth * 0.75) : .zero
        let controlY = max((hasSecondScreen ? bottom.maxY : top.maxY) + 12, b.maxY - controlsHeight)
        return GameplayLayout(landscape: false, top: top, bottom: bottom,
            circle: CGRect(x: b.minX, y: controlY + 56, width: movement, height: movement),
            dpad: CGRect(x: b.minX + movement + 12, y: controlY + 56, width: movement, height: movement),
            face: CGRect(x: b.maxX - faceSide, y: controlY + 56, width: faceSide, height: faceSide),
            leftShoulder: CGRect(x: b.minX, y: controlY, width: 64, height: 44),
            rightShoulder: CGRect(x: b.maxX - 64, y: controlY, width: 64, height: 44),
            select: CGRect(x: b.midX - 76, y: controlY, width: 68, height: 44),
            start: CGRect(x: b.midX + 8, y: controlY, width: 68, height: 44),
            hud: CGRect(x: b.minX, y: b.minY, width: b.width - 52, height: 44),
            gear: CGRect(x: b.maxX - 44, y: b.minY, width: 44, height: 44))
    }
}

struct DPadAxes: Equatable {
    let horizontal, vertical: Int
    static func at(_ point: CGPoint, size: CGSize) -> DPadAxes {
        guard point.x.isFinite, point.y.isFinite, size.width > 0, size.height > 0 else {
            return DPadAxes(horizontal: 0, vertical: 0)
        }
        let x = (point.x / size.width - 0.5) * 2
        let y = (point.y / size.height - 0.5) * 2
        return DPadAxes(horizontal: x < -0.28 ? -1 : x > 0.28 ? 1 : 0,
                        vertical: y < -0.28 ? 1 : y > 0.28 ? -1 : 0)
    }
}
