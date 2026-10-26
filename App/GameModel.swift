// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum GameSystem: String, Codable, CaseIterable, Identifiable, Sendable {
    case threeDS = "3ds", ds = "nds", gba, gb, gbc, nes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .threeDS: return "Nintendo 3DS"
        case .ds: return "Nintendo DS"
        case .gba: return "Game Boy Advance"
        case .gb: return "Game Boy"
        case .gbc: return "Game Boy Color"
        case .nes: return "Nintendo Entertainment System"
        }
    }
    var extensions: [String] {
        switch self {
        case .threeDS: return ["cci", "3ds", "cxi", "app", "cia", "3dsx"]
        case .ds: return ["nds", "srl"]
        case .gb: return ["gb", "sgb"]
        case .nes: return ["nes", "unif", "unf"]
        default: return [rawValue]
        }
    }
    static func identify(extension ext: String) -> Self? {
        allCases.first { $0.extensions.contains(ext.lowercased()) }
    }
    var dualScreen: Bool { self == .threeDS || self == .ds }
    var shortTitle: String {
        switch self {
        case .threeDS: return "3DS"
        case .ds: return "DS"
        case .gba: return "GBA"
        case .gb: return "GB"
        case .gbc: return "GBC"
        case .nes: return "NES"
        }
    }
    var nativeWidth: Int {
        switch self { case .threeDS: return 400; case .ds, .nes: return 256; case .gba: return 240; case .gb, .gbc: return 160 }
    }
    var nativeHeight: Int {
        switch self { case .threeDS, .nes: return 240; case .ds: return 192; case .gba: return 160; case .gb, .gbc: return 144 }
    }
    var aspect: Double { self == .nes ? 4.0 / 3 : Double(nativeWidth) / Double(nativeHeight) }
    var core: Int32 { self == .threeDS ? 0 : self == .ds ? 3 : self == .nes ? 2 : 1 }
    func showsControl(_ key: String) -> Bool {
        if key == "x" || key == "y" { return dualScreen }
        if key == "l" || key == "r" { return dualScreen || self == .gba }
        return true
    }
    func saveIdentity(for id: UUID) -> UInt64 {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let value = bytes.prefix(7).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        return value | UInt64(0xC0 + Self.allCases.firstIndex(of: self)!) << 56
    }
}

// Emulator button codes. This lives with the model (Foundation only) so the
// pure input-union and layout tests can use the same type as the app.
enum PadKey: Int32 {
    case a = 700, b = 701, x = 702, y = 703
    case start = 704, select = 705
    case up = 709, down = 710, left = 711, right = 712
    case l = 773, r = 774
}

struct Game: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
    let fileName: String
    var titleID: UInt64? = nil
    var favorite: Bool? = nil
    var lastPlayed: Date? = nil
    var coverFile: String? = nil
    // Set when the player deliberately removes artwork so refreshIdentities
    // does not restore the embedded icon on the next launch.
    var coverRemoved: Bool? = nil
    var system: GameSystem? = nil
    // Optional so existing libraries decode unchanged. Actual running time only.
    var playedSeconds: Double? = nil
    var platform: GameSystem { system ?? .threeDS }
    var coverURL: URL? { coverFile.map { DiskStore.coverDirectory.appendingPathComponent($0) } }
    var url: URL { DiskStore.gamesDirectory.appendingPathComponent(fileName) }
}
