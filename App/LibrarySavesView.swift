// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

struct LibrarySavesView: View {
    let games: [Game]
    let store: SaveStateStore
    var revision = 0
    let onLoad: (Game, SaveEntry) -> Void
    var onSavesChanged: () -> Void = {}
    var showsBack = false
    var onTransferActivity: (Bool) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var choosingGame = false
    @State private var entries: [SaveEntry] = []
    @State private var error: String?
    @State private var deleting: SaveEntry?
    @State private var importing = false
    @State private var transferring = false
    @State private var notice: String?
    @State private var loadedTitle: UInt64?
    @AppStorage("autosaveEnabled") private var autosave = true
    @AppStorage("autosaveMinutes") private var autosaveMinutes = 5
    @Environment(\.clawAccent) private var accent
    private var selected: Game? { games.first { $0.id == selectedID } ?? games.first }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                if showsBack {
                    Button { dismiss() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44).consoleGlass() }
                        .accessibilityLabel("Back")
                }
                ConsolePageHeading(title: "Saves", subtitle: "Pick up where you left off.", symbol: "externaldrive.fill")
                if selected?.titleID != nil {
                    Button { importing = true } label: {
                        Image(systemName: "square.and.arrow.down").frame(width: 44, height: 44).consoleGlass(tint: accent)
                    }.accessibilityLabel("Import save").accessibilityIdentifier("importSave")
                        .disabled(transferring)
                }
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if transferring { ProgressView("Importing save…").font(.caption) }
            if !games.isEmpty {
                Button { choosingGame = true } label: {
                    HStack(spacing: 12) {
                        Group {
                            if let game = selected { GameCoverArtwork(game: game) }
                        }.frame(width: 44, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(selected.map { ConsoleCatalog.displayName($0.name) } ?? "Choose a game").font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer(); Image(systemName: "chevron.down")
                    }.consolePanel().foregroundStyle(.primary)
                }.disabled(transferring)
                if let game = selected, let title = game.titleID {
                    SaveHistoryView(states: entries, titleID: title, store: store,
                        onLoad: { onLoad(game, $0) }, onDelete: { deleting = $0 },
                        onUpdate: { values in
                            if selected?.titleID == title { entries = values }
                            onSavesChanged()
                        }, scrolls: false).disabled(transferring)
                } else {
                    ConsoleEmptyState(title: "Launch this game first", symbol: "gamecontroller",
                        message: "Claw will identify its save folder when it starts.")
                }
            } else {
                ConsoleEmptyState(title: "Your progress belongs here", symbol: "clock.arrow.circlepath",
                    message: "Import a game, then create a save from its in-game menu.")
            }
            Toggle(isOn: $autosave) {
                Label("Auto Save", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline)
            }.clawCard().padding(.bottom, 8)
            if autosave {
                ConsoleMinuteStepper(minutes: $autosaveMinutes).clawCard()
            }
        }.padding(.horizontal, 10).padding(.vertical, 12)
        }.background { ConsoleBackdrop() }
            .tint(accent)
            .toggleStyle(ConsoleToggleStyle())
            .toolbar(.hidden, for: .navigationBar)
            .consoleBackSwipe(enabled: showsBack) { dismiss() }
            .task(id: "\(selected?.titleID ?? 0)-\(revision)") { await refresh() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "cst") ?? .data, .data]) { result in
                guard let game = selected, let title = game.titleID else { return }
                switch result {
                case .success(let url):
                    transferring = true
                    onTransferActivity(true)
                    Task {
                        defer { transferring = false; onTransferActivity(false) }
                        do {
                            entries = try await store.importSnapshot(from: url, title: title, core: game.platform.core)
                            notice = "Imported into an unused manual slot. Existing saves were kept."
                            onSavesChanged()
                        } catch { self.error = error.localizedDescription }
                    }
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .sheet(item: $deleting) { entry in
                ClawGamePrompt(title: "Delete this save?", message: "This permanently removes this snapshot and its thumbnail.",
                    confirmTitle: "Delete", destructive: true, initialName: nil, onCancel: {}) { _ in
                    guard let title = selected?.titleID else { return }
                    InterfaceHaptics.warning()
                    Task {
                        do { entries = try await store.delete(title: title, slot: entry.slot); onSavesChanged() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            .clawMessage("Save states", message: $error)
            .sheet(isPresented: $choosingGame) {
                ConsoleGamePicker(title: "Choose a game", games: games, selected: selected?.id) { selectedID = $0 }
            }
    }
    private func refresh() async {
        guard let title = selected?.titleID else { entries = []; loadedTitle = nil; return }
        if loadedTitle != title { entries = []; notice = nil; loadedTitle = title }
        do {
            let values = try await store.list(title: title)
            guard !Task.isCancelled, selected?.titleID == title else { return }
            entries = values
        }
        catch { self.error = error.localizedDescription }
    }
}
