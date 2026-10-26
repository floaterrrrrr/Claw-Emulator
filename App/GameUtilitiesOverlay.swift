// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import SwiftUI

@MainActor final class GameUtilitiesModel: ObservableObject {
    @Published var titleID: UInt64 = 0
    @Published var gameName = "Game"
    @Published var system: GameSystem = .threeDS
    @Published var states: [SaveEntry] = []
    @Published var selectedSlot = 1
    @Published var autosaveEnabled: Bool
    @Published var autosaveMinutes: Int
    @Published var ready = false
    @Published var busy = false
    @Published var speed = 1
    @Published var message = "Save a snapshot of your progress."
    @Published var graphics = "Loading…"
    @Published var volume: Double
    @Published var opacity: Double
    @Published var orientation: GameplayOrientation
    @Published var showStats: Bool
    @Published var largerTouchScreen: Bool
    @Published var skinEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        func bounded(_ key: String, fallback: Double, minimum: Double = 0) -> Double {
            guard let value = defaults.object(forKey: key) as? Double, value.isFinite else { return fallback }
            return min(1, max(minimum, value))
        }
        volume = bounded("gameVolume", fallback: 1)
        opacity = bounded("controlOpacity", fallback: 0.85, minimum: 0.35)
        orientation = GameplayOrientation(rawValue: defaults.string(forKey: "gameOrientation") ?? "") ?? .automatic
        showStats = defaults.object(forKey: "showGameStats") as? Bool ?? true
        largerTouchScreen = defaults.bool(forKey: "largerTouchScreen")
        autosaveEnabled = defaults.object(forKey: "autosaveEnabled") as? Bool ?? true
        autosaveMinutes = min(10, max(1, defaults.object(forKey: "autosaveMinutes") as? Int ?? 5))
#if CLAW_FRONTEND_FIXTURE
        skinEnabled = ProcessInfo.processInfo.arguments.contains("--test-skin")
#else
        skinEnabled = defaults.object(forKey: "controllerSkin") as? Bool
            ?? defaults.object(forKey: "atomicControllerSkin") as? Bool ?? true
#endif
    }
}

