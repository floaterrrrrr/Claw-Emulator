// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum SaveKind: String, Codable, Sendable { case auto, manual }
struct SaveEntry: Codable, Identifiable, Equatable, Sendable {
    var id: Int { slot }
    let slot: Int
    var kind: SaveKind
    var name: String
    var date: Date
    var label: String { kind == .auto ? "Auto Save" : "Manual Save" }
}

struct SaveTransferError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// All directory scans, header reads, metadata writes and deletion use this actor,
// never the UI or guest worker. Existing 3DS CST and isolated retro CRS formats
// share listing/metadata only; each runtime owns its own snapshot decoding.
actor SaveStateStore {
    private let directory: URL
    init(directory: URL) { self.directory = directory }
    private func stem(_ title: UInt64) -> String { String(format: "%016llX", title) }
    func file(_ title: UInt64, _ slot: Int) -> URL {
        directory.appendingPathComponent(String(format: "%@.%02d.cst", stem(title), slot))
    }
    private func metadata(_ title: UInt64) -> URL {
        directory.appendingPathComponent(stem(title) + ".slots.json")
    }
    private func names(_ title: UInt64) throws -> [SaveEntry] {
        let url = metadata(title)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return (try? JSONDecoder().decode([SaveEntry].self, from: Data(contentsOf: url))) ?? []
    }
    func list(title: UInt64) throws -> [SaveEntry] {
        guard title != 0 else { return [] }
        let labels = try names(title)
        var result: [SaveEntry] = []
        for slot in 1...11 {
            let url = file(title, slot)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 256) ?? Data()
            guard header.count == 256 else { continue }
            let magic = Array(header.prefix(4))
            guard magic == [67, 83, 84, 27] || magic == [67, 82, 83, 1] else { continue }
            let storedTitle = (0..<8).reduce(UInt64(0)) { $0 | UInt64(header[4+$1]) << ($1*8) }
            guard storedTitle == title else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 256 else { continue }
            let time = (0..<8).reduce(UInt64(0)) { $0 | UInt64(header[32+$1]) << ($1*8) }
            let fileDate = attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: Double(time))
            let date = magic == [67, 82, 83, 1] && time > 0 ? Date(timeIntervalSince1970: Double(time)) : fileDate
            let old = labels.first { $0.slot == slot }
            result.append(SaveEntry(slot: slot, kind: slot >= 9 ? .auto : .manual,
                                    name: old?.name ?? "", date: date))
        }
        return result.sorted { $0.date > $1.date }
    }
    func preview(title: UInt64, entry: SaveEntry) throws -> URL? {
        let state = file(title, entry.slot)
        let url = URL(fileURLWithPath: state.path + ".png")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stateDate = try FileManager.default.attributesOfItem(atPath: state.path)[.modificationDate] as? Date
        let pictureDate = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        guard let stateDate, let pictureDate, pictureDate >= stateDate else { return nil }
        return url
    }
    func autosaveSlot(title: UInt64) throws -> Int {
        let entries = try list(title: title)
        if let empty = (9...11).first(where: { slot in !entries.contains { $0.slot == slot } }) { return empty }
        return entries.filter { $0.kind == .auto }.min { $0.date < $1.date }?.slot ?? 9
    }
    func record(title: UInt64, slot: Int, name: String) throws -> [SaveEntry] {
        var entries = try list(title: title)
        guard let index = entries.firstIndex(where: { $0.slot == slot }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        entries[index].name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        try JSONEncoder().encode(entries).write(to: metadata(title), options: .atomic)
        return entries
    }
    // Imports only into an unused manual slot. A malformed or mismatched file
    // cannot replace progress; the native runtime validates payload/revision
    // again before a snapshot can be restored.
    func importSnapshot(from source: URL, title: UInt64, core: Int32) throws -> [SaveEntry] {
#if os(iOS) || os(macOS)
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
#endif
        guard title != 0, (0...3).contains(core), source.pathExtension.lowercased() == "cst" else {
            throw SaveTransferError(message: "Choose a Claw save snapshot (.cst) for this game.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let slot = (1...8).first(where: { !FileManager.default.fileExists(atPath: file(title, $0).path) }) else {
            throw SaveTransferError(message: "All manual save slots are full. Export or remove a save before importing another.")
        }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".import")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var readError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: readable.path)
                let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      size > 256, size <= 256 * 1024 * 1024 else {
                    throw SaveTransferError(message: "This save file is incomplete or too large.")
                }
                try FileManager.default.copyItem(at: readable, to: temporary)
            } catch { readError = error }
        }
        if let error = coordinationError { throw error }
        if let error = readError { throw error }
        try validateTransfer(temporary, title: title, core: core)
        let destination = file(title, slot)
        try FileManager.default.moveItem(at: temporary, to: destination)
        do { return try record(title: title, slot: slot, name: "Imported save") }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    private func validateTransfer(_ source: URL, title: UInt64, core: Int32) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard attributes[.type] as? FileAttributeType == .typeRegular, size > 256, size <= 256 * 1024 * 1024 else {
            throw SaveTransferError(message: "This save file is incomplete or too large.")
        }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 256) ?? Data()
        let expected: [UInt8] = core == 0 ? [67, 83, 84, 27] : [67, 82, 83, 1]
        guard header.count == 256, Array(header.prefix(4)) == expected else {
            throw SaveTransferError(message: "This save format is not compatible with the selected game.")
        }
        func number(at offset: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { $0 | UInt64(header[offset + $1]) << ($1 * 8) }
        }
        guard number(at: 4) == title, core == 0 || number(at: 40) == UInt64(core) else {
            throw SaveTransferError(message: "This snapshot belongs to a different game or library copy.")
        }
        if core != 0 {
            guard number(at: 16) > 0, number(at: 16) <= 128 * 1024 * 1024 else {
                throw SaveTransferError(message: "This snapshot has an invalid payload size.")
            }
        }
    }
    func export(title: UInt64, entry: SaveEntry) throws -> URL {
        guard try list(title: title).contains(where: { $0.slot == entry.slot }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Claw-Save-Export", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = file(title, entry.slot)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
    func delete(title: UInt64, slot: Int) throws -> [SaveEntry] {
        guard (1...11).contains(slot) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.removeItem(at: file(title, slot))
        try? FileManager.default.removeItem(atPath: file(title, slot).path + ".png")
        let entries = try list(title: title)
        try JSONEncoder().encode(entries).write(to: metadata(title), options: .atomic)
        return entries
    }
}
