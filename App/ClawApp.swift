// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

#if !CLAW_FRONTEND_FIXTURE
@main struct ClawApp: App {
    @UIApplicationDelegateAdaptor(ClawAppDelegate.self) private var appDelegate
    var body: some Scene { WindowGroup { LibraryView().modifier(ClawStyle()) } }
}
#endif
struct SharedArchive: Identifiable { let id = UUID(); let url: URL }
struct GameLaunch: Identifiable {
    let id = UUID()
    let game: Game
    var slot: Int? = nil
    var skipAutoResume = false
}
private enum ImportTarget { case game, keys, cover(UUID) }
struct LibraryView: View {
    @StateObject private var library = Library()
    @State private var importing = false
    @State private var importTarget = ImportTarget.game
    @State private var launch: GameLaunch?
    @State private var pendingLoad: GameLaunch?
    @State private var deletingGame: Game?
    @State private var showingDeleteConfirmation = false
    @State private var archive: SharedArchive?
    @State private var exporting = false
    @State private var preparingLaunch = false
    @State private var saveRevision = 0
    @State private var resumeSlots: [UUID: Int] = [:]
    @State private var latestSaves: [UUID: SaveEntry] = [:]
    @State private var saveTransfer = false
    @AppStorage("resolution") private var resolution = 2
    @AppStorage("automaticGraphicsProfile") private var automatic = true
    @AppStorage("cpuClock") private var cpuClock = 100
    @AppStorage("metalFXInput") private var metalFX = 2
    private let store = SaveStateStore(directory: DiskStore.coreDirectory.appendingPathComponent("save_states"))
    var body: some View {
        ZStack {
            // Destroy the library subtree during gameplay. Its artwork, clock,
            // battery observation and animations cannot compete with the core.
            if launch == nil {
                ConsoleHomeView(games: library.games, busy: library.busy || preparingLaunch || saveTransfer, exporting: exporting,
                    notice: library.notice, resumeSlots: resumeSlots, saveRevision: saveRevision, store: store,
                    onImport: { openImport(.game) }, onImportKeys: { openImport(.keys) }, onExport: export,
                    onLaunch: { game, resume in
                        startGame(GameLaunch(game: game, slot: resume ? resumeSlots[game.id] : nil,
                                             skipAutoResume: !resume))
                    }, onLoad: { game, entry in pendingLoad = GameLaunch(game: game, slot: entry.slot) },
                    onFavorite: { game in
                        Task { await library.update(id: game.id) { $0.favorite = !($0.favorite ?? false) } }
                    }, onCover: { openImport(.cover($0.id)) }, onRemoveCover: removeCover,
                    onDelete: { game in deletingGame = game; showingDeleteConfirmation = true },
                    latestSaves: latestSaves, onSavesChanged: {
                        saveRevision += 1
                        Task { await refreshLatest() }
                    }, onTransferActivity: { saveTransfer = $0 })
            } else { Color.black.ignoresSafeArea() }
        }
        .background(ClawPalette.background)
        .overlay(alignment: .bottom) {
            if launch == nil, let progress = library.importDisplay {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(progress.stage).font(.subheadline.weight(.semibold))
                        if let fraction = progress.fraction {
                            HStack(spacing: 10) {
                                ProgressView(value: fraction)
                                    .accessibilityValue("\(Int(fraction * 100)) percent")
                                Text("\(Int(fraction * 100))%")
                                    .font(.caption.monospacedDigit().weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 34, alignment: .trailing)
                                    .accessibilityHidden(true)
                            }
                        } else { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
                        Text("Large games may take a few minutes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { library.cancelArchiveImport() } label: {
                        Text("Cancel").font(.subheadline.weight(.medium)).frame(minWidth: 64, minHeight: 44)
                    }
                        .disabled(progress.cancelling)
                }
                .padding(16)
                .background(ClawPalette.card, in: RoundedRectangle(cornerRadius: 18))
                .overlay { RoundedRectangle(cornerRadius: 18).stroke(ClawPalette.border) }
                .padding(.horizontal, 18)
                .padding(.bottom, 78)
                .accessibilityIdentifier("archiveImportProgress")
            }
        }
        .modifier(AppIconSync(enabled: launch == nil && !preparingLaunch))
        .fileImporter(isPresented: $importing, allowedContentTypes: importTypes) { result in
            switch result {
            case .success(let url): importFile(url)
            case .failure(let error):
                library.error = "Could not open the file provider. In Google Drive, use Send a copy > Open in Claw, or save the ROM to On My iPhone first. (\(error.localizedDescription))"
            }
        }
        .fullScreenCover(item: $launch, onDismiss: { saveRevision += 1; Task { await refreshLatest() } }) { request in
            GameScreen(game: request.game,
                resolution: automatic ? Int(Claw3DSDefaultResolution()) : resolution,
                cpuClock: automatic ? 100 : cpuClock, asyncShaders: true,
                upscaleInput: Claw3DSMetalFXSupported() ? (automatic ? Int(Claw3DSDefaultMetalFXInput()) : metalFX) : 0,
                initialStateSlot: request.slot,
                onLoaded: { title in
                    Task {
                        await library.update(id: request.game.id) { game in
                            game.titleID = title; game.lastPlayed = Date()
                        }
                    }
                }, onPlaytime: { seconds in
                    Task {
                        await library.update(id: request.game.id) { game in
                            game.playedSeconds = ConsoleCatalog.seconds(game.playedSeconds) + seconds
                        }
                    }
                }, skipAutoResume: request.skipAutoResume, onExit: { launch = nil })
                .modifier(ClawStyle()).preferredColorScheme(.dark)
                .ignoresSafeArea(.container)
                .statusBarHidden(true).interactiveDismissDisabled()
        }
        .sheet(item: $archive) { ShareSheet(url: $0.url) }
        .confirmationDialog("Delete \(deletingGame.map { ConsoleCatalog.displayName($0.name) } ?? "game")?",
            isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            if let game = deletingGame {
                Button("Delete ROM", role: .destructive) {
                    InterfaceHaptics.warning()
                    Task { await library.delete(id: game.id); await refreshLatest() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the game file from Claw. Save data and save states will stay on this device.")
        }
        .onChange(of: showingDeleteConfirmation) { _, shown in if !shown { deletingGame = nil } }
        .sheet(item: $pendingLoad) { request in
            ClawGamePrompt(title: "Load this save state?", message: "Claw will start the game and restore the selected snapshot.",
                confirmTitle: "Load", destructive: false, initialName: nil, onCancel: {}) { _ in
                startGame(request)
            }
        }
        .clawMessage("Could not complete that", message: $library.error)
        .task {
            // Earlier builds cached remote covers. Remove them once without
            // blocking the library or the emulation thread.
            Task.detached(priority: .background) {
                let preference = "removedLegacyCoverCache"
                guard !UserDefaults.standard.bool(forKey: preference) else { return }
                let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("ClawCoverArt", isDirectory: true)
                do {
                    if FileManager.default.fileExists(atPath: cache.path) {
                        try FileManager.default.removeItem(at: cache)
                    }
                    UserDefaults.standard.set(true, forKey: preference)
                } catch { /* Retry on the next launch. */ }
            }
            if metalFX == 3 { metalFX = 2 }
            await library.refreshIdentities()
            await refreshLatest()
        }
        .onOpenURL { url in
            guard url.isFileURL else { return }
            importTarget = .game
            importFile(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            // Real pressure is different from a scene transition. Drop the
            // bounded decoded-image cache while retaining local artwork files.
            Task {
                await DiskArtwork.clearLibraryCache(memoryPressure: true)
            }
        }
    }
    private func startGame(_ request: GameLaunch) {
        guard !preparingLaunch, !saveTransfer, launch == nil else { return }
        preparingLaunch = true
        Task {
            await DiskArtwork.clearLibraryCache()
            if UIApplication.shared.applicationState == .active { launch = request }
            preparingLaunch = false
        }
    }
    private var importTypes: [UTType] {
        switch importTarget {
        case .cover: return [.image]
        case .keys: return [.plainText]
        case .game: return (GameSystem.allCases.flatMap(\.extensions) + ["7z", "zip"])
                .compactMap { UTType(filenameExtension: $0) } + [.data, .archive]
        }
    }
    private func openImport(_ target: ImportTarget) { importTarget = target; importing = true }
    private func importFile(_ url: URL) {
        let target = importTarget
        Task {
            switch target {
            case .keys: await library.importFile(url, keys: true)
            case .game: await library.importFile(url, keys: false)
            case .cover(let id):
                var old: URL?
                do {
                    let file = try await Task.detached(priority: .utility) { try CoverImporter.store(source: url, gameID: id) }.value
                    let saved = await library.update(id: id) { game in
                        old = game.coverURL
                        game.coverFile = file; game.coverRemoved = false
                    }
                    let unused = saved ? old : DiskStore.coverDirectory.appendingPathComponent(file)
                    if let unused {
                        _ = await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: unused) }.value
                    }
                } catch { library.error = error.localizedDescription }
            }
            await refreshLatest()
        }
    }
    private func removeCover(_ game: Game) {
        Task {
            var old: URL?
            let saved = await library.update(id: game.id) { current in
                old = current.coverURL
                current.coverFile = nil
                current.coverRemoved = true
            }
            if saved, let old {
                _ = await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: old) }.value
            }
            await refreshLatest()
        }
    }
    private func refreshLatest() async {
        var slots: [UUID: Int] = [:]
        var entries: [UUID: SaveEntry] = [:]
        for game in library.games {
            guard let title = game.titleID, let entry = try? await store.list(title: title).first else { continue }
            slots[game.id] = entry.slot
            entries[game.id] = entry
        }
        resumeSlots = slots
        latestSaves = entries
    }
    private func export() {
        guard !exporting else { return }
        exporting = true
        Task {
            do { archive = SharedArchive(url: try await Task.detached(priority: .utility) { try DiskStore.exportSaves() }.value) }
            catch { library.error = error.localizedDescription }
            exporting = false
        }
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
