// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

enum SaveFilter: String, CaseIterable, Identifiable {
    case all = "All", manual = "Manual", auto = "Auto"
    var id: String { rawValue }
}
struct SaveHistoryView: View {
    let states: [SaveEntry]
    let titleID: UInt64
    let store: SaveStateStore
    let onLoad: (SaveEntry) -> Void
    let onDelete: (SaveEntry) -> Void
    var initialFilter: SaveFilter = .all
    var onUpdate: ([SaveEntry]) -> Void = { _ in }
    var scrolls = true
    @State private var filter = SaveFilter.all
    @State private var renaming: SaveEntry?
    @State private var saveName = ""
    @State private var error: String?
    @State private var archive: SharedArchive?
    @AppStorage("saveSortOldestFirst") private var oldestFirst = false
    @State private var sorting = false
    @Environment(\.clawAccent) private var accent
    private var filtered: [SaveEntry] {
        states.filter { filter == .all || ($0.kind == .manual ? filter == .manual : filter == .auto) }
            .sorted {
                if $0.date == $1.date { return $0.slot < $1.slot }
                return oldestFirst ? $0.date < $1.date : $0.date > $1.date
            }
    }
    private var days: [Date] {
        Array(Set(filtered.map { Calendar.current.startOfDay(for: $0.date) }))
            .sorted { oldestFirst ? $0 < $1 : $0 > $1 }
    }
    var body: some View {
        Group {
            if scrolls { ScrollView { history.padding(.horizontal, 18).padding(.vertical, 16) } }
            else { history }
        }
            .onAppear { filter = initialFilter }
            .sheet(item: $renaming) { entry in
                ClawGamePrompt(title: "Rename save", message: "Give this snapshot a name you will recognize.",
                    confirmTitle: "Save", destructive: false, initialName: entry.name, onCancel: {}) { name in
                    Task {
                        do { onUpdate(try await store.record(title: titleID, slot: entry.slot, name: name)) }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            .sheet(item: $archive) { ShareSheet(url: $0.url) }
            .sheet(isPresented: $sorting) {
                ConsoleSettingsPage(title: "Sort saves", subtitle: "Choose the order of your snapshots.", symbol: "line.3.horizontal.decrease", closeLabel: "Done") {
                    ClawSettingsSection(title: "Order") {
                        ForEach([false, true], id: \.self) { oldest in
                            Button { oldestFirst = oldest; sorting = false } label: {
                                HStack {
                                    Text(oldest ? "Oldest first" : "Newest first")
                                    Spacer()
                                    if oldestFirst == oldest { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
                                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                            }.accessibilityAddTraits(oldestFirst == oldest ? .isSelected : [])
                        }
                    }
                }.presentationDetents([.medium])
            }
            .clawMessage("Save states", message: $error)
    }
    private var history: some View {
            VStack(alignment: .leading, spacing: 18) {
                ConsoleSegments(values: SaveFilter.allCases, selection: $filter) { $0.rawValue }
                    .accessibilityIdentifier("saveFilter")
                Button { sorting = true } label: {
                    HStack(spacing: 8) {
                        Label(oldestFirst ? "Oldest first" : "Newest first", systemImage: "line.3.horizontal.decrease")
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }.font(.caption).foregroundStyle(.secondary).frame(minHeight: 44).contentShape(Rectangle())
                }.accessibilityLabel("Sort saves").accessibilityIdentifier("saveSort")
                    .accessibilityValue(oldestFirst ? "Oldest first" : "Newest first")
                if filtered.isEmpty {
                    ConsoleEmptyState(title: "No save states yet.", symbol: "clock.arrow.circlepath",
                        message: "Create manual saves from the in-game menu.")
                }
                ForEach(days, id: \.self) { day in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Calendar.current.isDateInToday(day) ? "Today" : day.formatted(date: .abbreviated, time: .omitted))
                            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        ForEach(filtered.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }) { entry in
                            SaveStateCard(entry: entry, titleID: titleID, store: store,
                                onLoad: { onLoad(entry) }, onDelete: { onDelete(entry) },
                                onRename: { saveName = entry.name; renaming = entry },
                                onExport: {
                                    Task {
                                        do { archive = SharedArchive(url: try await store.export(title: titleID, entry: entry)) }
                                        catch { self.error = error.localizedDescription }
                                    }
                                })
                        }
                    }
                }
                Text("Create manual saves from the in-game menu. Auto Saves are kept separately.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 8)
    }
}
struct SaveStateCard: View {
    let entry: SaveEntry
    let titleID: UInt64
    let store: SaveStateStore
    let onLoad: () -> Void
    let onDelete: () -> Void
    let onRename: () -> Void
    let onExport: () -> Void
    @State private var preview: URL?
    @State private var showingActions = false
    @State private var pendingAction: (() -> Void)?
    @Environment(\.clawAccent) private var accent
    var body: some View {
        HStack(spacing: 12) {
            DiskArtwork(url: preview, revision: String(entry.date.timeIntervalSince1970))
                .frame(width: 104, height: 76).clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(preview == nil ? "No frame preview" : "Saved gameplay frame")
                .accessibilityIdentifier("statePreview\(entry.slot)")
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.name.isEmpty ? "\(entry.label) · Slot \(entry.slot)" : entry.name)
                    .font(.subheadline.weight(.semibold)).lineLimit(2)
                Text("\(entry.kind == .auto ? "AUTO" : "MANUAL") · SLOT \(entry.slot)")
                    .font(.caption2).foregroundStyle(accent)
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Load", action: onLoad).buttonStyle(ClawPrimaryButton())
                        .accessibilityIdentifier("loadSlot\(entry.slot)")
                    Spacer(minLength: 2)
                    Button { showingActions = true } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                            .background(ClawPalette.subtleFill, in: Circle())
                    }.accessibilityLabel("Options for slot \(entry.slot)")
                        .accessibilityIdentifier("stateMenu\(entry.slot)")
                }
            }
        }.consolePanel()
            .sheet(isPresented: $showingActions, onDismiss: {
                let action = pendingAction; pendingAction = nil; action?()
            }) {
                ConsoleSettingsPage(title: "Save actions", subtitle: entry.label, symbol: "clock.arrow.circlepath", closeLabel: "Done") {
                    Button { pendingAction = onRename; showingActions = false } label: {
                        ConsoleActionTile(title: "Rename", subtitle: "Give this snapshot a name", symbol: "pencil")
                    }
                    Button { pendingAction = onExport; showingActions = false } label: {
                        ConsoleActionTile(title: "Export save", subtitle: "Keep a copy or share it", symbol: "square.and.arrow.up")
                    }
                    Button { pendingAction = onDelete; showingActions = false } label: {
                        ConsoleActionTile(title: "Delete save", subtitle: "Permanently remove this snapshot", symbol: "trash")
                    }.accessibilityIdentifier("deleteSlot\(entry.slot)")
                }.padding(18).buttonStyle(ConsolePressStyle()).presentationDetents([.medium, .large])
            }
            .task(id: "\(titleID)-\(entry.slot)-\(entry.date.timeIntervalSince1970)") {
                preview = try? await store.preview(title: titleID, entry: entry)
            }
    }
}
@MainActor struct SaveStateManager: View {
    @ObservedObject var model: GameUtilitiesModel
    let onLoad: (SaveEntry) -> Void
    let onDelete: (SaveEntry) -> Void
    private let store = SaveStateStore(directory: DiskStore.coreDirectory.appendingPathComponent("save_states"))
    var body: some View {
        ConsoleSettingsPage(title: "All saves", subtitle: "Your snapshots", symbol: "clock.arrow.circlepath") {
            SaveHistoryView(states: model.states, titleID: model.titleID, store: store,
                            onLoad: onLoad, onDelete: onDelete, onUpdate: { model.states = $0 }, scrolls: false)
                .disabled(model.busy)
        }
    }
}
