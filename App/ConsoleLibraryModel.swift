// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum ConsoleLibraryInterface: String, CaseIterable, Identifiable {
    case modern, authentic
    var id: String { rawValue }
    var title: String { self == .modern ? "Claw UI" : "Stacked UI" }
    var summary: String {
        self == .modern ? "A focused cover carousel with subtle accent lighting."
            : "Browse by system, with a game list and cover panel."
    }
}

enum ConsoleSort: String, CaseIterable, Identifiable {
    case recent, title, playtime
    var id: String { rawValue }
    var title: String {
        switch self { case .recent: return "Recently played"; case .title: return "Title"; case .playtime: return "Time played" }
    }
}

// Readable hardware cards share their proportions in both library interfaces.
// Phones scroll the row; wider displays can fit all systems without squeezing.
struct ConsoleSystemBarLayout {
    static let regularHeight = 74.0
    static let largeTextHeight = 90.0
    let itemWidth: Double
    let itemHeight: Double
    let height: Double
    let spacing: Double
    let contentWidth: Double
    init(width: Double, largeText: Bool, count: Int = GameSystem.allCases.count + 1) {
        let available = width.isFinite ? max(0, width) : 0
        let items = max(1, count)
        spacing = 9
        let gaps = Double(items - 1) * spacing
        // Keep the hardware icons and labels readable on phones. Extra systems
        // scroll horizontally instead of being squeezed into tiny pills.
        itemWidth = largeText ? 132 : min(112, max(92, (available - 6 - gaps) / Double(items)))
        itemHeight = largeText ? 76 : 60
        height = largeText ? Self.largeTextHeight : Self.regularHeight
        contentWidth = Double(items) * itemWidth + gaps + 6
    }
}

