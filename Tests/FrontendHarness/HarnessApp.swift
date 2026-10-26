// SPDX-License-Identifier: GPL-3.0-or-later
// Real frontend, mocked core. No ROM, emulator performance or hardware-audio claims.
import SwiftUI
import Foundation
import UIKit
@main struct HarnessApp: App {
    @UIApplicationDelegateAdaptor(ClawAppDelegate.self) private var appDelegate
    init() {
        UserDefaults.standard.set(ConsoleLibraryInterface.modern.rawValue, forKey: "clawLibraryInterface")
        if ProcessInfo.processInfo.arguments.contains("--reset-icon-preferences") {
            for key in ["appIconMatchesAccent", "appIconColorRGB", "appIconOriginal"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        for system in [GameSystem.gb, .gbc, .gba] {
            for name in ["enabled", "screen", "opacity", "portrait", "landscape", "combos", "movement"] {
                UserDefaults.standard.removeObject(forKey: HandheldControlsConfiguration.key(system, name))
            }
            // Existing skin tests continue to exercise the skin path explicitly.
            UserDefaults.standard.set(ProcessInfo.processInfo.arguments.contains("--test-handheld-overlay"),
                forKey: HandheldControlsConfiguration.key(system, "enabled"))
        }
        try? FileManager.default.removeItem(at: DiskStore.coreDirectory.appendingPathComponent("save_states"))
        if ProcessInfo.processInfo.arguments.contains("--test-library") { prepareLibraryFixture() }
        if ProcessInfo.processInfo.arguments.contains("--test-imported-preview") { try? prepareImportedPreviewFixture() }
        for key in ["gameOrientation", "controlOpacity", "showGameStats", "largerTouchScreen", "gameVolume",
                    "controllerSkin", "atomicControllerSkin", "autosaveEnabled", "controlHaptics"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    var body: some Scene {
        WindowGroup {
            Group {
                if ProcessInfo.processInfo.arguments.contains("--test-library") { LibraryView() }
                else { HarnessRoot() }
            }.modifier(ClawStyle())
        }
    }
}
struct HarnessRoot: View {
    @State private var playing = false
    private let fixtureID = UUID(uuidString: "D62B5CB0-A48A-4323-95CB-347643312101")!
    private var platform: GameSystem {
        let value = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--fixture-system=") }?
            .replacingOccurrences(of: "--fixture-system=", with: "") ?? "3ds"
        return GameSystem(rawValue: value) ?? .threeDS
    }
    var body: some View {
        Button("Play fixture") { playing = true }.accessibilityIdentifier("playFixture")
            .fullScreenCover(isPresented: $playing) {
                GameScreen(game: Game(id: fixtureID, name: "Fixture game", fileName: "fixture." + platform.rawValue, system: platform),
                    resolution: Int(Claw3DSDefaultResolution()), cpuClock: 100, asyncShaders: true, upscaleInput: Int(Claw3DSDefaultMetalFXInput()),
                    initialStateSlot: ProcessInfo.processInfo.arguments.contains("--test-initial-restore") ? 1 : nil,
                    onExit: { playing = false })
                    .preferredColorScheme(.dark)
                    .ignoresSafeArea(.container)
                    .statusBarHidden(true)
                    .overlay(alignment: .bottom) { CoreDiagnostic().padding(.bottom, 2).allowsHitTesting(false) }
                    .interactiveDismissDisabled()
            }
    }
}
struct CoreDiagnostic: View {
    @State private var state = ""
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    var body: some View {
        Text(state).font(.system(size: 6)).foregroundStyle(.gray)
            .accessibilityIdentifier("coreSpy")
            .onReceive(timer) { _ in state = String(cString: Claw3DSTestState()) }
    }
}

// Local fixtures exercise the actual library without supplying any game ROMs.
@MainActor private func prepareLibraryFixture() {
    try? DiskStore.prepare()
    var header = Data(repeating: 0, count: 512)
    header.replaceSubrange(0x100..<0x104, with: Data("NCCH".utf8))
    let title: UInt64 = 0x0004000001234500
    for i in 0..<8 { header[0x118+i] = UInt8(truncatingIfNeeded: title >> (i*8)) }
    let id = UUID()
    // Original test artwork, not a placeholder or a copyrighted game cover.
    let artwork = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256)).pngData { context in
        UIColor(red: 0.04, green: 0.75, blue: 0.95, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        UIColor.magenta.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 32))
    }
    let cover = "library-fixture.png"
    try? artwork.write(to: DiskStore.coverDirectory.appendingPathComponent(cover), options: .atomic)
    var game = Game(id: id, name: "Orbit Quest", fileName: "library-fixture.3ds", titleID: title, coverFile: cover)
    try? header.write(to: game.url)
    var games = [game]
    if ProcessInfo.processInfo.arguments.contains("--test-carousel") {
        game.lastPlayed = Date(timeIntervalSince1970: 300); game.playedSeconds = 3600
        let gba = Game(id: UUID(), name: "Signal Runner", fileName: "carousel-fixture.gba", coverFile: cover,
            system: .gba, playedSeconds: 11460)
        let ds = Game(id: UUID(), name: "Track Sprint", fileName: "carousel-fixture.3ds", coverFile: cover, playedSeconds: 900)
        try? Data(repeating: 0, count: 512).write(to: gba.url)
        try? header.write(to: ds.url)
        games = [game, gba, ds]
    }
    try? DiskStore.saveLibrary(games)
}

// Original colored markers and transparent control artwork. No third-party skin.
@MainActor private func prepareImportedPreviewFixture() throws {
    let id = "841C391A-F8AC-4B1C-9025-2EBD2BAFD777"
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClawSkins").appendingPathComponent(id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
    let background = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 400), format: format).pngData { renderer in
        UIColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1).setFill()
        renderer.fill(CGRect(x: 0, y: 0, width: 200, height: 400))
        for (color, x, y) in [(UIColor.red, 0.0, 0.0), (.yellow, 180.0, 0.0), (.magenta, 0.0, 360.0), (.white, 180.0, 360.0)] {
            color.setFill(); renderer.fill(CGRect(x: x, y: y, width: 20, height: 40))
        }
    }
    let control = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: format).pngData { renderer in
        UIColor.green.setFill(); renderer.cgContext.fillEllipse(in: CGRect(x: 10, y: 10, width: 20, height: 20))
    }
    try background.write(to: directory.appendingPathComponent("background.png"))
    try control.write(to: directory.appendingPathComponent("control.png"))
    let definitions: [(String, Double, Double, Double, Double)] = [
        ("dpad", 10, 280, 40, 40), ("circle", 10, 240, 40, 40), ("a", 130, 280, 40, 40),
        ("b", 110, 320, 40, 40), ("x", 110, 240, 40, 40), ("y", 90, 280, 40, 40),
        ("l", 0, 220, 40, 20), ("r", 160, 220, 40, 20), ("start", 100, 370, 30, 20),
        ("select", 60, 370, 30, 20), ("menu", 170, 365, 20, 20), ("a", 160, 330, 20, 20)]
    let controls = definitions.map { key, x, y, w, h in
        DeltaSkinControl(key: key, frame: SkinRect(x: x, y: y, width: w, height: h), asset: "control.png")
    }
    let portrait = DeltaSkinVariant(width: 200, height: 400, background: "background.png",
        screens: [SkinRect(x: 20, y: 30, width: 160, height: 96), SkinRect(x: 40, y: 145, width: 120, height: 90)], controls: controls)
    let landscape = DeltaSkinVariant(width: 400, height: 200, background: "background.png",
        screens: [SkinRect(x: 20, y: 10, width: 180, height: 108), SkinRect(x: 220, y: 15, width: 144, height: 108)],
        controls: controls.map { DeltaSkinControl(key: $0.key, frame: SkinRect(x: $0.frame.x * 2, y: $0.frame.y / 2,
            width: $0.frame.width * 2, height: $0.frame.height / 2), asset: $0.asset) })
    let skin = ImportedSkin(id: id, name: "Preview layout fixture", system: .threeDS,
        variants: ["standard.portrait": portrait, "standard.landscape": landscape], warnings: [])
    try JSONEncoder().encode(skin).write(to: directory.appendingPathComponent("skin.json"), options: .atomic)
}
