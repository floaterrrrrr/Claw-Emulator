// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

struct ArchiveImportDisplay: Equatable {
    let stage: String
    let fraction: Double?
    let cancelling: Bool
}

final class ArchiveImportSession: @unchecked Sendable {
    let token: OpaquePointer
    private let lock = NSLock()
    private var stage = "Preparing archive"
    private var fraction: Double?
    private var cancelledFlag = false
    private var coordinator: NSFileCoordinator?

    init?() {
        guard let token = Claw3DSArchiveImportTokenCreate() else { return nil }
        self.token = token
    }
    deinit { Claw3DSArchiveImportTokenDestroy(token) }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledFlag
    }
    func cancel() {
        lock.lock()
        cancelledFlag = true
        stage = "Cancelling import"
        let active = coordinator
        lock.unlock()
        Claw3DSArchiveImportTokenCancel(token)
        active?.cancel()
    }
    func coordinating(with value: NSFileCoordinator?) {
        lock.lock()
        coordinator = value
        let shouldCancel = cancelledFlag
        lock.unlock()
        if shouldCancel { value?.cancel() }
    }
    func update(_ value: String, copied: UInt64 = 0, total: UInt64 = 0) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelledFlag else { return }
        stage = value
        fraction = total > 0 ? min(1, Double(copied) / Double(total)) : nil
    }
    func snapshot() -> ArchiveImportDisplay {
        lock.lock()
        let currentStage = stage, currentFraction = fraction, cancelling = cancelledFlag
        lock.unlock()
        guard !cancelling, currentStage == "Unpacking game" else {
            return ArchiveImportDisplay(stage: currentStage, fraction: currentFraction, cancelling: cancelling)
        }
        var completed: UInt64 = 0, total: UInt64 = 0
        var phase: Int32 = 0
        Claw3DSArchiveImportTokenProgress(token, &completed, &total, &phase)
        // Decoders may reread compressed input, so keep unpacking below 100%
        // until the verified game has actually been handed to the save step.
        let fraction = total > 0 ? min(phase == 2 ? 1 : 0.99,
                                      Double(completed) / Double(total)) : nil
        return ArchiveImportDisplay(stage: phase == 2 ? "Saving extracted game" : "Unpacking game",
                                    fraction: fraction, cancelling: false)
    }
}

enum DiskStore {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var gamesDirectory: URL { documents.appendingPathComponent("Games", isDirectory: true) }
    static var coreDirectory: URL { documents.appendingPathComponent("EmulationData", isDirectory: true) }
    static var coverDirectory: URL { documents.appendingPathComponent("Covers", isDirectory: true) }
    static var index: URL { documents.appendingPathComponent("library.json") }

