// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@main enum Tests {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("states")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SaveStateStore(directory: directory), title: UInt64 = 0x4000000055E00
        func fixture(_ slot: Int) throws {
            var data = Data(repeating: 0, count: 257)
            data.replaceSubrange(0..<4, with: [67,83,84,27])
            for index in 0..<8 { data[4+index] = UInt8(truncatingIfNeeded: title >> (index*8)) }
            try data.write(to: directory.appendingPathComponent(String(format: "%016llX.%02d.cst",title,slot)))
        }
        let empty = try await store.list(title: title); assert(empty.isEmpty)
        try fixture(1)
        let manual = try await store.record(title: title, slot: 1, name: " Route 2 ")
        assert(manual.count == 1 && manual[0].name == "Route 2" && manual[0].kind == .manual)
        try fixture(2)
        let twoSlots = try await store.record(title: title, slot: 2, name: "Santalune")
        assert(twoSlots.first { $0.slot == 1 }?.name == "Route 2")
        assert(twoSlots.first { $0.slot == 2 }?.name == "Santalune")
        let overwritten = try await store.record(title: title, slot: 1, name: String(repeating: "x", count: 80))
        assert(overwritten.first { $0.slot == 1 }?.name.count == 64)
        let firstAuto = try await store.autosaveSlot(title: title); assert(firstAuto == 9)
        for slot in 9...11 { try fixture(slot) }
        let entries = try await store.list(title: title)
        assert(entries.filter { $0.kind == .auto }.count == 3)
        let rotating = try await store.autosaveSlot(title: title); assert((9...11).contains(rotating))
        for slot in 9...11 {
            let url = directory.appendingPathComponent(String(format: "%016llX.%02d.cst",title,slot))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(slot))], ofItemAtPath: url.path)
        }
        let oldest = try await store.autosaveSlot(title: title); assert(oldest == 9)
        let metadata = directory.appendingPathComponent(String(format: "%016llX.slots.json",title))
        try Data("invalid JSON".utf8).write(to: metadata)
        let recovered = try await store.list(title: title); assert(recovered.count == 5)
        let exported = try await store.export(title: title, entry: manual[0])
        let originalBytes = try Data(contentsOf: await store.file(title, 1))
        let exportedBytes = try Data(contentsOf: exported)
        assert(exportedBytes == originalBytes)
        let imported = try await store.importSnapshot(from: exported, title: title, core: 0)
        assert(imported.first { $0.slot == 3 }?.name == "Imported save")
        let preservedBytes = try Data(contentsOf: await store.file(title, 1))
        let importedBytes = try Data(contentsOf: await store.file(title, 3))
        assert(preservedBytes == originalBytes && importedBytes == originalBytes)
        assert(imported.filter { $0.kind == .auto }.count == 3)
        _ = try await store.record(title: title, slot: 3, name: "Before the boss")
        let reopened = try await SaveStateStore(directory: directory).list(title: title)
        assert(reopened.first { $0.slot == 3 }?.name == "Before the boss")
        for invalidCore: Int32 in [-1, 1] {
            do { _ = try await store.importSnapshot(from: exported, title: title, core: invalidCore); assertionFailure("Wrong emulator accepted") }
            catch {}
        }
        do { _ = try await store.importSnapshot(from: exported, title: title + 1, core: 0); assertionFailure("Wrong game accepted") }
        catch {}
        for slot in 4...8 { try fixture(slot) }
        do { _ = try await store.importSnapshot(from: exported, title: title, core: 0); assertionFailure("A full manual slot set must not be overwritten") }
        catch {}
        let afterFullImport = try Data(contentsOf: await store.file(title, 3))
        assert(afterFullImport == originalBytes)
        let shortFile = directory.appendingPathComponent("incomplete.cst")
        try Data(repeating: 0, count: 100).write(to: shortFile)
        do { _ = try await store.importSnapshot(from: shortFile, title: title, core: 0); assertionFailure("Truncated state accepted") }
        catch {}
        let emptyTitle = try await store.list(title: 0); assert(emptyTitle.isEmpty)
        let other = try await store.list(title: title+1); assert(other.isEmpty)
        let snapshot = await store.file(title, 1)
        let preview = URL(fileURLWithPath: snapshot.path + ".png")
        try Data([137,80,78,71]).write(to: preview)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: snapshot.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 900)], ofItemAtPath: preview.path)
        let stale = try await store.preview(title: title, entry: manual[0]); assert(stale == nil)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1100)], ofItemAtPath: preview.path)
        let current = try await store.preview(title: title, entry: manual[0]); assert(current == preview)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1200)], ofItemAtPath: snapshot.path)
        let staleAfterOverwrite = try await store.preview(title: title, entry: manual[0]); assert(staleAfterOverwrite == nil)
        let deleted = try await store.delete(title: title, slot: 1); assert(!deleted.contains { $0.slot == 1 })
        assert(!FileManager.default.fileExists(atPath: preview.path))
        let retroTitle: UInt64 = 0xC100000000000001
        let retroFile = await store.file(retroTitle, 1)
        var retro = Data(repeating: 0, count: 257)
        retro.replaceSubrange(0..<4, with: [67,82,83,1])
        for index in 0..<8 { retro[4+index] = UInt8(truncatingIfNeeded: retroTitle >> (index*8)) }
        let timestamp = UInt64(Date().timeIntervalSince1970) - 100
        for index in 0..<8 { retro[32+index] = UInt8(truncatingIfNeeded: timestamp >> (index*8)) }
        try retro.write(to: retroFile)
        let retroStates = try await store.list(title: retroTitle)
        assert(retroStates.count == 1 && retroStates[0].slot == 1)
        assert(abs(retroStates[0].date.timeIntervalSince1970 - Double(timestamp)) < 1)
        // A filename with the right title must not expose another game's state.
        retro[4] ^= 0x20
        try retro.write(to: retroFile)
        let wrongTitle = try await store.list(title: retroTitle); assert(wrongTitle.isEmpty)
        print("PASS: preview association/stale overwrite/deletion, CST/CRS discovery, persistent renames, export/import round-trip, unused-slot imports, full-slot/wrong-game/wrong-core/truncated rejection, rotating autosaves and embedded timestamps")
    }
}
