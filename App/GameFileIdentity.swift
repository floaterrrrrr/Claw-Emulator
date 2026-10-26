// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// Read only container headers. Never decrypt, scan a multi-GB ROM, or involve
// the live core just to identify games in the library.
enum GameFileIdentity {
    // Archives sometimes contain a playable image named .bin or .rom. Trust
    // recognizable cartridge headers, never the archive entry's unknown suffix.
    static func extensionForUnknownROM(at url: URL) throws -> String? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = Array(try file.read(upToCount: 0x200) ?? Data())
        func matches(_ offset: Int, _ signature: [UInt8]) -> Bool {
            bytes.count >= offset + signature.count &&
                Array(bytes[offset..<offset + signature.count]) == signature
        }
        if matches(0x100, Array("NCSD".utf8)) { return "3ds" }
        if matches(0x100, Array("NCCH".utf8)) { return "cxi" }
        if matches(0, Array("3DSX".utf8)) { return "3dsx" }
        if matches(0, [0x4E, 0x45, 0x53, 0x1A]) || matches(0, Array("UNIF".utf8)) { return "nes" }
        let logo: [UInt8] = [0x24, 0xFF, 0xAE, 0x51]
        if matches(0xC0, logo) { return "nds" }
        if matches(4, logo) { return "gba" }
        if matches(0x104, [0xCE, 0xED, 0x66, 0x66]) {
            return bytes.count > 0x143 && bytes[0x143] & 0x80 != 0 ? "gbc" : "gb"
        }
        return nil
    }

    static func titleID(at url: URL) throws -> UInt64? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        func bytes(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
            try file.seek(toOffset: offset)
            return Array(try file.read(upToCount: count) ?? Data())
        }
        func little(_ data: [UInt8]) -> UInt64 {
            data.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }
        let header = try bytes(0x100, 0x30)
        guard header.count == 0x30 else { return nil }
        let magic = String(bytes: header.prefix(4), encoding: .ascii)
        var base: UInt64 = 0
        if magic == "NCSD" {
            base = little(Array(header[0x20..<0x24])) * 0x200
            guard base >= 0x200 else { return nil }
        } else if magic != "NCCH" { return nil }
        guard try bytes(base + 0x100, 4) == Array("NCCH".utf8) else { return nil }
        let id = try bytes(base + 0x118, 8)
        guard id.count == 8 else { return nil }
        let value = little(id)
        return value == 0 ? nil : value
    }
}

extension GameFileIdentity {
    // Optional icon from a decrypted ExeFS. This is a local fallback, never an
    // online cover-art lookup and never a crypto override for encrypted games.
    static func iconRGBA(at url: URL) throws -> Data? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let fileSize = try file.seekToEnd()
        func read(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
            guard offset <= fileSize, UInt64(count) <= fileSize - offset else { return [] }
            try file.seek(toOffset: offset)
            return Array(try file.read(upToCount: count) ?? Data())
        }
        func little(_ bytes: ArraySlice<UInt8>) -> UInt64 {
            bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }
        // Homebrew .3dsx files can carry their own SMDH icon. The fixed
        // offsets are checked against the file before reading any icon bytes.
        let homebrew = try read(0, 0x2C)
        if homebrew.count == 0x2C, Array(homebrew.prefix(4)) == Array("3DSX".utf8) {
            let iconOffset = little(homebrew[0x20..<0x24])
            let iconSize = little(homebrew[0x24..<0x28])
            guard iconOffset >= 0x2C, iconSize >= 0x36C0,
                  iconOffset <= fileSize, iconSize <= fileSize - iconOffset,
                  try read(iconOffset, 4) == Array("SMDH".utf8) else { return nil }
            let tiled = try read(iconOffset + 0x24C0, 0x1200)
            return tiled.count == 0x1200 ? decodeIcon(tiled) : nil
        }
        let root = try read(0x100, 0x30)
        guard root.count == 0x30 else { return nil }
        let magic = String(bytes: root.prefix(4), encoding: .ascii)
        let base = magic == "NCSD" ? little(root[0x20..<0x24]) * 0x200 : 0
        guard magic == "NCSD" || magic == "NCCH" else { return nil }
        let header = try read(base + 0x100, 0x100)
        guard header.count == 0x100, Array(header[0..<4]) == Array("NCCH".utf8),
              header[0x8F] & 4 != 0, header[0x8E] <= 8 else { return nil }
        let unit = UInt64(0x200) << UInt64(header[0x8E])
        let exefs = base + little(header[0xA0..<0xA4]) * unit
        guard exefs > base else { return nil }
        let sections = try read(exefs, 0xA0)
        guard sections.count == 0xA0 else { return nil }
        for section in stride(from: 0, to: 0xA0, by: 16) {
            let name = String(bytes: sections[section..<section+8].prefix(while: { $0 != 0 }), encoding: .ascii)
            guard name == "icon", little(sections[section+12..<section+16]) >= 0x36C0 else { continue }
            let offset = exefs + 0x200 + little(sections[section+8..<section+12])
            guard try read(offset, 4) == Array("SMDH".utf8) else { return nil }
            let tiled = try read(offset + 0x24C0, 0x1200)
            guard tiled.count == 0x1200 else { return nil }
            return decodeIcon(tiled)
        }
        return nil
    }
    static func decodeIcon(_ bytes: [UInt8]) -> Data? {
        guard bytes.count == 48 * 48 * 2 else { return nil }
        var rgba = [UInt8](repeating: 255, count: 48 * 48 * 4)
        for y in 0..<48 { for x in 0..<48 {
            var morton = 0
            for bit in 0..<3 {
                morton |= ((x >> bit) & 1) << (bit * 2)
                morton |= ((y >> bit) & 1) << (bit * 2 + 1)
            }
            let source = (morton + (x & ~7) * 8 + (y & ~7) * 48) * 2
            let value = UInt16(bytes[source]) | UInt16(bytes[source+1]) << 8
            let target = (y * 48 + x) * 4
            let red = UInt8((value >> 11) & 31), green = UInt8((value >> 5) & 63), blue = UInt8(value & 31)
            rgba[target] = (red << 3) | (red >> 2)
            rgba[target+1] = (green << 2) | (green >> 4)
            rgba[target+2] = (blue << 3) | (blue >> 2)
        } }
        return Data(rgba)
    }
}