    static func prepare() throws {
        for directory in [gamesDirectory, coverDirectory, coreDirectory, coreDirectory.appendingPathComponent("sysdata") ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    static func readLibrary() throws -> [Game] {
        try prepare()
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        return try JSONDecoder().decode([Game].self, from: Data(contentsOf: index))
    }

    static func saveLibrary(_ games: [Game]) throws {
        try JSONEncoder().encode(games).write(to: index, options: .atomic)
    }

    static func deleteGameFile(_ game: Game) throws {
        // Library metadata is decoded from disk. Never allow a malformed name
        // to turn a long-press deletion into a path outside Claw's Games folder.
        let name = game.fileName
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "The game file name is invalid."])
        }
        let url = gamesDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "The game path is not a ROM file."])
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    static func importGame(from source: URL, session: ArchiveImportSession? = nil) throws -> Game {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        try prepare()
        let ext = source.pathExtension.lowercased()
        if ext == "7z" || ext == "zip" { return try importArchive(from: source, session: session) }
        guard let system = GameSystem.identify(extension: ext) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey:
                "Choose a supported game file (.3ds, .3dsx, .cia, .nds, .gba, .gb, .gbc, .nes) or a .7z/.zip containing one supported game."])
        }
        let id = UUID()
        let fileName = "\(id.uuidString).\(ext == "cia" ? "app" : ext)"
        let destination = gamesDirectory.appendingPathComponent(fileName)
        do {
            // Drive and other File Providers may return a placeholder URL. A
            // coordinated read makes iOS fetch the selected file before copying.
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var importError: Error?
            coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                do {
                    if ext == "cia" {
                        let staged = gamesDirectory.appendingPathComponent("\(id.uuidString).partial")
                        defer { try? FileManager.default.removeItem(at: staged) }
                        switch Claw3DSExtractCIA(readable.path, staged.path) {
                        case 0:
                            guard try GameFileIdentity.titleID(at: staged) != nil else {
                                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                                    "The .cia file does not contain a playable game."])
                            }
                            try FileManager.default.moveItem(at: staged, to: destination)
                        case 2: throw CocoaError(.fileReadNoPermission, userInfo: [NSLocalizedDescriptionKey:
                            "This CIA is encrypted. Import a decrypted dump of your game."])
                        case 3: throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey:
                            "This CIA is an update, DLC, or system title. Import a base-game CIA."])
                        default: throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                            "The .cia file could not be read or does not contain a complete game."])
                        }
                    } else {
                        // FileManager streams the copy instead of loading a multi-GB game into RAM.
                        try FileManager.default.copyItem(at: readable, to: destination)
                    }
                } catch { importError = error }
            }
            if let error = coordinationError {
                // Some providers materialize the URL but fail coordination.
                try? FileManager.default.removeItem(at: destination)
                do {
                    if ext == "cia" {
                        let staged = gamesDirectory.appendingPathComponent("\(id.uuidString).partial")
                        defer { try? FileManager.default.removeItem(at: staged) }
                        guard Claw3DSExtractCIA(source.path, staged.path) == 0,
                              try GameFileIdentity.titleID(at: staged) != nil else { throw error }
                        try FileManager.default.moveItem(at: staged, to: destination)
                    } else { try FileManager.default.copyItem(at: source, to: destination) }
                } catch { throw fileProviderError(error) }
            }
            if coordinationError == nil, let error = importError {
                let description = error.localizedDescription.lowercased()
                if description.contains("helper application") || description.contains("file provider") {
                    throw fileProviderError(error)
                }
                throw error
            }
            let copiedInfo = try destination.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard copiedInfo.isRegularFile == true, (copiedInfo.fileSize ?? 0) > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var copied = destination
            try copied.setResourceValues(values)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return Game(id: id, name: source.deletingPathExtension().lastPathComponent, fileName: fileName,
                    titleID: system == .threeDS ? (try? GameFileIdentity.titleID(at: destination)) : system.saveIdentity(for: id),
                    coverFile: system == .threeDS ? CoverImporter.embeddedIcon(from: destination, gameID: id) : nil,
                    system: system)
    }

    private static func fileProviderError(_ error: Error) -> Error {
        CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey:
            "Could not read this file from its provider. In Google Drive, choose Send a copy, then Open in Claw; or save it On My iPhone first. (\(error.localizedDescription))"])
    }

    private static func copyArchive(_ source: URL, to destination: URL,
                                    session: ArchiveImportSession?) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let total = UInt64(max(0, (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        var copied: UInt64 = 0
        while true {
            if session?.isCancelled == true { throw CancellationError() }
            let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            copied += UInt64(chunk.count)
            session?.update("Copying archive from Files", copied: copied, total: total)
        }
        guard copied > 0 else { throw CocoaError(.fileReadCorruptFile) }
    }

    private static func importArchive(from source: URL, session: ArchiveImportSession?) throws -> Game {
        let localRoot = documents.deletingLastPathComponent().standardizedFileURL.path + "/"
        let alreadyLocal = source.standardizedFileURL.path.hasPrefix(localRoot)
        let localArchive = alreadyLocal ? source : FileManager.default.temporaryDirectory
            .appendingPathComponent("claw-source-\(UUID().uuidString).\(source.pathExtension)")
        defer { if !alreadyLocal { try? FileManager.default.removeItem(at: localArchive) } }
        if !alreadyLocal {
            session?.update("Getting archive from Files")
            let coordinator = NSFileCoordinator()
            session?.coordinating(with: coordinator)
            var coordinationError: NSError?
            var copyError: Error?
            coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                do { try copyArchive(readable, to: localArchive, session: session) }
                catch { copyError = error }
            }
            session?.coordinating(with: nil)
            if session?.isCancelled == true { throw CancellationError() }
            if coordinationError != nil {
                try? FileManager.default.removeItem(at: localArchive)
                do { try copyArchive(source, to: localArchive, session: session) }
                catch {
                    if error is CancellationError { throw error }
                    throw fileProviderError(error)
                }
            } else if let error = copyError {
                if error is CancellationError { throw error }
                let description = error.localizedDescription.lowercased()
                if description.contains("helper application") || description.contains("file provider") {
                    throw fileProviderError(error)
                }
                throw error
            }
        }
        if session?.isCancelled == true { throw CancellationError() }
        session?.update("Unpacking game")
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("claw-rom-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        var result: Int32 = 1
        var extractedExtension = [CChar](repeating: 0, count: 16)
        let capacity = UInt32(extractedExtension.count)
        result = Claw3DSExtractROMArchive(localArchive.path, staged.path,
                                       FileManager.default.temporaryDirectory.path, &extractedExtension,
                                       capacity, 6 * 1024 * 1024 * 1024, session?.token)
        switch result {
        case 0: break
        case 5: throw CancellationError()
        case 6: throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey:
            "This .7z uses a compression or encryption method Claw cannot unpack yet. Manic may support it; use its exported .3ds file for now."])
        case 7: throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey:
            "Claw could not find a game inside this archive. If Manic converts it to .3ds, import that exported file for now."])
        case 2: throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey:
            "This archive contains more than one supported game. Extract or share one game at a time."])
        case 3: throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey:
            "This archive needs more free storage or is too large to unpack safely. Free space or extract the ROM first, then import it into Claw."])
        case 4: throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey:
            "Could not read or unpack this archive. If it is in Google Drive, use Send a copy > Open in Claw."])
        default: throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
            "This archive does not contain one supported, unencrypted game file."])
        }
        let archivedExtension = extractedExtension.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let ext: String
        if archivedExtension == "bin" {
            guard let recognized = try GameFileIdentity.extensionForUnknownROM(at: staged) else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey:
                    "Claw unpacked the archive, but could not identify the game format inside. Import Manic's exported .3ds file for now."])
            }
            ext = recognized
        } else { ext = archivedExtension }
        if session?.isCancelled == true { throw CancellationError() }
        session?.update("Adding game to library")
        let named = staged.appendingPathExtension(ext)
        try FileManager.default.moveItem(at: staged, to: named)
        defer { try? FileManager.default.removeItem(at: named) }
        if ext == "cia" {
            let imported = try importGame(from: named)
            if session?.isCancelled == true {
                try? FileManager.default.removeItem(at: imported.url)
                throw CancellationError()
            }
            return Game(id: imported.id, name: source.deletingPathExtension().lastPathComponent,
                        fileName: imported.fileName, titleID: imported.titleID,
                        coverFile: imported.coverFile, system: imported.system)
        }
        guard let system = GameSystem.identify(extension: ext) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let id = UUID()
        let fileName = "\(id.uuidString).\(ext)"
        let destination = gamesDirectory.appendingPathComponent(fileName)
        do {
            // A move within the app container avoids copying a large extracted
            // ROM for a second time, and leaves no temporary duplicate behind.
            try FileManager.default.moveItem(at: named, to: destination)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var stored = destination
            try stored.setResourceValues(values)
            if session?.isCancelled == true { throw CancellationError() }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return Game(id: id, name: source.deletingPathExtension().lastPathComponent, fileName: fileName,
                    titleID: system == .threeDS ? (try? GameFileIdentity.titleID(at: destination)) : system.saveIdentity(for: id),
                    coverFile: system == .threeDS ? CoverImporter.embeddedIcon(from: destination, gameID: id) : nil,
                    system: system)
    }

    static func importKeys(from source: URL) throws {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        try prepare()
        var data: Data?
        var readError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do {
                let size = try readable.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size < 1_048_576 else { throw CocoaError(.fileReadCorruptFile) }
                data = try Data(contentsOf: readable)
            } catch { readError = error }
        }
        if let error = coordinationError { throw error }
        if let error = readError { throw error }
        guard let data else { throw CocoaError(.fileReadUnknown) }
        guard let text = String(data: data, encoding: .utf8), text.contains("=") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Match KEYS_FILE in the vendored core; aes_keys.txt is a legacy import filename.
        try data.write(to: coreDirectory.appendingPathComponent("sysdata/keys.txt"), options: .atomic)
    }

    static func exportSaves() throws -> URL {
        try prepare()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Claw-Saves-\(UUID().uuidString).zip")
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var copyError: Error?
        coordinator.coordinate(readingItemAt: coreDirectory, options: .forUploading,
                               error: &coordinationError) { archiveURL in
            do { try FileManager.default.copyItem(at: archiveURL, to: destination) }
            catch { copyError = error }
        }
        if let error = coordinationError { throw error }
        if let error = copyError { throw error }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileReadUnknown)
        }
        return destination
    }
}

