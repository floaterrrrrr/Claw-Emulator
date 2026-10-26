// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
enum DiskStore {
    static let gamesDirectory = URL(fileURLWithPath: "/tmp/Games")
    static let coverDirectory = URL(fileURLWithPath: "/tmp/Covers")
}
@main enum SixSystemTests {
    static func main() throws {
        let skin = try JSONDecoder().decode(ControllerSkin.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let id = UUID(uuidString: "A8A121A9-49AB-432F-B017-6FF822C4CBDF")!
        let old = Data("{\"id\":\"\(id.uuidString)\",\"name\":\"Existing game\",\"fileName\":\"old.3ds\"}".utf8)
        let legacy = try JSONDecoder().decode(Game.self, from: old)
        precondition(legacy.platform == .threeDS && legacy.fileName == "old.3ds")
        var identities = Set<UInt64>()
        let sizes = [CGSize(width: 375, height: 647), CGSize(width: 402, height: 778),
                     CGSize(width: 667, height: 354), CGSize(width: 750, height: 381), CGSize(width: 832, height: 419)]
        for system in GameSystem.allCases {
            let identity = system.saveIdentity(for: id)
            precondition(identities.insert(identity).inserted)
            precondition(identity == system.saveIdentity(for: id))
            precondition(identity != system.saveIdentity(for: UUID()))
            for ext in system.extensions { precondition(GameSystem.identify(extension: ext.uppercased()) == system) }
            let game = Game(id: id, name: "Fixture", fileName: "fixture." + system.extensions[0], titleID: identity, system: system)
            let copy = try JSONDecoder().decode(Game.self, from: JSONEncoder().encode(game))
            precondition(copy.platform == system && copy.titleID == identity)
            for size in sizes {
                let safe = CGRect(origin: CGPoint(x: 62, y: 24), size: size)
                let standard = GameplayLayout.make(in: safe, mainAspect: CGFloat(system.aspect), hasSecondScreen: system.dualScreen)
                var layouts = [standard]
                guard let themed = ControllerSkinLayout.make(skin: skin, in: safe,
                    mainAspect: CGFloat(system.aspect), hasSecondScreen: system.dualScreen, hasAnalog: system == .threeDS) else {
                    fatalError("Missing Obsidian layout for \(system) on \(size)")
                }
                layouts.append(themed.gameplay)
                for layout in layouts {
                    precondition(abs(layout.top.width / layout.top.height - system.aspect) < 0.001)
                    precondition(safe.contains(layout.top))
                    if system.dualScreen {
                        precondition(abs(layout.bottom.width / layout.bottom.height - 4.0 / 3) < 0.001)
                        precondition(safe.contains(layout.bottom) && !layout.top.intersects(layout.bottom))
                    } else { precondition(layout.bottom == .zero) }
                    for target in [layout.circle, layout.dpad, layout.face, layout.leftShoulder,
                                   layout.rightShoulder, layout.select, layout.start, layout.gear].filter({ !$0.isEmpty }) {
                        precondition(safe.contains(target) && target.width >= 44 && target.height >= 44)
                        precondition(!target.intersects(layout.top))
                        if system.dualScreen { precondition(!target.intersects(layout.bottom)) }
                    }
                }
            }
        }
        precondition(GameSystem.identify(extension: "zip") == nil)
        precondition(GameSystem.identify(extension: "snes") == nil)
        precondition(!GameSystem.gb.showsControl("x") && !GameSystem.nes.showsControl("l"))
        precondition(GameSystem.gba.showsControl("l") && GameSystem.ds.showsControl("x"))
        print("PASS: six-system identification, legacy library migration, isolated save identities, phone layouts, correct screen ratios and supported controls")
    }
}
