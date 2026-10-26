// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@main enum GameIdentityTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let url = root.appendingPathComponent("game.3ds")
        func expectTitle(_ expected: UInt64?) throws {
            let value = try GameFileIdentity.titleID(at: url); assert(value == expected)
        }
        let title: UInt64 = 0x0004000001234500
        var ncch = Data(repeating: 0, count: 512)
        ncch.replaceSubrange(0x100..<0x104, with: Data("NCCH".utf8))
        for i in 0..<8 { ncch[0x118+i] = UInt8(truncatingIfNeeded: title >> (i*8)) }
        try ncch.write(to: url)
        try expectTitle(title)
        let ncchExtension = try GameFileIdentity.extensionForUnknownROM(at: url)
        assert(ncchExtension == "cxi")
        var ncsd = Data(repeating: 0, count: 512)
        ncsd.replaceSubrange(0x100..<0x104, with: Data("NCSD".utf8)); ncsd[0x120] = 1
        ncsd.append(ncch); try ncsd.write(to: url)
        try expectTitle(title)
        let ncsdExtension = try GameFileIdentity.extensionForUnknownROM(at: url)
        assert(ncsdExtension == "3ds")
        ncsd[0x120] = 255; try ncsd.write(to: url)
        try expectTitle(nil)
        try Data("not a game".utf8).write(to: url)
        try expectTitle(nil)
        let invalidExtension = try GameFileIdentity.extensionForUnknownROM(at: url)
        assert(invalidExtension == nil)
        var icon = [UInt8](repeating: 0, count: 0x1200)
        for i in stride(from: 0, to: icon.count, by: 2) { icon[i+1] = 0xF8 } // RGB565 red
        icon[128] = 0x1F; icon[129] = 0 // x=8,y=0 is a blue pixel
        icon[768] = 0xE0; icon[769] = 0x07 // x=0,y=8 is green
        let decoded = GameFileIdentity.decodeIcon(icon)!
        assert(Array(decoded[0..<4]) == [255,0,0,255])
        assert(Array(decoded[32..<36]) == [0,0,255,255])
        assert(Array(decoded[1536..<1540]) == [0,255,0,255])
        assert(GameFileIdentity.decodeIcon([0]) == nil)
        var container = Data(repeating: 0, count: 0x5000)
        container.replaceSubrange(0..<512, with: ncch)
        container[0x18F] = 4; container[0x1A0] = 2 // decrypted, ExeFS at 0x400
        container.replaceSubrange(0x400..<0x404, with: Data("icon".utf8))
        container[0x40C] = 0xC0; container[0x40D] = 0x36
        container.replaceSubrange(0x600..<0x604, with: Data("SMDH".utf8))
        container.replaceSubrange(0x2AC0..<0x3CC0, with: icon)
        try container.write(to: url)
        let extracted = try GameFileIdentity.iconRGBA(at: url); assert(extracted == decoded)
        container[0x18F] = 0; try container.write(to: url)
        let encrypted = try GameFileIdentity.iconRGBA(at: url); assert(encrypted == nil) // never reinterpret encrypted bytes
        var homebrew = Data(repeating: 0, count: 0x4000)
        homebrew.replaceSubrange(0..<4, with: Data("3DSX".utf8))
        homebrew[4] = 0x2C // header size
        homebrew[0x20] = 0x40 // SMDH offset
        homebrew[0x24] = 0xC0; homebrew[0x25] = 0x36 // SMDH size
        homebrew.replaceSubrange(0x40..<0x44, with: Data("SMDH".utf8))
        homebrew.replaceSubrange(0x2500..<0x3700, with: icon)
        try homebrew.write(to: url)
        let homebrewIcon = try GameFileIdentity.iconRGBA(at: url)
        assert(homebrewIcon == decoded)
        homebrew[0x25] = 0xFF // claimed SMDH length exceeds file
        try homebrew.write(to: url)
        let oversizedHomebrewIcon = try GameFileIdentity.iconRGBA(at: url)
        assert(oversizedHomebrewIcon == nil)
        print("PASS: NCCH/NCSD title IDs, bounded SMDH icons including homebrew, RGB565 decoding and encrypted-icon guard")
    }
}