@MainActor final class Library: ObservableObject {
    @Published var games: [Game] = []
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var importDisplay: ArchiveImportDisplay?
    private var activeArchiveImport: ArchiveImportSession?
    private var writable = true
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    // Reserve the writer across disk awaits; callers edit the latest game only
    // after acquiring it, so an import/refresh cannot erase a queued edit.
    private func beginMutation() async -> Bool {
        guard writable else {
            error = "The library could not be read. Restart Claw or restore your library backup before making changes."
            return false
        }
        if busy {
            await withCheckedContinuation { mutationWaiters.append($0) }
        } else { busy = true }
        return true
    }
    private func endMutation() {
        if mutationWaiters.isEmpty { busy = false }
        else { mutationWaiters.removeFirst().resume() }
    }

    func cancelArchiveImport() { activeArchiveImport?.cancel() }

    init() {
        do { games = try DiskStore.readLibrary() }
        catch {
            self.error = "Could not read the game library: \(error.localizedDescription)"
            writable = false
        }
    }

    func refreshIdentities() async {
        guard !busy, await beginMutation() else { return }
        defer { endMutation() }
        let original = games
        let updated = await Task.detached(priority: .utility) {
            original.map { game -> Game in
                var value = game
                if value.titleID == nil {
                    value.titleID = value.platform == .threeDS ? (try? GameFileIdentity.titleID(at: value.url))
                        : value.platform.saveIdentity(for: value.id)
                }
                if value.coverFile == nil && value.coverRemoved != true && value.platform == .threeDS {
                    value.coverFile = CoverImporter.embeddedIcon(from: value.url, gameID: value.id)
                }
                return value
            }
        }.value
        do {
            try await Task.detached(priority: .utility) { try DiskStore.saveLibrary(updated) }.value
            games = updated
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func update(id: UUID, change: (inout Game) -> Void) async -> Bool {
        guard await beginMutation() else { return false }
        defer { endMutation() }
        guard let index = games.firstIndex(where: { $0.id == id }) else {
            error = "This game is no longer in the library."
            return false
        }
        var updated = games
        change(&updated[index])
        do {
            try await Task.detached(priority: .utility) { try DiskStore.saveLibrary(updated) }.value
            games = updated
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult
    func delete(id: UUID) async -> Bool {
        guard await beginMutation() else { return false }
        defer { endMutation() }
        guard let game = games.first(where: { $0.id == id }) else {
            error = "This game is no longer in the library."
            return false
        }
        let original = games
        let remaining = games.filter { $0.id != id }
        do {
            try await Task.detached(priority: .utility) {
                try DiskStore.saveLibrary(remaining)
                do { try DiskStore.deleteGameFile(game) }
                catch {
                    try DiskStore.saveLibrary(original)
                    throw error
                }
            }.value
            games = remaining
            notice = "ROM deleted. Save data and snapshots were kept."
            if let coverName = game.coverFile, !remaining.contains(where: { $0.coverFile == coverName }),
               !coverName.contains("/"), !coverName.contains("\\"), coverName != ".", coverName != ".." {
                _ = await Task.detached(priority: .utility) {
                    let url = DiskStore.coverDirectory.appendingPathComponent(coverName)
                    if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                       values.isRegularFile == true, values.isSymbolicLink != true {
                        try? FileManager.default.removeItem(at: url)
                    }
                }.value
            }
            return true
        } catch {
            self.error = "Could not delete the ROM: \(error.localizedDescription)"
            return false
        }
    }

    func importFile(_ url: URL, keys: Bool) async {
        guard await beginMutation() else { return }
        defer { endMutation() }
        let isArchive = !keys && ["7z", "zip"].contains(url.pathExtension.lowercased())
        let session = isArchive ? ArchiveImportSession() : nil
        if isArchive && session == nil {
            error = "Could not prepare the archive import. Free some memory and try again."
            return
        }
        activeArchiveImport = session
        importDisplay = session?.snapshot()
        let observer = Task { @MainActor in
            while !Task.isCancelled {
                if let session { importDisplay = session.snapshot() }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer {
            observer.cancel()
            activeArchiveImport = nil
            importDisplay = nil
        }
        do {
            if keys {
                try await Task.detached(priority: .userInitiated) { try DiskStore.importKeys(from: url) }.value
                notice = "Console keys imported."
            } else {
                let game = try await Task.detached(priority: .userInitiated) {
                    try DiskStore.importGame(from: url, session: session)
                }.value
                if session?.isCancelled == true {
                    try? FileManager.default.removeItem(at: game.url)
                    throw CancellationError()
                }
                do {
                    let updated = games + [game]
                    try await Task.detached(priority: .utility) { try DiskStore.saveLibrary(updated) }.value
                    games = updated
                } catch {
                    try? FileManager.default.removeItem(at: game.url)
                    throw error
                }
            }
        } catch is CancellationError {
            notice = "Import cancelled."
        } catch { self.error = error.localizedDescription }
    }
}
