// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

enum ConsoleImportResult {
    case games
    case load(Game, SaveEntry)
}

struct ConsoleImportHub: View {
    let games: [Game]
    let store: SaveStateStore
    let revision: Int
    let onResult: (ConsoleImportResult) -> Void
    let onSavesChanged: () -> Void
    var onTransferActivity: (Bool) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.clawAccent) private var accent
    @State private var formats = false
    @State private var guide = false
    @State private var driveHelp = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Add to your collection").font(.title2.bold())
                            Text("Games, skins, and saves. All in one place.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                                .frame(width: 44, height: 44).consoleGlass()
                        }.accessibilityLabel("Close import")
                    }.padding(.bottom, 8)
                    Button { onResult(.games) } label: {
                        ConsoleActionTile(title: "Import games", subtitle: "Choose files from Files or iCloud Drive",
                                          symbol: "doc.badge.plus", prominent: true)
                    }.accessibilityIdentifier("importGamesFromFiles")
                    Button { driveHelp = true } label: {
                        ConsoleActionTile(title: "Google Drive", subtitle: "Choose a game from your Drive in Files",
                                          symbol: "externaldrive")
                    }.accessibilityIdentifier("importGamesFromGoogleDrive")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                        NavigationLink {
                            SkinSettingsView(games: games, showsBack: true, importOnAppear: true)
                        } label: {
                            ImportShortcut(title: "Import skin", subtitle: "Choose your controls and layout", symbol: "paintbrush.pointed")
                        }.accessibilityIdentifier("hubImportSkin")
                        NavigationLink {
                            LibrarySavesView(games: games, store: store, revision: revision,
                                onLoad: { onResult(.load($0, $1)) }, onSavesChanged: onSavesChanged,
                                showsBack: true, onTransferActivity: onTransferActivity)
                        } label: {
                            ImportShortcut(title: "Import saves", subtitle: "Bring back your saved progress", symbol: "externaldrive")
                        }.accessibilityIdentifier("hubImportSaves")
                    }
                    VStack(spacing: 12) {
                        DisclosureGroup(isExpanded: $formats) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(GameSystem.allCases) { system in
                                    LabeledContent(system.shortTitle, value: system.extensions.map { "." + $0 }.joined(separator: ", "))
                                }
                                Text("A .7z or .zip containing one supported game also works.")
                                Divider()
                                Text("Import skin files from Files. Save import accepts Claw snapshots (.cst) for the selected game.")
                                    .foregroundStyle(.secondary)
                            }.font(.caption).padding(.top, 12)
                        } label: { Label("Supported files", systemImage: "info.circle").font(.subheadline.weight(.medium)) }
                        Divider()
                        DisclosureGroup(isExpanded: $guide) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("1. Import a game from Files.")
                                Text("2. Pick its cover, then tap Play.")
                                Text("3. Choose portrait and landscape skins in Skins.")
                                Text("4. Save progress from the in-game menu. Find your snapshots in Saves.")
                            }.font(.caption).foregroundStyle(.secondary).padding(.top, 12)
                        } label: { Label("Getting started", systemImage: "book.closed").font(.subheadline.weight(.medium)) }
                    }.consolePanel()
                    Text("\(games.count) games in your library").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 4)
                }.padding(20)
            }.background { ConsoleBackdrop() }.toolbar(.hidden, for: .navigationBar)
        }.buttonStyle(ConsolePressStyle()).tint(accent)
            .alert("Import from Google Drive", isPresented: $driveHelp) {
                Button("Open Files") { onResult(.games) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("In Files, choose Browse, then Google Drive under Locations. If Drive shows a helper application error, open the ROM in Google Drive and choose Send a copy > Open in Claw.")
            }
            .presentationDragIndicator(.visible)
    }
}

private struct ImportShortcut: View {
    let title: String
    let subtitle: String
    let symbol: String
    @Environment(\.clawAccent) private var accent
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol).font(.system(size: 26, weight: .medium)).foregroundStyle(accent)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(accent)
            }
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, minHeight: 114, alignment: .topLeading)
            .padding(16)
            .consoleGlass(radius: 18, interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 18))
    }
}
