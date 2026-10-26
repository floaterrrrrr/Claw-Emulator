// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@main enum SkinTests {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let skin = try JSONDecoder().decode(ControllerSkin.self, from: data)
        precondition(skin.isValid)
        let sizes = [CGSize(width: 667, height: 354), CGSize(width: 700, height: 340),
                     CGSize(width: 750, height: 381), CGSize(width: 832, height: 419)]
        for size in sizes {
            let safe = CGRect(origin: CGPoint(x: 62, y: 24), size: size)
            guard let layout = ControllerSkinLayout.make(skin: skin, in: safe) else {
                fatalError("Skin does not fit \(size)")
            }
            for control in skin.controls {
                let art = layout.artFrames[control.key]!, hit = layout.hitFrames[control.key]!
                precondition(abs(art.midX - hit.midX) < 0.001 && abs(art.midY - hit.midY) < 0.001)
                precondition(hit.width >= 44 && hit.height >= 44 && safe.contains(hit))
            }
            let game = layout.gameplay
            precondition(abs(game.top.width / game.top.height - 5.0 / 3) < 0.001)
            precondition(abs(game.bottom.width / game.bottom.height - 4.0 / 3) < 0.001)
            precondition(game.top.maxX < game.bottom.minX)
            precondition(game.dpad.maxY <= game.circle.minY)
            precondition(game.face.maxY <= game.bottom.minY)
            precondition(layout.quickSave.width >= 44 && layout.quickSave.height >= 44)
            precondition(layout.quickLoad.width >= 44 && layout.quickLoad.height >= 44)
            precondition(layout.quickSave.maxX < game.gear.minX && game.gear.maxX < layout.quickLoad.minX)
            precondition(layout.quickSave.maxY < game.top.minY)
            precondition(game.circle.maxX < game.top.minX)
            precondition(game.top.width * game.top.height > game.bottom.width * game.bottom.height * 2.5)
            precondition(game.bottom.width >= 168, "Touch display regressed to the old narrow column")
            precondition(abs(game.circle.minY - game.dpad.maxY - 24) < 0.001)
            precondition(abs(game.circle.midX - game.dpad.midX) < 0.001,
                         "Movement controls lost their common vertical centerline")
            precondition(game.face.minY >= safe.minY + 40, "ABXY collided with the header")
            precondition(game.face.width == 132, "Touch display size changed the ABXY targets")
            precondition(abs(game.face.midX - game.bottom.midX) < 0.001,
                         "ABXY should align with the touch display below it")
            precondition(safe.contains(layout.canvas))
            precondition(safe.contains(layout.quickSave) && safe.contains(layout.quickLoad))
        }
        for size in [CGSize(width: 320, height: 560), CGSize(width: 375, height: 647), CGSize(width: 402, height: 778), CGSize(width: 440, height: 860)] {
            let safe = CGRect(origin: CGPoint(x: 12, y: 62), size: size)
            let portrait = ControllerSkinLayout.make(skin: skin, in: safe)!
            precondition(!portrait.gameplay.landscape)
            precondition(portrait.gameplay.top.maxY < portrait.gameplay.bottom.minY)
            precondition(portrait.gameplay.face.maxY < portrait.quickLoad.minY)
            precondition(portrait.hitFrames.count == 10)
            precondition(portrait.gameplay.gear.width == 44)
            precondition(abs(portrait.gameplay.top.height - portrait.gameplay.bottom.height) < 0.001,
                         "3DS displays should retain matching physical heights")
            precondition(abs(portrait.gameplay.top.midX - safe.midX) < 0.001)
            precondition(abs(portrait.gameplay.bottom.midX - safe.midX) < 0.001)
        }
        precondition(ControllerSkinLayout.make(skin: skin, in: CGRect(x: 0, y: 0, width: 568, height: 300)) == nil)
        for size in sizes {
            let safe = CGRect(origin: CGPoint(x: 62, y: 24), size: size)
            let normal = ControllerSkinLayout.make(skin: skin, in: safe)!
            let larger = ControllerSkinLayout.make(skin: skin, in: safe, largerTouchScreen: true)!
            precondition(larger.gameplay.bottom.width > normal.gameplay.bottom.width)
            precondition(larger.gameplay.face == normal.gameplay.face || larger.gameplay.face.size == normal.gameplay.face.size)
        }
        // The shell must fill the display without shrinking the safe controls
        // into the fixed artwork aspect ratio. Exercise both cutout sides and
        // a nonzero container origin, as well as the iPhone 14/17/Max sizes.
        let phones: [(CGSize, CGFloat, CGFloat)] = [
            (CGSize(width: 667, height: 375), 0, 21),
            (CGSize(width: 844, height: 390), 59, 21),
            (CGSize(width: 874, height: 402), 62, 21),
            (CGSize(width: 956, height: 440), 62, 21)
        ]
        for (size, cutout, home) in phones {
            for cutoutOnLeft in [false, true] {
                let bounds = CGRect(origin: CGPoint(x: 11, y: 17), size: size)
                let left = cutoutOnLeft ? cutout : max(0, cutout - 3)
                let right = cutoutOnLeft ? max(0, cutout - 3) : cutout
                let safe = CGRect(x: bounds.minX + left, y: bounds.minY,
                                  width: bounds.width - left - right, height: bounds.height - home)
                let layout = ControllerSkinLayout.make(skin: skin, in: safe, bounds: bounds)!
                precondition(layout.canvas == bounds, "Shell left an avoidable outer border")
                let game = layout.gameplay
                let targets = Array(layout.hitFrames.values) + [game.top, game.bottom, game.hud,
                                                               game.gear, layout.quickSave, layout.quickLoad]
                precondition(targets.allSatisfy { safe.contains($0) }, "Content crossed a physical safe area")
                precondition(abs(game.top.width / game.top.height - 5.0 / 3) < 0.001)
                precondition(abs(game.bottom.width / game.bottom.height - 4.0 / 3) < 0.001)
                // Preserve the main display's dominance while allocating more
                // width to the requested larger touch display.
                if size.width == 874 { precondition(game.top.width > safe.width * 0.55) }
                for i in targets.indices {
                    for j in targets.indices where j > i {
                        let overlap = targets[i].intersection(targets[j])
                        precondition(overlap.isNull || overlap.width < 0.01 || overlap.height < 0.01,
                                     "Overlapping screens or controls on \(size)")
                    }
                }
            }
        }
        // Keep static skin artwork at Retina scale on phones, with a bounded
        // backing bitmap even for unexpectedly large viewports/display scales.
        for size in [CGSize(width: 402, height: 874), CGSize(width: 956, height: 440),
                     CGSize(width: 4096, height: 4096)] {
            for requested in [CGFloat(1), 2, 3, 4] {
                let scale = SkinRasterBudget.scale(for: size, displayScale: requested)!
                precondition(scale > 0 && scale <= requested && scale <= 3)
                precondition(size.width * size.height * scale * scale <= SkinRasterBudget.maxPixels + 0.001)
            }
        }
        precondition(SkinRasterBudget.scale(for: CGSize(width: 402, height: 874), displayScale: 3) == 3)
        precondition(SkinRasterBudget.scale(for: .zero, displayScale: 3) == nil)
        precondition(SkinRasterBudget.scale(for: CGSize(width: CGFloat.infinity, height: 10), displayScale: 3) == nil)
        precondition(SkinRasterBudget.scale(for: CGSize(width: 100, height: 100), displayScale: .nan) == nil)
        print("PASS: matching portrait/landscape shell, both landscape cutout sides, larger iPhone 17 screens, 44pt targets, no overlap and intact 3DS aspect ratios; bounded Retina skin raster budget")
    }
}
