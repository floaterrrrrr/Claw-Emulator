// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

enum DiskStore {
    static let coverDirectory = URL(fileURLWithPath: "/tmp")
    static let gamesDirectory = coverDirectory
}
@main enum HandheldControlTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String = "Requirement failed",
                      file: StaticString = #filePath, line: UInt = #line) {
        guard condition() else {
            FileHandle.standardError.write(Data("\(file):\(line): error: \(message)\n".utf8))
            exit(1)
        }
    }
    static func close(_ a: Double, _ b: Double, file: StaticString = #filePath, line: UInt = #line) {
        check(abs(a - b) < 0.001, "\(a) != \(b)", file: file, line: line)
    }
    static func close(_ a: CGRect, _ b: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        close(a.minX, b.minX, file: file, line: line); close(a.minY, b.minY, file: file, line: line)
        close(a.width, b.width, file: file, line: line); close(a.height, b.height, file: file, line: line)
    }
    static func main() throws {
        let suite = "claw.handheld.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let screens = [CGRect(x: 0, y: 59, width: 393, height: 759),
                       CGRect(x: 59, y: 0, width: 734, height: 372),
                       CGRect(x: 0, y: 20, width: 320, height: 528),
                       CGRect(x: 0, y: 0, width: 568, height: 299),
                       CGRect(x: 0, y: 0, width: 1024, height: 1366),
                       CGRect(x: 64, y: 0, width: 828, height: 419)]
        for system in GameSystem.allCases {
            let configuration = HandheldControlsConfiguration.load(system: system, defaults: defaults)
            check(configuration.enabled == [.gb, .gbc, .gba].contains(system))
            close(configuration.opacity, 0.45)
            guard system.hasHandheldOverlay else { continue }
            for safe in screens {
                let frames = HandheldControlLayout().frames(in: safe, system: system)
                check(frames.count == (system == .gba ? 9 : 7))
                check((frames[.l] != nil) == (system == .gba))
                for (control, frame) in frames {
                    check(safe.insetBy(dx: -0.001, dy: -0.001).contains(frame), "Control is outside the safe area")
                    check(frame.width >= 44 && frame.height >= 44)
                    close(frame.width / frame.height, control == .l || control == .r ? 76.0 / 44.0 : 1.0)
                }
                // Maximal aspect-fit, with no control gutter or cropped pixels.
                let viewport = HandheldViewport.frame(in: safe, aspect: system.aspect)
                close(viewport.width / viewport.height, system.aspect)
                check(safe.insetBy(dx: -0.001, dy: -0.001).contains(viewport))
                close(viewport.midX, safe.midX); close(viewport.midY, safe.midY)
                check(abs(viewport.width - safe.width) < 0.001 || abs(viewport.height - safe.height) < 0.001)

            }
        }
        let safe = screens[0]
        var edited = HandheldControlLayout()
        edited.set(.a, frame: CGRect(x: 160, y: 200, width: 80, height: 72), in: safe)
        let resolved = edited.frames(in: safe, system: .gba)[.a]!
        close(resolved, CGRect(x: 160, y: 196, width: 80, height: 80))
        let before = HandheldControlsConfiguration.load(system: .gba, defaults: defaults)
        check(before.portrait.controls.isEmpty, "Editing a draft does not persist it")
        try HandheldControlsConfiguration.save(edited, system: .gba, orientation: "portrait", opacity: 0.3, defaults: defaults)
        let saved = HandheldControlsConfiguration.load(system: .gba, defaults: defaults)
        check(saved.portrait == edited && saved.landscape.controls.isEmpty)
        check(HandheldControlsConfiguration.load(system: .gb, defaults: defaults).portrait.controls.isEmpty)
        close(saved.opacity, 0.3)
        let doubled = CGRect(x: 40, y: 80, width: safe.width * 2, height: safe.height * 2)
        let scaled = saved.portrait.frames(in: doubled, system: .gba)[.a]!
        close((scaled.midX - doubled.minX) / doubled.width, (resolved.midX - safe.minX) / safe.width)
        close((scaled.midY - doubled.minY) / doubled.height, (resolved.midY - safe.minY) / safe.height)
        close(scaled.width, 160); close(scaled.height, 160)
        // Fused multiply-add can retain a sub-ulp remainder on Apple silicon.
        // Normalized coordinates need geometric tolerance, not bitwise equality.
        close(CGRect(x: (-22.0).addingProduct(22.0 / 393, 393), y: 774, width: 44, height: 44),
              CGRect(x: 0, y: 774, width: 44, height: 44))
        var clamped = HandheldControlLayout()
        clamped.set(.menu, frame: CGRect(x: -999, y: 9999, width: 1, height: 1), in: safe)
        let menu = clamped.frames(in: safe, system: .gb)[.menu]!
        close(menu, CGRect(x: safe.minX, y: safe.maxY - 44, width: 44, height: 44))
        clamped.set(.dpad, frame: CGRect(x: 10, y: 10, width: 9999, height: 9999), in: safe)
        let oversizedPad = clamped.frames(in: safe, system: .gb)[.dpad]!
        close(oversizedPad.width, safe.width); close(oversizedPad.height, safe.width)
        let unchanged = clamped
        clamped.set(.a, frame: CGRect(x: Double.nan, y: 0, width: 60, height: 60), in: safe)
        check(clamped == unchanged)
        for json in ["{}", "invalid", "{\"version\":99,\"controls\":{}}",
                     "{\"version\":1,\"controls\":{\"unknown\":{\"x\":0.5,\"y\":0.5,\"width\":0.2,\"height\":0.2}}}",
                     "{\"version\":1,\"controls\":{\"a\":{\"x\":-1,\"y\":0.5,\"width\":0.2,\"height\":0.2}}}"] {
            defaults.set(Data(json.utf8), forKey: HandheldControlsConfiguration.key(.gb, "portrait"))
            check(HandheldControlsConfiguration.layout(system: .gb, orientation: "portrait", defaults: defaults).controls.isEmpty)
        }
        var invalid = HandheldControlLayout()
        invalid.controls["a"] = HandheldPlacement(x: .nan, y: 0.5, width: 0.2, height: 0.2)
        check(!invalid.valid)
        do {
            try HandheldControlsConfiguration.save(invalid, system: .gba, orientation: "portrait", opacity: 0.4, defaults: defaults)
            check(false, "Invalid geometry must not overwrite the saved layout")
        } catch { }
        check(HandheldControlsConfiguration.load(system: .gba, defaults: defaults).portrait == edited)
        // A previously selected fill preference is obsolete and must not crop.
        defaults.set("fullScreen", forKey: HandheldControlsConfiguration.key(.gb, "screen"))
        let fitted = HandheldViewport.frame(in: screens[1], aspect: GameSystem.gb.aspect)
        close(fitted.width / fitted.height, GameSystem.gb.aspect)
        check(screens[1].insetBy(dx: -0.001, dy: -0.001).contains(fitted))
        defaults.set(9.0, forKey: HandheldControlsConfiguration.key(.gb, "opacity"))
        let recovered = HandheldControlsConfiguration.load(system: .gb, defaults: defaults)
        check(recovered.opacity == 0.8)
        defaults.set(false, forKey: HandheldControlsConfiguration.key(.gba, "enabled"))
        check(!HandheldControlsConfiguration.load(system: .gba, defaults: defaults).enabled)
        // New layouts can reach every physical edge while defaults still avoid cutouts.
        let full = CGRect(x: 0, y: 0, width: 852, height: 393)
        let inset = CGRect(x: 59, y: 0, width: 734, height: 372)
        for control in HandheldControl.available(for: .gba) {
            var edge = HandheldControlLayout()
            edge.set(control, frame: CGRect(x: -200, y: 999, width: 64, height: 64), in: full)
            let frame = edge.frames(in: full, system: .gba, safeArea: inset)[control]!
            close(frame.minX, 0); close(frame.maxY, full.maxY)
            edge.set(control, frame: CGRect(x: 9999, y: -200, width: 64, height: 64), in: full)
            let opposite = edge.frames(in: full, system: .gba, safeArea: inset)[control]!
            close(opposite.maxX, full.maxX); close(opposite.minY, 0)
        }
        // The editor shortcut is layout-only, with independent saved positions.
        check(!HandheldCombo.inputs(for: .gba).contains(.edit))
        var handPortrait = HandheldControlLayout(), handLandscape = HandheldControlLayout()
        handPortrait.set(.edit, frame: CGRect(x: 100, y: 160, width: 44, height: 44), in: safe)
        handLandscape.set(.edit, frame: CGRect(x: 250, y: 80, width: 44, height: 44), in: full)
        try HandheldControlsConfiguration.save(handPortrait, system: .gb, orientation: "portrait", opacity: 0.45, defaults: defaults)
        try HandheldControlsConfiguration.save(handLandscape, system: .gb, orientation: "landscape", opacity: 0.45, defaults: defaults)
        let handConfig = HandheldControlsConfiguration.load(system: .gb, defaults: defaults)
        close(handConfig.portrait.frames(in: safe, system: .gb)[.edit]!, CGRect(x: 100, y: 160, width: 44, height: 44))
        close(handConfig.landscape.frames(in: full, system: .gb)[.edit]!, CGRect(x: 250, y: 80, width: 44, height: 44))
        let maxCombos = (0..<16).map { HandheldCombo(name: "Button \($0)", inputs: [.a]) }
        var fullLayout = HandheldControlLayout()
        for (key, frame) in fullLayout.allFrames(in: full, system: .gba, combos: maxCombos) {
            fullLayout.set(key, frame: frame, in: full)
        }
        check(fullLayout.controls.count == 25 && fullLayout.valid, "The hand shortcut must not reduce the 16 custom-button allowance")
        var legacy = edited; legacy.version = 1
        let legacyFrames = legacy.frames(in: full, system: .gba, safeArea: inset)
        let migrated = legacy.migrated(in: full, safeArea: inset, system: .gba)
        check(migrated.version == 3)
        for (key, frame) in legacyFrames { close(migrated.frames(in: full, system: .gba, safeArea: inset)[key]!, frame) }
        let exampleCombo = HandheldCombo(name: "Example combo", inputs: [.b, .r])
        check(HandheldCombo.automaticName(for: [.a, .b]) == "A+B")
        check(HandheldCombo.automaticName(for: [.start, .select]) == "S+S")
        check(HandheldCombo.resolvedName("  ", inputs: [.r, .b]) == "R+B")
        check(HandheldCombo.resolvedName(" Custom ", inputs: [.r, .b]) == "Custom")
        let speed2 = HandheldCombo(name: HandheldCombo.resolvedName("", inputs: [], speed: 2), inputs: [], speed: 2)
        let speed4 = HandheldCombo(name: HandheldCombo.resolvedName("", inputs: [], speed: 4), inputs: [], speed: 4)
        check(speed2.name == "2×" && speed4.name == "4×")
        check(speed2.valid(for: .gba) && speed4.valid(for: .gba))
        check(!speed2.valid(for: .gb) && !speed4.valid(for: .gbc))
        check(!HandheldCombo(name: "3×", inputs: [], speed: 3).valid(for: .gba))
        check(!HandheldCombo(name: "2×", inputs: [.a], speed: 2).valid(for: .gba))
        let restoredCombo = try JSONDecoder().decode(HandheldCombo.self, from: JSONEncoder().encode(exampleCombo))
        check(restoredCombo == exampleCombo,
              "Existing combos decode without a speed action")
        check(exampleCombo.valid(for: .gba) && !exampleCombo.valid(for: .gb))
        check(exampleCombo.keys == [.r, .b], "Shoulder modifiers latch before the fire button")
        check(!HandheldCombo(name: "", inputs: [.a]).valid(for: .gba))
        check(!HandheldCombo(name: "Bad", inputs: [.menu]).valid(for: .gba))
        check(!HandheldCombo(name: "Bad", inputs: [.a, .a]).valid(for: .gba))
        var custom = HandheldControlLayout()
        custom.set(exampleCombo.key, frame: CGRect(x: 0, y: 0, width: 64, height: 64), in: full)
        close(custom.allFrames(in: full, system: .gba, combos: [exampleCombo], safeArea: inset)[exampleCombo.key]!, CGRect(x: 0, y: 0, width: 64, height: 64))
        // Old portrait sizes (including the reported tall custom button) are
        // repaired on read and preserve circular geometry after migration.
        var oldLayout = HandheldControlLayout(); oldLayout.version = 2
        for key in ["a", "b", "start", "select", "dpad", "l", "r", exampleCombo.key] {
            oldLayout.controls[key] = HandheldPlacement(x: 0.5, y: 0.5, width: 0.2, height: 0.3)
        }
        for screen in screens {
            let legacyFrames = oldLayout.allFrames(in: screen, system: .gba, combos: [exampleCombo])
            let repaired = oldLayout.migrated(in: screen, safeArea: screen, system: .gba, combos: [exampleCombo])
            for (key, frame) in legacyFrames {
                close(frame.width / frame.height, key == "l" || key == "r" ? 76.0 / 44.0 : 1)
                close(repaired.allFrames(in: screen, system: .gba, combos: [exampleCombo])[key]!, frame)
            }
            for resized in screens {
                for (key, frame) in repaired.allFrames(in: resized, system: .gba, combos: [exampleCombo]) {
                    close(frame.width / frame.height, key == "l" || key == "r" ? 76.0 / 44.0 : 1)
                    check(resized.insetBy(dx: -0.001, dy: -0.001).contains(frame))
                }
            }
        }
        try HandheldControlsConfiguration.save(custom, system: .gba, orientation: "landscape", opacity: 0.5,
                                               combos: [exampleCombo, speed2, speed4], defaults: defaults)
        let comboConfig = HandheldControlsConfiguration.load(system: .gba, defaults: defaults)
        check(comboConfig.combos == [exampleCombo, speed2, speed4] && comboConfig.landscape == custom)
        check(comboConfig.portrait == edited, "Landscape edits preserve the portrait layout")
        defaults.set(HandheldMovement.joystick.rawValue, forKey: HandheldControlsConfiguration.key(.gba, "movement"))
        check(HandheldControlsConfiguration.load(system: .gba, defaults: defaults).movement == .joystick)
        var union = HeldInputUnion<PadKey>()
        check(union.set(.r, pressed: true, source: "manual") == true)
        check(union.set(.r, pressed: true, source: exampleCombo.key) == nil)
        check(union.set(.b, pressed: true, source: exampleCombo.key) == true)
        check(union.set(.b, pressed: true, source: "another combo") == nil)
        check(union.set(.r, pressed: false, source: exampleCombo.key) == nil)
        check(union.set(.b, pressed: false, source: exampleCombo.key) == nil)
        check(union.allInputs == [.r, .b])
        check(union.set(.r, pressed: false, source: "manual") == false)
        check(union.set(.b, pressed: false, source: "another combo") == false)
        check(union.allInputs.isEmpty)
        print("PASS: circular controls, pill shoulders, resized legacy layouts, automatic/custom names, edge placement and independent held inputs")
        print("PASS: GB/GBC/GBA aspect-fit, safe targets, normalized placement, persistence isolation, invalid-data recovery")
    }
}
