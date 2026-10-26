// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
// Path dependency only; the exact production Game Codable type is compiled.
enum DiskStore {
    static let gamesDirectory = URL(fileURLWithPath: "/tmp/Games")
    static let coverDirectory = URL(fileURLWithPath: "/tmp/Covers")
}
@main enum GameModelTests {
    static func main() throws {
        let original = Data("{\"id\":\"A8A121A9-49AB-432F-B017-6FF822C4CBDF\",\"name\":\"Orbit Quest\",\"fileName\":\"original.3ds\"}".utf8)
        var game = try JSONDecoder().decode(Game.self, from: original)
        assert(game.titleID == nil && game.coverFile == nil && game.favorite == nil && game.coverRemoved == nil)
        assert(game.url.lastPathComponent == "original.3ds" && game.name == "Orbit Quest")
        game.favorite = true; game.titleID = 0x0004000001234500
        game.lastPlayed = Date(timeIntervalSince1970: 1000); game.coverFile = "chosen.jpg"
        let roundTrip = try JSONDecoder().decode(Game.self, from: JSONEncoder().encode(game))
        assert(roundTrip.id == game.id && roundTrip.fileName == game.fileName)
        assert(roundTrip.favorite == true && roundTrip.lastPlayed == game.lastPlayed)
        assert(roundTrip.titleID == game.titleID && roundTrip.coverURL?.lastPathComponent == "chosen.jpg")
        game.coverFile = nil; game.coverRemoved = true
        let withoutCover = try JSONDecoder().decode(Game.self, from: JSONEncoder().encode(game))
        assert(withoutCover.coverURL == nil && withoutCover.coverRemoved == true)
        assert(GameSystem.identify(extension: "CIA") == .threeDS)
        assert(GameSystem.identify(extension: "3DSX") == .threeDS)
        assert(GameSystem.identify(extension: "SGB") == .gb)
        assert(GameSystem.identify(extension: "UNIF") == .nes)
        assert(GameSystem.identify(extension: "zip") == nil)
        print("PASS: existing library JSON and ROM paths migrate without data loss; title, favorite, cover and last-played round trip")
    }
}
