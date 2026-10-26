// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

private enum ConsoleTab: String {
    case library, saves, skins, settings
}

struct ConsoleHomeView: View {
    let games: [Game]
    let busy: Bool
    let exporting: Bool
    let notice: String?
    let resumeSlots: [UUID: Int]
    let saveRevision: Int
    let store: SaveStateStore
    let onImport: () -> Void
    let onImportKeys: () -> Void
    let onExport: () -> Void
    let onLaunch: (Game, Bool) -> Void
    let onLoad: (Game, SaveEntry) -> Void
    let onFavorite: (Game) -> Void
    let onCover: (Game) -> Void
    let onRemoveCover: (Game) -> Void
    let onDelete: (Game) -> Void
    var latestSaves: [UUID: SaveEntry] = [:]
    var onSavesChanged: () -> Void = {}
    var onTransferActivity: (Bool) -> Void = { _ in }
    @State private var tab = ConsoleTab.library
    @State private var importing = false
    @State private var importResult: ConsoleImportResult?
    @State private var favoritesOnly = false
    @State private var system: GameSystem?
    @State private var search = ""
    @State private var selectedGameID: UUID?
    @State private var searching = false
    @AppStorage("clawLibraryInterface") private var libraryInterface = ConsoleLibraryInterface.modern.rawValue
    @Environment(\.clawAccent) private var accent
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        // The original system tab bar. No custom dock is drawn over it.
        TabView(selection: $tab) {
            page(library: true) { wide in libraryContent(wide: wide) }
                .tag(ConsoleTab.library).tabItem { Label("Library", systemImage: "gamecontroller") }
            page { _ in
                NavigationStack {
                    LibrarySavesView(games: games, store: store, revision: saveRevision,
                        onLoad: onLoad, onSavesChanged: onSavesChanged, onTransferActivity: onTransferActivity)
                }.disabled(exporting)
            }.tag(ConsoleTab.saves).tabItem { Label("Saves", systemImage: "clock.arrow.circlepath") }
            page { _ in
                NavigationStack { SkinSettingsView(games: games) }
                    .disabled(exporting)
            }.tag(ConsoleTab.skins).tabItem { Label("Skins", systemImage: "tshirt") }
            page { _ in
                NavigationStack { ClawSettings(games: games, exporting: exporting, onImportKeys: onImportKeys, onExport: onExport) }
            }.tag(ConsoleTab.settings).tabItem { Label("Settings", systemImage: "gearshape") }
        }.tint(accent).background { ConsoleBackdrop() }.statusBarHidden(false)
            .onChange(of: tab) { _, value in
                InterfaceHaptics.dock()
                if value != .library { searching = false; search = "" }
            }
            .onChange(of: searching) { _, value in if !value { search = "" } }
            .sheet(isPresented: $importing, onDismiss: finishImport) {
                ConsoleImportHub(games: games, store: store, revision: saveRevision,
                    onResult: { result in importResult = result; importing = false },
                    onSavesChanged: onSavesChanged, onTransferActivity: onTransferActivity)
            }
    }
    private func page<Page: View>(library: Bool = false, @ViewBuilder content: @escaping (Bool) -> Page) -> some View {
        GeometryReader { geometry in
            // A keyboard-shortened portrait viewport is not landscape.
            let wide = (verticalSizeClass == .compact ||
                (geometry.size.width >= 700 && geometry.size.width > geometry.size.height)) && !typeSize.isAccessibilitySize
            VStack(spacing: 6) {
                if !library || !searching || !wide {
                    HStack(spacing: 8) {
                        ConsoleBrand()
                        Spacer(minLength: 0)
                        ConsoleStatusCapsule()
                    }.frame(height: 44)
                }
                content(wide).frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            }.padding(.horizontal, wide ? 16 : 18).padding(.top, 8).padding(.bottom, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background { ConsoleBackdrop() }
    }
    private func finishImport() {
        let result = importResult; importResult = nil
        switch result {
        case .games: onImport()
        case .load(let game, let entry): onLoad(game, entry)
        case nil: break
        }
    }
    @ViewBuilder private func libraryContent(wide: Bool) -> some View {
        if searching {
            ConsoleSearchView(games: games, busy: busy || exporting,
                resumeSlots: resumeSlots, system: $system, favoritesOnly: $favoritesOnly, search: $search,
                onClose: { searching = false }, onImport: { importing = true }, onLaunch: { game, resume in
                    selectedGameID = game.id
                    onLaunch(game, resume)
                }, onFavorite: onFavorite, onCover: onCover, onRemoveCover: onRemoveCover, onDelete: onDelete)
        } else if ConsoleLibraryInterface(rawValue: libraryInterface) == .authentic {
            ConsoleAuthenticLibrary(games: games, wide: wide, busy: busy || exporting,
                resumeSlots: resumeSlots, system: $system, favoritesOnly: $favoritesOnly,
                selectedID: $selectedGameID, onImport: { importing = true }, onSearch: { searching = true }, onLaunch: onLaunch,
                onFavorite: onFavorite, onCover: onCover, onRemoveCover: onRemoveCover, onDelete: onDelete)
        } else {
            ConsoleShelf(games: games, wide: wide, busy: busy || exporting,
                resumeSlots: resumeSlots, system: $system, favoritesOnly: $favoritesOnly,
                selectedID: $selectedGameID, onImport: { importing = true }, onSearch: { searching = true }, onLaunch: onLaunch,
                onFavorite: onFavorite, onCover: onCover, onRemoveCover: onRemoveCover,
                onDelete: onDelete, latestSaves: latestSaves)
        }
    }
}

// Search owns one field for its entire lifetime. Keyboard/rotation changes only
// resize the results viewport; they cannot replace the focused field or carousel.
private struct ConsoleSearchView: View {
    let games: [Game]
    let busy: Bool
    let resumeSlots: [UUID: Int]
    @Binding var system: GameSystem?
    @Binding var favoritesOnly: Bool
    @Binding var search: String
    let onClose: () -> Void
    let onImport: () -> Void
    let onLaunch: (Game, Bool) -> Void
    let onFavorite: (Game) -> Void
    let onCover: (Game) -> Void
    let onRemoveCover: (Game) -> Void
    let onDelete: (Game) -> Void
    @AppStorage("consoleSort") private var sortName = ConsoleSort.recent.rawValue
    @AppStorage("showLibraryPlaytime") private var showPlaytime = true
    @State private var results: [Game] = []
    @FocusState private var focused: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.clawAccent) private var accent
    var body: some View {
        VStack(spacing: 8) {
            // Leave room for results above a landscape keyboard. The same
            // systems remain available from the field's filter menu.
            if verticalSizeClass != .compact || !focused { ConsoleSystemBar(selection: $system) }
            searchField.layoutPriority(1)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if results.isEmpty {
                        VStack(spacing: 14) {
                            ConsoleEmptyState(title: games.isEmpty ? "Your library is empty" : "No matching games",
                                symbol: "magnifyingglass", message: games.isEmpty
                                    ? "Import a game to get started." : "Try another title or change your filters.", compact: true)
                            if games.isEmpty { Button("Import games", action: onImport).buttonStyle(ClawPrimaryButton()).disabled(busy) }
                        }.padding(.vertical, 16)
                    } else { ForEach(results) { game in result(game) } }
                }.padding(.vertical, 4)
            }.scrollDismissesKeyboard(.interactively).accessibilityIdentifier("searchResults")
        }.padding(.vertical, 4)
            .onAppear { rebuild() }
            .onChange(of: games) { _, _ in rebuild() }
            .onChange(of: system) { _, _ in rebuild() }
            .onChange(of: favoritesOnly) { _, _ in rebuild() }
            .onChange(of: search) { _, _ in rebuild() }
            .onChange(of: sortName) { _, _ in rebuild() }
            .task {
                await Task.yield()
                guard !Task.isCancelled else { return }
                focused = true
            }
            .onDisappear { focused = false }
            .consoleBackSwipe { focused = false; onClose() }
    }
    private func rebuild() {
        results = ConsoleCatalog.games(games, system: system, favorites: favoritesOnly, search: search,
                                       sort: ConsoleSort(rawValue: sortName) ?? .recent)
    }
    private var searchField: some View {
        HStack(spacing: 8) {
            Button { focused = false; onClose() } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }.accessibilityLabel("Back to library").accessibilityIdentifier("closeLibrarySearch")
            TextField("Search \(games.count) games", text: $search)
                .focused($focused).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).onSubmit { focused = false }
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("gameSearch")
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                    .accessibilityLabel("Clear search")
            }
            ConsoleSortMenu(selection: $sortName, count: results.count, total: games.count,
                            system: $system, favoritesOnly: $favoritesOnly)
        }.padding(.horizontal, 12).consoleGlass(radius: 16)
    }
    private func result(_ game: Game) -> some View {
        Button { focused = false; onLaunch(game, true) } label: {
            HStack(spacing: 12) {
                GameCoverArtwork(game: game, fill: false).frame(width: 44, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 4) {
                    Text(ConsoleCatalog.displayName(game.name)).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(game.platform.title).font(.caption).foregroundStyle(.secondary)
                    if showPlaytime {
                        Text(ConsoleCatalog.playtime(game.playedSeconds) + " played").font(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "play.fill").font(.caption).foregroundStyle(accent)
            }.foregroundStyle(.primary).padding(12)
                .background(ClawPalette.subtleFill, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(ConsolePressStyle()).disabled(busy)
            .accessibilityLabel("\(game.name), \(game.platform.title)")
            .accessibilityHint("Play or continue. Hold for game options.")
            .contextMenu {
                if resumeSlots[game.id] != nil { Button("Start from boot", systemImage: "power") { focused = false; onLaunch(game, false) } }
                ConsoleGameActions(game: game, onFavorite: onFavorite, onCover: onCover,
                                   onRemoveCover: onRemoveCover, onDelete: onDelete)
            }
    }
}

private struct ConsoleShelf: View {
    let games: [Game]
    let wide: Bool
    let busy: Bool
    let resumeSlots: [UUID: Int]
    @Binding var system: GameSystem?
    @Binding var favoritesOnly: Bool
    @Binding var selectedID: UUID?
    let onImport: () -> Void
    let onSearch: () -> Void
    let onLaunch: (Game, Bool) -> Void
    let onFavorite: (Game) -> Void
    let onCover: (Game) -> Void
    let onRemoveCover: (Game) -> Void
    let onDelete: (Game) -> Void
    var latestSaves: [UUID: SaveEntry] = [:]
    @State private var visible: [Game] = []
    @State private var recent: [Game] = []
    @State private var hoveredID: UUID?
    @State private var revealedPlaytime: UUID?
    @State private var allGames = false
    @State private var browsingRecent = false
    @AppStorage("consoleSort") private var sortName = ConsoleSort.recent.rawValue
    @AppStorage("showLibraryPlaytime") private var showPlaytime = true
    @AppStorage("libraryHaptics") private var haptics = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.clawAccent) private var accent
    private var selected: Game? { visible.first { $0.id == selectedID } ?? visible.first }
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88) }

    var body: some View {
        GeometryReader { geometry in
            if wide {
                VStack(spacing: 6) {
                    filters
                    if visible.isEmpty { empty }
                    else {
                        let filterHeight = typeSize >= .xxLarge ? ConsoleSystemBarLayout.largeTextHeight : ConsoleSystemBarLayout.regularHeight
                        let side = max(32, min(300, geometry.size.height - 89 - filterHeight))
                        carousel(side: side, viewportWidth: geometry.size.width)
                    }
                    Spacer(minLength: 0)
                    Divider()
                    landscapeActions
                }
            } else if typeSize.isAccessibilitySize || geometry.size.height < 400 {
                ScrollView {
                    VStack(spacing: 12) {
                        filters
                        if let game = selected {
                            carousel(side: min(220, geometry.size.width * 0.7), viewportWidth: geometry.size.width)
                            gameDetails(game)
                            launchActions(game)
                        } else { empty }
                        portraitActions
                        recentGames
                    }.padding(.vertical, 6)
                }
            } else {
                let layout = ConsolePortraitLayout(width: geometry.size.width, height: geometry.size.height,
                    hasRecent: !recent.isEmpty,
                    hasResume: selected.map { resumeSlots[$0.id] != nil } ?? false, largeText: typeSize >= .xxLarge)
                VStack(spacing: 5) {
                    filters.frame(height: layout.filterHeight)
                    if let game = selected {
                        carousel(side: layout.coverSide, viewportWidth: geometry.size.width)
                        gameDetails(game).frame(height: 46)
                        launchActions(game)
                    } else { empty.frame(maxHeight: .infinity) }
                    portraitActions.frame(height: 44)
                    if layout.showRecent { compactRecent.frame(height: 80) }
                    Spacer(minLength: 0)
                }.padding(.vertical, 4)
            }
        }
        .onAppear { rebuild() }
        .onChange(of: games) { _, _ in rebuild() }
        .onChange(of: system) { _, _ in rebuild() }
        .onChange(of: favoritesOnly) { _, _ in rebuild() }
        .onChange(of: sortName) { _, _ in rebuild() }
        .sensoryFeedback(.selection, trigger: selectedID) { _, value in haptics && value != nil }
        .sheet(isPresented: $allGames) { allGamesSheet }
    }
    private func rebuild() {
        visible = ConsoleCatalog.games(games, system: system, favorites: favoritesOnly, search: "",
                                       sort: ConsoleSort(rawValue: sortName) ?? .recent)
        recent = Array(ConsoleCatalog.games(games.filter { $0.lastPlayed != nil }, system: nil,
                                            favorites: false, search: "", sort: .recent))
        if !visible.contains(where: { $0.id == selectedID }) { selectedID = visible.first?.id }
        hoveredID = nil
        revealedPlaytime = nil
    }
    private var filters: some View {
        ConsoleSystemBar(selection: $system)
    }
    private var empty: some View {
        VStack(spacing: 12) {
            ConsoleEmptyState(title: games.isEmpty ? "Your next adventure starts here" : "No matching games",
                symbol: "gamecontroller", message: games.isEmpty
                    ? "Import a supported game from Files."
                    : "Try another system, search or favorites filter.", compact: wide)
            if games.isEmpty {
                Button("Import games", action: onImport).buttonStyle(ClawPrimaryButton())
            }
        }.frame(maxWidth: .infinity, minHeight: wide ? 80 : 200)
    }
    private func carousel(side: CGFloat, viewportWidth: CGFloat) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .center, spacing: wide ? 14 : 8) {
                ForEach(visible) { game in
                    cover(game, side: side).overlay(alignment: .bottomTrailing) {
                        if showPlaytime && game.id == (hoveredID ?? revealedPlaytime) {
                            ConsolePlaytimeBadge(seconds: game.playedSeconds).padding(8)
                        }
                    }.frame(width: side).id(game.id)
                        .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                            content
                                .scaleEffect(reduceMotion || wide ? 1 : 1 - abs(phase.value) * 0.16)
                                .rotation3DEffect(.degrees(reduceMotion || wide ? 0 : phase.value * -22),
                                                  axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                                .offset(y: reduceMotion || wide ? 0 : abs(phase.value) * 12)
                                .opacity(reduceMotion || wide ? 1 : 1 - abs(phase.value) * 0.22)
                        }
                }
            }.scrollTargetLayout()
                .padding(.vertical, 10)
        }.contentMargins(.horizontal, wide ? 4 : max(4, (viewportWidth - side) / 2), for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $selectedID, anchor: wide ? .leading : .center)
            .scrollIndicators(.hidden).frame(height: side + 20)
            .accessibilityIdentifier("gameCarousel")
    }
    private func cover(_ game: Game, side: CGFloat) -> some View {
        Button { withAnimation(motion) { selectedID = game.id; revealedPlaytime = game.id } } label: {
            GameCoverArtwork(game: game, fill: false).frame(width: side - 8, height: side - 8)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(4)
                .background(ClawPalette.card, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(game.id == selectedID ? accent : ClawPalette.border,
                                                                                        lineWidth: game.id == selectedID ? 2 : 0.8))
                .consoleNeon(accent, active: game.id == selectedID)
        }.buttonStyle(ConsolePressStyle())
            .accessibilityLabel("\(game.name), \(game.platform.title)")
            .accessibilityValue(showPlaytime ? "Time played \(ConsoleCatalog.playtime(game.playedSeconds))" : "")
            .accessibilityHint("Select, then use Play or Continue. Hold for game options.")
            .accessibilityAddTraits(game.id == selectedID ? .isSelected : [])
            .accessibilityAction(named: "Play") { onLaunch(game, true) }
            .onHover { hovering in hoveredID = hovering ? game.id : nil }
            .contextMenu { gameActions(game) }
    }
    private func gameDetails(_ game: Game) -> some View {
        VStack(spacing: 3) {
            Text(ConsoleCatalog.displayName(game.name))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 7) {
                Text(game.platform.title)
                if showPlaytime {
                    Text("·")
                    Label(ConsoleCatalog.playtime(game.playedSeconds) + " played", systemImage: "clock")
                }
            }.font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
    }
    private func saveCaption(_ game: Game) -> String {
        if let entry = latestSaves[game.id] {
            return "Last save · " + entry.date.formatted(.relative(presentation: .named))
        }
        return "Save available"
    }
    private func launchActions(_ game: Game) -> some View {
        VStack(spacing: 0) {
            primaryLaunch(game).frame(height: resumeSlots[game.id] == nil ? 48 : 44)
            if resumeSlots[game.id] != nil {
                HStack(spacing: 8) {
                    Text(saveCaption(game)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { onLaunch(game, false) } label: {
                        Label("Start from boot", systemImage: "power")
                            .font(.system(size: 10, weight: .medium)).padding(.horizontal, 12)
                            .frame(height: 28).consoleGlass().frame(minHeight: 44)
                    }.buttonStyle(ConsolePressStyle()).disabled(busy)
                        .accessibilityIdentifier("startFromBoot")
                }.frame(height: 44)
            }
        }.padding(.horizontal, 18)
    }
    private func primaryLaunch(_ game: Game) -> some View {
        Button { onLaunch(game, true) } label: {
            Label(resumeSlots[game.id] == nil && game.lastPlayed == nil ? "Play" : "Continue", systemImage: "play.fill")
                .font(.headline).foregroundStyle(accent.clawReadableLabel)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(accent, in: Capsule())
        }.buttonStyle(ConsolePressStyle()).disabled(busy).accessibilityIdentifier("continueGame")
    }
    private var landscapeActions: some View {
        HStack(spacing: 12) {
            importButton
            Button(action: onSearch) { Image(systemName: "magnifyingglass").frame(width: 44, height: 44).consoleGlass() }
                .accessibilityLabel("Search games").accessibilityIdentifier("consoleSearch")
            if let game = selected {
                Button { onFavorite(game) } label: {
                    Image(systemName: game.favorite == true ? "heart.fill" : "heart")
                        .foregroundStyle(game.favorite == true ? accent : .primary)
                        .frame(width: 44, height: 44).consoleGlass()
                }.buttonStyle(ConsolePressStyle()).accessibilityLabel("Toggle favorite for \(game.name)")
                Spacer(minLength: 0)
                Menu {
                    gameActions(game)
                    Toggle("Favorites only", isOn: $favoritesOnly)
                    Button("All games") { browsingRecent = false; allGames = true }
                    sortOptions
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44).consoleGlass()
                }.accessibilityLabel("Game and sorting options")
                primaryLaunch(game).frame(maxWidth: 240)
            } else { Spacer() }
        }
    }
    private var portraitActions: some View {
        HStack(spacing: 8) {
            importButton
            Button { favoritesOnly.toggle() } label: {
                Label("Favorites", systemImage: favoritesOnly ? "heart.fill" : "heart")
                    .foregroundStyle(favoritesOnly ? accent : .primary)
                    .font(.caption).padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 44).consoleGlass()
            }.buttonStyle(ConsolePressStyle()).accessibilityAddTraits(favoritesOnly ? .isSelected : [])
            Button(action: onSearch) {
                Label("Search", systemImage: "magnifyingglass").font(.caption)
                    .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 44).consoleGlass()
            }.buttonStyle(ConsolePressStyle()).accessibilityIdentifier("consoleSearch")
        }
    }
    private var importButton: some View {
        Button(action: onImport) {
            Label("Import", systemImage: "plus").font(.caption.weight(.medium))
                .padding(.horizontal, 18).frame(minHeight: 44).consoleGlass()
        }.buttonStyle(ConsolePressStyle()).disabled(busy).accessibilityIdentifier("importGame")
    }
    @ViewBuilder private var recentGames: some View {
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recently played").font(.headline).accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(Array(recent.prefix(6))) { game in
                            Button {
                                system = nil; favoritesOnly = false
                                rebuild()
                                withAnimation(motion) { selectedID = game.id }
                            } label: {
                                HStack(spacing: 8) {
                                    GameCoverArtwork(game: game).frame(width: 52, height: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: 7))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(ConsoleCatalog.displayName(game.name)).font(.caption.weight(.semibold)).lineLimit(2)
                                        Text(game.platform.shortTitle).font(.caption2).foregroundStyle(.secondary)
                                    }.frame(width: 108, alignment: .leading)
                                }.padding(8).consoleGlass(radius: 14)
                            }.buttonStyle(ConsolePressStyle()).contextMenu { gameActions(game) }
                        }
                    }
                }.scrollIndicators(.hidden)
            }
        }
    }
    private var compactRecent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recently played").font(.caption.weight(.semibold))
                Spacer()
                Button { browsingRecent = true; allGames = true } label: {
                    Label("See all", systemImage: "chevron.right").font(.system(size: 10, weight: .medium))
                }.accessibilityLabel("See all games")
            }.frame(height: 18)
            HStack(spacing: 8) {
                ForEach(Array(recent.prefix(2))) { game in
                    Button {
                        system = nil; favoritesOnly = false; rebuild()
                        withAnimation(motion) { selectedID = game.id }
                    } label: {
                        HStack(spacing: 7) {
                                    GameCoverArtwork(game: game).frame(width: 42, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(ConsoleCatalog.displayName(game.name)).font(.caption2.weight(.semibold)).lineLimit(2)
                                Text(game.platform.title).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                                if showPlaytime {
                                    Label(ConsoleCatalog.playtime(game.playedSeconds), systemImage: "clock")
                                        .font(.system(size: 9)).foregroundStyle(accent)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(6).consoleGlass(radius: 12)
                    }.buttonStyle(ConsolePressStyle())
                        .contextMenu { gameActions(game) }
                }
            }.frame(height: 56)
        }
    }
    private var sortOptions: some View {
        Picker("Sort games", selection: $sortName) {
            ForEach(ConsoleSort.allCases) { Text($0.title).tag($0.rawValue) }
        }
    }
    @ViewBuilder private func gameActions(_ game: Game) -> some View {
        if resumeSlots[game.id] != nil { Button("Start from boot") { onLaunch(game, false) } }
        ConsoleGameActions(game: game, onFavorite: onFavorite, onCover: onCover,
                           onRemoveCover: onRemoveCover, onDelete: onDelete)
    }
    private var allGamesSheet: some View {
        NavigationStack {
            ConsoleSettingsPage(title: browsingRecent ? "Recently played" : "All games",
                subtitle: "\((browsingRecent ? recent : visible).count) games", symbol: "square.grid.2x2.fill", closeLabel: "Done") {
                if !browsingRecent {
                    ConsoleSortMenu(selection: $sortName, count: visible.count, total: games.count,
                                    showsLabel: true, system: $system, favoritesOnly: $favoritesOnly)
                }
                if (browsingRecent ? recent : visible).isEmpty {
                    ConsoleEmptyState(title: "No matching games", symbol: "gamecontroller",
                        message: "Choose another system or turn off Favorites in Sort & filter.")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 240 : 140), spacing: 14)], spacing: 14) {
                    ForEach(browsingRecent ? recent : visible) { game in
                        Button {
                            allGames = false
                            if browsingRecent { system = nil; favoritesOnly = false; rebuild() }
                            withAnimation(motion) { selectedID = game.id }
                        } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                GameCoverArtwork(game: game, fill: false).aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                Text(ConsoleCatalog.displayName(game.name)).font(.subheadline.weight(.semibold))
                                    .lineLimit(2, reservesSpace: true).frame(maxWidth: .infinity, alignment: .leading)
                                HStack {
                                    Text(game.platform.shortTitle).font(.caption2.weight(.semibold)).foregroundStyle(accent)
                                        .padding(.horizontal, 9).padding(.vertical, 5)
                                        .background(accent.opacity(0.12), in: Capsule())
                                    Spacer(minLength: 0)
                                    if selectedID == game.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(accent).accessibilityHidden(true)
                                    }
                                }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(ClawPalette.card, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
                                    .strokeBorder(selectedID == game.id ? accent.opacity(0.65) : ClawPalette.border, lineWidth: 0.8))
                                .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                        }.buttonStyle(ConsolePressStyle()).contextMenu { gameActions(game) }
                    }
                }
            }
        }
    }
}
