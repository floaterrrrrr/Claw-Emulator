// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

// An alternate system-first library. It shares the real game/save services and
// the pinned app header; it never launches a core to generate a preview.
struct ConsoleAuthenticLibrary: View {
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
    @State private var visible: [Game] = []
    @AppStorage("consoleSort") private var sortName = ConsoleSort.recent.rawValue
    @AppStorage("showLibraryPlaytime") private var showPlaytime = true
    @AppStorage("libraryHaptics") private var haptics = true
    @Environment(\.clawAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    private var selected: Game? { visible.first { $0.id == selectedID } ?? visible.first }
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9) }

    var body: some View {
        VStack(spacing: 8) {
            if typeSize.isAccessibilitySize {
                ScrollView {
                    VStack(spacing: 12) {
                        systemStrip
                        if let selected { detail(selected, landscape: false).frame(height: 280) }
                        listHeading
                        LazyVStack(spacing: 6) { rows }
                        footer
                    }
                }
            } else if wide {
                GeometryReader { geometry in
                    HStack(spacing: 12) {
                        ScrollView {
                            VStack(spacing: 8) { systemChoices }
                                .padding(.vertical, 6).padding(.horizontal, 3)
                        }.scrollIndicators(.hidden).frame(width: typeSize >= .xxLarge ? 140 : 100)
                        VStack(spacing: 8) { listHeading; gameList; footer }
                            .frame(width: max(170, geometry.size.width * 0.34))
                        if let selected { detail(selected, landscape: true) }
                        else { empty }
                    }
                }
            } else {
                systemStrip
                if let selected { detail(selected, landscape: false).frame(height: 174) }
                listHeading
                gameList
                footer
            }
        }.padding(.vertical, 4)
            .accessibilityIdentifier("authenticLibrary")
            .onAppear { rebuild() }
            .onChange(of: games) { _, _ in rebuild() }
            .onChange(of: system) { _, _ in rebuild() }
            .onChange(of: favoritesOnly) { _, _ in rebuild() }
            .onChange(of: sortName) { _, _ in rebuild() }
            .sensoryFeedback(.selection, trigger: selectedID) { _, value in haptics && value != nil }
    }
    private func rebuild() {
        visible = ConsoleCatalog.games(games, system: system, favorites: favoritesOnly,
            search: "", sort: ConsoleSort(rawValue: sortName) ?? .recent)
        if !visible.contains(where: { $0.id == selectedID }) { selectedID = visible.first?.id }
    }
    private var systemStrip: some View { ConsoleSystemBar(selection: $system) }
    @ViewBuilder private var systemChoices: some View {
        systemChoice(nil)
        ForEach(GameSystem.allCases) { systemChoice($0) }
    }
    private func systemChoice(_ value: GameSystem?) -> some View {
        ConsoleSystemChoice(value: value, selected: system == value,
            width: typeSize >= .xxLarge ? 132 : 92, height: typeSize >= .xxLarge ? 76 : 60) {
                withAnimation(motion) { system = value }
            }.id(value?.rawValue ?? "all")
    }
    private var listHeading: some View {
        HStack(spacing: 8) {
            Text(system?.title ?? "All systems").font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
            Button { favoritesOnly.toggle() } label: {
                Image(systemName: favoritesOnly ? "heart.fill" : "heart")
                    .foregroundStyle(favoritesOnly ? accent : .secondary).frame(width: 44, height: 44)
            }.accessibilityLabel("Favorites only").accessibilityAddTraits(favoritesOnly ? .isSelected : [])
            ConsoleSortMenu(selection: $sortName, count: visible.count, total: games.count)
        }.frame(minHeight: 44)
    }
    private var gameList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if visible.isEmpty { empty }
                else { LazyVStack(spacing: 6) { rows }.padding(3) }
            }.scrollIndicators(.hidden)
                .onChange(of: selectedID) { _, value in
                    guard let value else { return }
                    withAnimation(motion) { proxy.scrollTo(value, anchor: .center) }
                }
        }
    }
    @ViewBuilder private var rows: some View {
        ForEach(visible) { game in
            Button { withAnimation(motion) { selectedID = game.id } } label: {
                HStack(spacing: 10) {
                    GameCoverArtwork(game: game, fill: false).frame(width: 34, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Text(ConsoleCatalog.displayName(game.name)).font(.subheadline.weight(game.id == selectedID ? .semibold : .regular))
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    if game.favorite == true { Image(systemName: "heart.fill").font(.caption2).foregroundStyle(accent) }
                    if game.id == selectedID { Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(accent) }
                }.foregroundStyle(.primary).padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(game.id == selectedID ? accent.opacity(0.14) : ClawPalette.subtleFill,
                                in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(game.id == selectedID ? accent : .clear, lineWidth: 1))
            }.buttonStyle(ConsolePressStyle()).id(game.id)
                .accessibilityLabel(ConsoleCatalog.displayName(game.name))
                .accessibilityHint("Select. Hold for game options.")
                .accessibilityAddTraits(game.id == selectedID ? .isSelected : [])
                .contextMenu { gameActions(game) }
        }
    }
    private func detail(_ game: Game, landscape: Bool) -> some View {
        GeometryReader { geometry in
            let side = landscape ? max(48, min(geometry.size.width, geometry.size.height - 124)) : min(130, geometry.size.width * 0.43)
            Group {
                if landscape {
                    VStack(spacing: 8) {
                        artwork(game, side: side)
                        details(game)
                        launchButton(game)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 14) {
                        artwork(game, side: side)
                        VStack(alignment: .leading, spacing: 8) { details(game); launchButton(game) }
                            .frame(maxWidth: .infinity)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.consolePanel()
    }
    private func artwork(_ game: Game, side: CGFloat) -> some View {
        GameCoverArtwork(game: game, fill: false).frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.85), lineWidth: 1))
            .consoleNeon(accent)
            .contextMenu { gameActions(game) }
    }
    private func details(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(ConsoleCatalog.displayName(game.name)).font(.subheadline.weight(.semibold)).lineLimit(2)
            if showPlaytime {
                Label(ConsoleCatalog.playtime(game.playedSeconds) + " played", systemImage: "clock")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func launchButton(_ game: Game) -> some View {
        Button { onLaunch(game, true) } label: {
            Label(resumeSlots[game.id] == nil && game.lastPlayed == nil ? "Play" : "Continue", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }.buttonStyle(ClawPrimaryButton()).disabled(busy).accessibilityIdentifier("continueGame")
            .contextMenu { gameActions(game) }
    }
    @ViewBuilder private func gameActions(_ game: Game) -> some View {
        if resumeSlots[game.id] != nil { Button("Start from boot", systemImage: "power") { onLaunch(game, false) } }
        ConsoleGameActions(game: game, onFavorite: onFavorite, onCover: onCover,
                           onRemoveCover: onRemoveCover, onDelete: onDelete)
    }
    private var footer: some View {
        HStack {
            Button(action: onImport) { Label("Import", systemImage: "plus").font(.caption).padding(.horizontal, 12).frame(height: 36).consoleGlass() }
                .frame(minHeight: 44).disabled(busy).accessibilityIdentifier("importGame")
            Spacer()
            Button(action: onSearch) { Label("Search", systemImage: "magnifyingglass").font(.caption).padding(.horizontal, 12).frame(height: 36).consoleGlass() }
                .frame(minHeight: 44).accessibilityIdentifier("consoleSearch")
        }.frame(height: 44)
    }
    private var empty: some View {
        ConsoleEmptyState(title: "No games here yet", symbol: "gamecontroller", message: "Import a game or choose another system.", compact: wide)
    }
}