enum ConsoleCatalog {
    static func displayName(_ value: String) -> String {
        var name = value.replacingOccurrences(of: "(?i)\\s*\\((USA|Europe|Japan|World|Korea|Taiwan|Australia|En[,)]|Rev[ .])[^)]*\\).*", with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: "(?i)\\s+(decrypted|encrypted|trimmed)$", with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: "\\s*\\[[^]]*\\]", with: "", options: .regularExpression)
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func games(_ games: [Game], system: GameSystem?, favorites: Bool, search: String,
                      sort: ConsoleSort) -> [Game] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return games.filter {
            (system == nil || $0.platform == system) && (!favorites || $0.favorite == true) &&
                (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }.sorted { a, b in
            if sort == .recent, a.lastPlayed != b.lastPlayed {
                return (a.lastPlayed ?? .distantPast) > (b.lastPlayed ?? .distantPast)
            }
            if sort == .playtime, seconds(a.playedSeconds) != seconds(b.playedSeconds) {
                return seconds(a.playedSeconds) > seconds(b.playedSeconds)
            }
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.id.uuidString < b.id.uuidString : order == .orderedAscending
        }
    }
    static func seconds(_ value: Double?) -> Double {
        guard let value, value.isFinite, value > 0 else { return 0 }
        return value
    }
    static func playtime(_ value: Double?) -> String {
        let minutes = Int(min(seconds(value), 3_153_600_000) / 60)
        if minutes == 0 { return "Less than a minute" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

// Geometry budget for a fixed portrait HOME screen, excluding header and bottom dock.
// Optional recent tiles yield space first; large accessibility text uses a scroll fallback.
struct ConsolePortraitLayout {
    let coverSide: Double
    let showRecent: Bool
    let filterHeight: Double
    init(width: Double, height: Double, hasRecent: Bool, hasResume: Bool = false, largeText: Bool = false) {
        filterHeight = largeText ? ConsoleSystemBarLayout.largeTextHeight : ConsoleSystemBarLayout.regularHeight
        // Filters 74/90, cover light inset 20, details 46, launch 48/88,
        // actions 44, row gaps 25 and vertical padding 8. Count/sort live in Search.
        let base = 191.0 + filterHeight + (hasResume ? 40 : 0)
        showRecent = hasRecent && height - base - 85 >= 145
        coverSide = max(64, min(width * 0.68, height - base - (showRecent ? 85 : 0)))
    }
}

enum CoverArtLifecycle {
    static func shouldReleaseImage(visible: Bool, active: Bool, memoryPressure: Bool = false) -> Bool {
        memoryPressure || (!visible && active)
    }
}

// Pure battery formatting shared by the library and the in-game header. The
// monitor owns live UIDevice values; these helpers keep placeholders and
// accessibility copy identical in both places.
enum BatteryPresentation {
    static func percentText(_ level: Float) -> String {
        guard level.isFinite, level >= 0 else { return "—" }
        return "\(min(100, Int((level * 100).rounded())))%"
    }
    static func symbolName(_ level: Float) -> String {
        guard level.isFinite, level >= 0 else { return "battery.0percent" }
        if level <= 0.15 { return "battery.0percent" }
        if level <= 0.35 { return "battery.25percent" }
        if level <= 0.65 { return "battery.50percent" }
        if level <= 0.85 { return "battery.75percent" }
        return "battery.100percent"
    }
    static func accessibilityText(_ level: Float, charging: Bool) -> String {
        guard level.isFinite, level >= 0 else { return "Battery unavailable" }
        let percent = min(100, Int((level * 100).rounded()))
        return "Battery \(percent) percent" + (charging ? ", charging" : "")
    }
}

// Input presses are unioned per source. A duplicate visual region for one
// input uses its own source, so releasing one region or a controller must not
// cancel the same input still held by another region.
struct HeldInputUnion<Input: Hashable> {
    private var held: [String: Set<Input>] = [:]
    var allInputs: Set<Input> { Set(held.values.flatMap { $0 }) }
    // Returns the new pressed state only when it actually changed; nil means
    // another source already holds the input (or already released it).
    mutating func set(_ input: Input, pressed: Bool, source: String) -> Bool? {
        let wasPressed = held.values.contains { $0.contains(input) }
        if pressed { held[source, default: []].insert(input) } else { held[source]?.remove(input) }
        let nowPressed = held.values.contains { $0.contains(input) }
        return wasPressed == nowPressed ? nil : nowPressed
    }
    mutating func removeAll() { held.removeAll() }
}

// Horizontal dock selection with a dead zone around internal boundaries.
// Returning nil means "keep the current page"; this prevents a finger resting
// on a boundary from alternating pages and firing repeated haptics. The outer
// edges are not dead zones because the first and last pages must stay reachable.
enum ConsoleNavigation {
    static func selectionIndex(forX x: Double, width: Double, count: Int,
                               deadZone: Double = 10) -> Int? {
        guard count > 0, width.isFinite, width > 0, x.isFinite else { return nil }
        let clamped = min(max(x, 0), width.nextDown)
        let cell = width / Double(count)
        guard cell.isFinite, cell > 0 else { return nil }
        let raw = clamped / cell
        let boundary = raw.rounded()
        let zone = deadZone.isFinite ? max(0, deadZone) : 0
        // Compare in points. Dividing and then multiplying the distance made
        // an exact 10-point edge become 9.999999999999996 on both architectures.
        if boundary >= 1, boundary <= Double(count - 1), abs(clamped - boundary * cell) < zone {
            return nil
        }
        return min(count - 1, max(0, Int(raw)))
    }
}

// No polling, wall clock, or frame-loop work. Call only at session transitions.
struct PlaytimeClock {
    private var startedAt: TimeInterval?
    mutating func resume(at uptime: TimeInterval) {
        guard uptime.isFinite, startedAt == nil else { return }
        startedAt = uptime
    }
    mutating func pause(at uptime: TimeInterval) -> TimeInterval {
        guard let start = startedAt else { return 0 }
        startedAt = nil
        guard uptime.isFinite, uptime >= start else { return 0 }
        return uptime - start
    }
}
