// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
protocol ObservableObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
struct ArchiveImportDisplay {
    let stage: String
    let fraction: Double?
    let cancelling: Bool
}
final class ArchiveImportSession: @unchecked Sendable {
    init?() {}
    var isCancelled: Bool { false }
    func cancel() {}
    func snapshot() -> ArchiveImportDisplay {
        ArchiveImportDisplay(stage: "Preparing archive", fraction: nil, cancelling: false)
    }
}
// Only the platform disk/image services are substituted; Library is the actual
// production class, including its writer queue and error handling.
final class LibraryDiskFixture: @unchecked Sendable {
    let lock = NSLock()
    var values: [Game] = []
    var failWrite = false
    var failRead = false
    var failDelete = false
    var deletedFiles: [String] = []
    func read() throws -> [Game] {
        try lock.withLock {
            if failRead { throw CocoaError(.fileReadCorruptFile) }
            return values
        }
    }
    func save(_ games: [Game]) throws {
        Thread.sleep(forTimeInterval: 0.02)
        try lock.withLock {
            if failWrite { throw CocoaError(.fileWriteOutOfSpace) }
            values = games
        }
    }
}
enum DiskStore {
    static let fixture = LibraryDiskFixture()
    static let gamesDirectory = URL(fileURLWithPath: "/tmp")
    static let coverDirectory = gamesDirectory
    static func readLibrary() throws -> [Game] { try fixture.read() }
    static func saveLibrary(_ games: [Game]) throws { try fixture.save(games) }
    static func deleteGameFile(_ game: Game) throws {
        try fixture.lock.withLock {
            if fixture.failDelete { throw CocoaError(.fileWriteNoPermission) }
            fixture.deletedFiles.append(game.fileName)
        }
    }
    static func importKeys(from: URL) throws {}
    static func importGame(from: URL, session: ArchiveImportSession? = nil) throws -> Game {
        throw CocoaError(.fileReadUnknown)
    }
}
enum GameFileIdentity { static func titleID(at: URL) throws -> UInt64 { 100 } }
enum CoverImporter { static func embeddedIcon(from: URL, gameID: UUID) -> String? { "embedded.png" } }
@main enum LibraryEditTests {
    @MainActor static func main() async throws {
        let game = Game(id: UUID(), name: "Fixture", fileName: "game.gba", system: .gba)
        DiskStore.fixture.values = [game]
        let library = Library()
        async let refresh: Void = library.refreshIdentities()
        while !library.busy { await Task.yield() }
        async let favorite = library.update(id: game.id) { $0.favorite = true }
        async let cover = library.update(id: game.id) { $0.coverFile = "chosen.jpg" }
        async let played = library.update(id: game.id) { $0.lastPlayed = Date(timeIntervalSince1970: 42) }
        await refresh
        let results = await (favorite, cover, played)
        precondition(results.0 && results.1 && results.2 && !library.busy)
        let saved = try DiskStore.readLibrary()[0]
        precondition(saved.favorite == true && saved.coverFile == "chosen.jpg")
        precondition(saved.titleID != nil && saved.lastPlayed == Date(timeIntervalSince1970: 42))
        DiskStore.fixture.lock.withLock { DiskStore.fixture.failWrite = true }
        let failed = await library.update(id: game.id) { $0.coverFile = nil; $0.coverRemoved = true }
        precondition(!failed && library.error != nil && library.games[0].coverFile == "chosen.jpg")
        DiskStore.fixture.lock.withLock { DiskStore.fixture.failWrite = false }
        let removed = await library.update(id: game.id) { $0.coverFile = nil; $0.coverRemoved = true }
        precondition(removed)
        let reopened = Library()
        precondition(reopened.games[0].coverURL == nil && reopened.games[0].coverRemoved == true)
        DiskStore.fixture.lock.withLock { DiskStore.fixture.failWrite = true }
        let failedWriteDelete = await library.delete(id: game.id)
        precondition(!failedWriteDelete && library.games.count == 1)
        precondition(DiskStore.fixture.lock.withLock { DiskStore.fixture.deletedFiles.isEmpty })
        DiskStore.fixture.lock.withLock { DiskStore.fixture.failWrite = false }
        DiskStore.fixture.lock.withLock { DiskStore.fixture.failDelete = true }
        let failedDelete = await library.delete(id: game.id)
        let afterFailedDelete = try DiskStore.readLibrary()
        precondition(!failedDelete && library.games.count == 1 && afterFailedDelete.count == 1)
        DiskStore.fixture.lock.withLock { DiskStore.fixture.failDelete = false }
        let deleted = await library.delete(id: game.id)
        let afterDelete = try DiskStore.readLibrary()
        precondition(deleted && library.games.isEmpty && afterDelete.isEmpty)
        precondition(DiskStore.fixture.lock.withLock { DiskStore.fixture.deletedFiles == [game.fileName] })
        DiskStore.fixture.lock.withLock { DiskStore.fixture.failRead = true }
        let unreadable = Library()
        unreadable.error = nil
        let rejected = await unreadable.update(id: game.id) { $0.favorite = false }
        precondition(!rejected && unreadable.error != nil)
        print("PASS: queued library edits persist; failed deletions preserve metadata and ROMs; confirmed deletion removes the ROM while saves remain")
    }
}