@MainActor struct GameUtilitiesOverlay: View {
    @ObservedObject var model: GameUtilitiesModel
    let onResume: () -> Void
    let onSpeed: (Int) -> Void
    let onSave: () -> Void
    let onRestore: () -> Void
    let onSaveAndLeave: () -> Void
    let onLoadSlot: (SaveEntry) -> Void
    let onDeleteSlot: (SaveEntry) -> Void
    let onStop: () -> Void
    let onVolume: (Double) -> Void
    let onLayout: () -> Void
    let onEditControls: () -> Void
    @AppStorage("clawAccent") private var accentName = ClawAccent.orange.rawValue
    @AppStorage("clawCustomAccentRGB") private var customRGB = ClawAccent.defaultCustomRGB
    @AppStorage("controlHaptics") private var haptics = true
    @ObservedObject private var battery = BatteryMonitor.shared
    @State private var observingBattery = false
    @State private var choosingSlot = false
    private var accent: Color {
        accentName == ClawAccent.custom.rawValue ? ClawAccent.customColor(customRGB)
            : (ClawAccent(rawValue: accentName) ?? .orange).color
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: geometry.size.width > geometry.size.height ? .trailing : .center) {
                Color.black.opacity(0.5).ignoresSafeArea()
                NavigationStack { menu }
                .frame(width: min(geometry.size.width - 32, 520), height: max(100, geometry.size.height - 32))
                .background(ClawPalette.background, in: RoundedRectangle(cornerRadius: 28))
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(ClawPalette.border.opacity(0.6), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.24), radius: 24, y: 12)
                .padding(16)
            }
        }.tint(accent).environment(\.clawAccent, accent).buttonStyle(ConsolePressStyle()).preferredColorScheme(.dark)
            .onAppear {
                guard !observingBattery else { return }
                battery.begin(); observingBattery = true
            }
            .onDisappear {
                guard observingBattery else { return }
                battery.end(); observingBattery = false
            }
            .onChange(of: model.orientation) { _, _ in onLayout() }
            .onChange(of: model.opacity) { _, _ in onLayout() }
            .onChange(of: model.showStats) { _, _ in onLayout() }
            .onChange(of: model.largerTouchScreen) { _, _ in onLayout() }
            .onChange(of: model.skinEnabled) { _, _ in onLayout() }
            .onChange(of: model.autosaveEnabled) { _, _ in onLayout() }
            .onChange(of: model.autosaveMinutes) { _, _ in onLayout() }
    }
    private var menu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.gameName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            Text("Paused").font(.largeTitle.bold())
                        }
                        Spacer(minLength: 0)
                        BatteryStatusLabel(monitor: battery, accent: accent, showsBackground: true,
                                           identifier: "gameBattery")
                        Button(action: onResume) {
                            Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                                .frame(width: 44, height: 44).background(ClawPalette.subtleFill, in: Circle())
                        }.disabled(!model.ready || model.busy).accessibilityLabel("Close game menu")
                    }
                }
                Button(action: onResume) {
                    Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                }.buttonStyle(ClawPrimaryButton()).accessibilityIdentifier("resumeGame")
                    .disabled(!model.ready || model.busy)
                HStack {
                    Text("Speed").font(.subheadline)
                    ClawSpeedPicker(selection: Binding(get: { model.speed }, set: onSpeed))
                        .accessibilityIdentifier("playbackSpeed")
                }.disabled(!model.ready || model.busy)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Game volume").font(.subheadline)
                        Slider(value: Binding(get: { model.volume }, set: onVolume), in: 0...1)
                            .accessibilityLabel("Game volume").accessibilityIdentifier("gameVolume")
                        Text(model.volume, format: .percent.precision(.fractionLength(0))).font(.caption).monospacedDigit()
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    Button(action: onSave) { tile("Save state", "square.and.arrow.down") }
                        .accessibilityIdentifier("saveState")
                    Button(action: onRestore) { tile("Load state", "arrow.counterclockwise") }
                        .accessibilityIdentifier("loadState")
                    NavigationLink { controls } label: { tile("Controls", "gamecontroller") }
                        .accessibilityIdentifier("gameControlsSettings")
                    NavigationLink { graphics } label: { tile("Graphics", "gearshape") }
                }.disabled(!model.ready || model.busy)
                NavigationLink {
                    SaveStateManager(model: model, onLoad: onLoadSlot, onDelete: onDeleteSlot)
                } label: { menuRow("All saves", "clock.arrow.circlepath") }
                    .accessibilityIdentifier("manageStates").disabled(!model.ready || model.busy)
                NavigationLink { saveOptions } label: {
                    menuRow("Save options · Slot \(model.selectedSlot)", "slider.horizontal.3")
                }.accessibilityIdentifier("saveOptions")
                if model.busy { ProgressView() }
                Text(model.message).font(.caption).foregroundStyle(.secondary)
                Divider()
                Button(action: onStop) { tile("Return to library", "rectangle.portrait.and.arrow.right") }
                    .disabled(model.busy).accessibilityIdentifier("stopGame")
            }.padding(20)
        }.background(ClawPalette.background).foregroundStyle(.primary)
            .toolbar(.hidden, for: .navigationBar)
    }
    private func tile(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3)
            Text(title).font(.subheadline.weight(.medium))
        }.frame(maxWidth: .infinity, minHeight: 48).padding(.horizontal, 8)
            .background(ClawPalette.card, in: Capsule())
            .overlay(Capsule().strokeBorder(ClawPalette.border, lineWidth: 0.8))
            .contentShape(Capsule())
    }
    private func menuRow(_ title: String, _ icon: String) -> some View {
        HStack { Label(title, systemImage: icon); Spacer(); Image(systemName: "chevron.right") }
            .font(.subheadline).frame(minHeight: 44).clawCard()
    }
    private var controls: some View {
        ClawOptionsPage(title: "Controls", symbol: "gamecontroller") {
            if model.system.hasHandheldOverlay {
                HandheldControlsOptions(system: model.system, usesFormRows: false, onEditLive: onEditControls)
            }
            ClawSettingsSection(title: "Display") {
                Text("Orientation").font(.subheadline.weight(.medium))
                ConsoleSegments(values: GameplayOrientation.allCases, selection: $model.orientation) { $0.title }
                    .accessibilityIdentifier("gameOrientation")
                if model.system.dualScreen {
                    Divider()
                    Toggle("Larger touch screen", isOn: $model.largerTouchScreen)
                    Text("Uses more space in landscape.").font(.caption).foregroundStyle(.secondary)
                }
            }
            ClawSettingsSection(title: "Control appearance", footer: "Choose or import skins from the Skins tab in your library.") {
                ClawSettingsSlider(title: "Skin control opacity", value: $model.opacity, range: 0.35...1)
            }
            ClawSettingsSection(title: "Feedback") {
                Toggle("Control haptics", isOn: $haptics)
                Divider()
                Toggle("Show performance", isOn: $model.showStats)
            }
        }
    }
    private var graphics: some View {
        ClawOptionsPage(title: "Graphics", symbol: "display") {
            ClawSettingsSection(title: "Current session", footer: model.system == .threeDS
                ? "Change resolution and MetalFX in library settings before your next launch."
                : "The complete image is scaled from its native resolution.") {
                Label(model.graphics, systemImage: "display")
                    .font(.subheadline.weight(.medium)).textSelection(.enabled)
            }

        }
    }
    private var saveOptions: some View {
        ClawOptionsPage(title: "Save options", symbol: "slider.horizontal.3") {
            ClawSettingsSection(title: "Manual saves", footer: "Eight slots, with a name and preview for each snapshot.") {
                Button { choosingSlot = true } label: {
                    ClawSettingsRow(title: "Manual slot", symbol: "square.stack", value: "Slot \(model.selectedSlot)")
                }.accessibilityIdentifier("manualSlot")
            }
            ClawSettingsSection(title: "Automatic saves", footer: "Three rotating snapshots, kept separately from your manual saves.") {
                Toggle("Auto Save", isOn: $model.autosaveEnabled).accessibilityIdentifier("autosaveEnabled")
                Divider()
                ConsoleMinuteStepper(minutes: $model.autosaveMinutes).accessibilityIdentifier("autosaveMinutes")
                    .disabled(!model.autosaveEnabled)
            }
            Button(action: onSaveAndLeave) {
                Label("Save & return to library", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(ClawPrimaryButton()).accessibilityIdentifier("saveAndLeave")
                .disabled(!model.ready || model.busy)
            Text("You’ll confirm before saving. Keep using the game’s own save menu too.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
            .sheet(isPresented: $choosingSlot) {
                ConsoleSettingsPage(title: "Manual save slot", subtitle: "Choose your next snapshot’s slot.", symbol: "square.stack", closeLabel: "Done") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 10) {
                        ForEach(1...8, id: \.self) { slot in
                            Button {
                                model.selectedSlot = slot; choosingSlot = false
                            } label: {
                                HStack {
                                    Text("Slot \(slot)")
                                    Spacer()
                                    if model.selectedSlot == slot { Image(systemName: "checkmark.circle.fill") }
                                }.padding(14).frame(minHeight: 54)
                                    .background(ClawPalette.card, in: RoundedRectangle(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14)
                                        .strokeBorder(model.selectedSlot == slot ? accent : ClawPalette.border))
                            }.buttonStyle(ConsolePressStyle()).accessibilityIdentifier("chooseManualSlot\(slot)")
                                .accessibilityAddTraits(model.selectedSlot == slot ? .isSelected : [])
                        }
                    }
                }
                    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
    }
}
