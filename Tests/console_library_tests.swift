// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum DiskStore {
    static let coverDirectory = URL(fileURLWithPath: "/tmp")
    static let gamesDirectory = coverDirectory
}
@main enum ConsoleLibraryTests {
    static func main() throws {
        precondition(ConsoleLibraryInterface(rawValue: "modern") == .modern)
        precondition(ConsoleLibraryInterface(rawValue: "authentic")?.title == "Stacked UI")
        let old = Data("[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"Existing game\",\"fileName\":\"old.3ds\"}]".utf8)
        let legacy = try JSONDecoder().decode([Game].self, from: old)
        precondition(legacy[0].playedSeconds == nil && legacy[0].platform == .threeDS)
        var clock = PlaytimeClock()
        clock.resume(at: 100)
        clock.resume(at: 150) // Duplicate resume must not reset the start.
        precondition(clock.pause(at: 160) == 60)
        precondition(clock.pause(at: 200) == 0) // Pause/exit cannot double count.
        clock.resume(at: 300) // Paused/background time is excluded.
        precondition(clock.pause(at: 330) == 30)
        clock.resume(at: .infinity)
        precondition(clock.pause(at: 400) == 0)
        clock.resume(at: 500)
        precondition(clock.pause(at: 499) == 0)
        let a = Game(id: UUID(), name: "Alpha", fileName: "a.gba", favorite: true,
                     lastPlayed: Date(timeIntervalSince1970: 100), system: .gba, playedSeconds: 61)
        let b = Game(id: UUID(), name: "Beta", fileName: "b.nds", lastPlayed: Date(timeIntervalSince1970: 200),
                     system: .ds, playedSeconds: 3600)
        let c = Game(id: UUID(), name: "Gamma", fileName: "c.gba", system: .gba)
        let games = [c, a, b]
        precondition(ConsoleCatalog.games(games, system: nil, favorites: false, search: "", sort: .recent).map(\.id) == [b.id, a.id, c.id])
        precondition(ConsoleCatalog.games(games, system: .gba, favorites: true, search: " ALP ", sort: .title).map(\.id) == [a.id])
        precondition(ConsoleCatalog.games(games, system: nil, favorites: false, search: "", sort: .playtime).map(\.id) == [b.id, a.id, c.id])
        precondition(ConsoleCatalog.games(games, system: .nes, favorites: false, search: "", sort: .recent).isEmpty)
        precondition(ConsoleCatalog.playtime(45720) == "12h 42m")
        precondition(ConsoleCatalog.playtime(-1) == "Less than a minute")
        precondition(ConsoleCatalog.playtime(.nan) == "Less than a minute")
        let saved = try JSONDecoder().decode(Game.self, from: JSONEncoder().encode(b))
        precondition(saved.playedSeconds == 3600)
        let rawName = "Orbit Quest (USA) (En,Ja,Fr,De,Es,It,Ko) Decrypted"
        precondition(ConsoleCatalog.displayName(rawName) == "Orbit Quest")
        precondition(!CoverArtLifecycle.shouldReleaseImage(visible: true, active: false))
        precondition(!CoverArtLifecycle.shouldReleaseImage(visible: false, active: false))
        precondition(!CoverArtLifecycle.shouldReleaseImage(visible: true, active: true))
        precondition(CoverArtLifecycle.shouldReleaseImage(visible: false, active: true))
        precondition(CoverArtLifecycle.shouldReleaseImage(visible: true, active: true, memoryPressure: true))
        precondition(CoverArtLifecycle.shouldReleaseImage(visible: true, active: false, memoryPressure: true))
        precondition(ConsoleNavigation.selectionIndex(forX: 10, width: 350, count: 5) == 0)
        precondition(ConsoleNavigation.selectionIndex(forX: 59, width: 350, count: 5) == 0)
        precondition(ConsoleNavigation.selectionIndex(forX: 65, width: 350, count: 5) == nil)
        precondition(ConsoleNavigation.selectionIndex(forX: 70, width: 350, count: 5) == nil)
        precondition(ConsoleNavigation.selectionIndex(forX: 79, width: 350, count: 5) == nil)
        precondition(ConsoleNavigation.selectionIndex(forX: 80, width: 350, count: 5) == 1)
        precondition(ConsoleNavigation.selectionIndex(forX: 300, width: 350, count: 5) == 4)
        precondition(ConsoleNavigation.selectionIndex(forX: 350, width: 350, count: 5) == 4)
        precondition(ConsoleNavigation.selectionIndex(forX: -5, width: 350, count: 5) == 0)
        precondition(ConsoleNavigation.selectionIndex(forX: .nan, width: 350, count: 5) == nil)
        for boundary in 1..<5 {
            let x = Double(boundary) * 70
            precondition(ConsoleNavigation.selectionIndex(forX: x - 10, width: 350, count: 5) == boundary - 1)
            precondition(ConsoleNavigation.selectionIndex(forX: x + 10, width: 350, count: 5) == boundary)
            precondition(ConsoleNavigation.selectionIndex(forX: x - 9, width: 350, count: 5) == nil)
            precondition(ConsoleNavigation.selectionIndex(forX: x + 9, width: 350, count: 5) == nil)
        }
        precondition(BatteryPresentation.percentText(-1) == "—")
        precondition(BatteryPresentation.percentText(0.504) == "50%")
        precondition(BatteryPresentation.percentText(1) == "100%")
        precondition(BatteryPresentation.accessibilityText(-1, charging: false) == "Battery unavailable")
        precondition(BatteryPresentation.accessibilityText(0.42, charging: true) == "Battery 42 percent, charging")
        precondition(BatteryPresentation.symbolName(0.9) == "battery.100percent")
        precondition(BatteryPresentation.symbolName(-1) == "battery.0percent")
        for color in AppIconColor.choices {
            precondition(AppIconColor.closest(to: color.rgb) == color)
        }
        precondition(AppIconColor.resolve(accent: "green", customRGB: 0, matchAccent: true,
                                         manualRGB: AppIconColor.red.rgb, original: true) == .green)
        precondition(AppIconColor.resolve(accent: "custom", customRGB: 0x2589F9, matchAccent: true,
                                         manualRGB: 0, original: false) == .blue)
        precondition(AppIconColor.resolve(accent: "blue", customRGB: 0, matchAccent: false,
                                         manualRGB: AppIconColor.orange.rgb, original: false) == .orange)
        precondition(AppIconColor.resolve(accent: "blue", customRGB: 0, matchAccent: false,
                                         manualRGB: 0, original: true).alternateName == nil)
        precondition(AppIconColor.resolve(accent: "missing", customRGB: 0, matchAccent: true,
                                         manualRGB: 0, original: false) == .orange)
        precondition(AppIconColor.choices == [.orange, .blue, .green, .red])
        // Duplicate visual regions own unique sources. Releasing one region or
        // a controller must not release the same input held elsewhere.
        var held = HeldInputUnion<PadKey>()
        precondition(held.set(.a, pressed: true, source: "face-700") == true)
        precondition(held.set(.a, pressed: true, source: "duplicate-a-1") == nil)
        precondition(held.set(.a, pressed: true, source: "controller-1") == nil)
        precondition(held.allInputs == [.a])
        precondition(held.set(.a, pressed: false, source: "face-700") == nil)
        precondition(held.set(.a, pressed: false, source: "controller-1") == nil)
        precondition(held.allInputs == [.a])
        precondition(held.set(.a, pressed: false, source: "duplicate-a-1") == false)
        precondition(held.allInputs.isEmpty)
        precondition(held.set(.up, pressed: true, source: "dpad") == true)
        precondition(held.set(.left, pressed: true, source: "duplicate-dpad-1") == true)
        precondition(held.set(.up, pressed: false, source: "dpad") == false)
        precondition(held.set(.left, pressed: true, source: "duplicate-dpad-1") == nil)
        precondition(held.allInputs == [.left])
        precondition(held.set(.left, pressed: false, source: "duplicate-dpad-1") == false)
        precondition(held.set(.b, pressed: false, source: "unknown") == nil)
        precondition(held.allInputs.isEmpty)
        precondition(held.set(.a, pressed: true, source: "circle") == true)
        held.removeAll()
        precondition(held.allInputs.isEmpty)
        for width in [284.0, 320, 375, 393, 430] {
            for height in [400.0, 424, 460, 520, 625, 680, 760] {
                for resume in [true, false] {
                    let layout = ConsolePortraitLayout(width: width, height: height, hasRecent: true, hasResume: resume)
                    let used = layout.coverSide + 265 + (resume ? 40 : 0) + (layout.showRecent ? 85 : 0)
                    precondition(used <= height + 4 && layout.coverSide >= 64)
                    let large = ConsolePortraitLayout(width: width, height: height, hasRecent: true, hasResume: resume, largeText: true)
                    let largeUsed = large.coverSide + 281 + (resume ? 40 : 0) + (large.showRecent ? 85 : 0)
                    precondition(largeUsed <= height + 4 && large.coverSide >= 64)
                }
            }
        }
        let phoneHome = ConsolePortraitLayout(width: 357, height: 629, hasRecent: true, hasResume: true)
        precondition(phoneHome.showRecent && phoneHome.coverSide >= 200)
        let shortHome = ConsolePortraitLayout(width: 284, height: 460, hasRecent: true, hasResume: true)
        precondition(!shortHome.showRecent && shortHome.coverSide >= 150)
        for width in [284.0, 320, 339, 357, 394, 560, 700, 900] {
            let strip = ConsoleSystemBarLayout(width: width, largeText: false)
            precondition((92...112).contains(strip.itemWidth) && strip.contentWidth.isFinite)
            precondition(strip.itemHeight == 60 && strip.height == 74)
            if width >= 704 { precondition(strip.contentWidth <= width + 0.01) }
            else { precondition(strip.contentWidth > width) } // hardware cards scroll on phones
            let accessible = ConsoleSystemBarLayout(width: width, largeText: true)
            precondition(accessible.itemWidth == 132 && accessible.itemHeight == 76 && accessible.height == 90)
        }
        precondition(ConsoleSystemBarLayout(width: .nan, largeText: false).itemWidth == 92)
        print("PASS: safe cover title/region matching, sequel separation, clean display names, fixed portrait home geometry with resume/recents")
        print("PASS: old library migration, active-only playtime, duplicate pause/resume, invalid clocks, system/search/favorite filters, stable sorting, playtime persistence, cover lifecycle/memory release, dock dead zones, battery formatting, app icon color policy and unioned duplicate input sources")
    }
}
