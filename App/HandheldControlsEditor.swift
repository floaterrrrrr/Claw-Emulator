// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

struct HandheldControlsSettingsPage: View {
    @State private var system = GameSystem.gba
    var body: some View {
        ConsoleSettingsPage(title: "Handheld controls", subtitle: "Make room for the game.", symbol: "dpad") {
            ConsoleSegments(values: [GameSystem.gb, .gbc, .gba], selection: $system) { $0.shortTitle }
            HandheldControlsOptions(system: system).id(system)
        }
    }
}
struct HandheldControlsOptions: View {
    let system: GameSystem
    let usesFormRows: Bool
    var onEditLive: (() -> Void)? = nil
    @AppStorage private var enabled: Bool
    @AppStorage private var opacity: Double
    @AppStorage private var movement: String
    @State private var editing = false
    init(system: GameSystem, usesFormRows: Bool = false, onEditLive: (() -> Void)? = nil) {
        self.system = system
        self.usesFormRows = usesFormRows
        self.onEditLive = onEditLive
        _enabled = AppStorage(wrappedValue: true, HandheldControlsConfiguration.key(system, "enabled"))
        _movement = AppStorage(wrappedValue: HandheldMovement.dpad.rawValue, HandheldControlsConfiguration.key(system, "movement"))
        _opacity = AppStorage(wrappedValue: 0.45, HandheldControlsConfiguration.key(system, "opacity"))
    }
    var body: some View {
        Group {
            // Form must receive separate rows. A VStack of interactive controls
            // lets automatic row actions send taps to a different control.
            if usesFormRows { rows }
            else { VStack(alignment: .leading, spacing: 14) { rows }.consolePanel() }
        }.onChange(of: enabled) { _, _ in notify() }
            .onChange(of: opacity) { _, _ in notify() }
            .onChange(of: movement) { _, _ in InterfaceHaptics.selection(); notify() }
            .fullScreenCover(isPresented: $editing) { HandheldControlsEditor(initialSystem: system) }
    }
    @ViewBuilder private var rows: some View {
        Toggle("Floating controls", isOn: $enabled).accessibilityIdentifier("handheldOverlayEnabled")
        Text("Controls sit over the game. Turn this off to use your chosen skin.").font(.caption).foregroundStyle(.secondary)
        if enabled {
            ConsoleSegments(values: HandheldMovement.allCases.map(\.rawValue), selection: $movement) {
                HandheldMovement(rawValue: $0)?.title ?? $0
            }.accessibilityIdentifier("handheldMovement")
            LabeledContent("Control opacity", value: opacity.formatted(.percent.precision(.fractionLength(0))))
            Slider(value: $opacity, in: 0.15...0.8).accessibilityLabel("Floating control opacity")
        }
        Button {
            if let onEditLive { onEditLive() } else { editing = true }
        } label: {
            Label("Edit control layout", systemImage: "hand.draw")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.borderless).accessibilityIdentifier("editHandheldLayout")
        Text("Move and resize buttons separately in portrait and landscape. Add custom buttons here too. Saving enables floating controls for this system.")
            .font(.caption).foregroundStyle(.secondary)
    }
    private func notify() { NotificationCenter.default.post(name: .handheldControlsChanged, object: nil) }
}

struct HandheldControlsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("clawAccent") private var accentName = ClawAccent.orange.rawValue
    @AppStorage("clawCustomAccentRGB") private var customRGB = ClawAccent.defaultCustomRGB
    private var accent: Color {
        accentName == ClawAccent.custom.rawValue ? ClawAccent.customColor(customRGB)
            : (ClawAccent(rawValue: accentName) ?? .orange).color
    }
    let system: GameSystem
    @State private var orientation = "portrait"
    @State private var draft = HandheldControlLayout()
    @State private var opacity = 0.45
    @State private var selected = HandheldControl.dpad.rawValue
    @State private var combos: [HandheldCombo] = []
    @State private var showTools = false
    @State private var liveSize: CGSize?
    let onFinish: ((Bool) -> Void)?
    private let movement: HandheldMovement
    @State private var error: String?
    @State private var canvasDragOrigin: CGRect?
    @State private var toolbarAtBottom = false
    @State private var displaySize = CGSize(width: 393, height: 852)
    @State private var displayInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
    // Drafts are kept when switching orientations, and written only by Save.
    @State private var drafts: [String: HandheldControlLayout] = [:]
    init(initialSystem: GameSystem, liveCanvas: CGSize? = nil, initialSelection: HandheldControl = .dpad, onFinish: ((Bool) -> Void)? = nil) {
        system = initialSystem
        self.onFinish = onFinish
        _liveSize = State(initialValue: liveCanvas)
        _selected = State(initialValue: initialSelection.rawValue)
        let configuration = HandheldControlsConfiguration.load(system: initialSystem)
        movement = configuration.movement
        _combos = State(initialValue: configuration.combos)
        _opacity = State(initialValue: configuration.opacity)
    }
    private var canvas: CGSize {
        if let liveSize { return liveSize }
        let short = min(displaySize.width, displaySize.height), long = max(displaySize.width, displaySize.height)
        return orientation == "portrait" ? CGSize(width: short, height: long) : CGSize(width: long, height: short)
    }
    private var safe: CGRect {
        if liveSize != nil {
            return CGRect(origin: .zero, size: canvas).inset(by: UIEdgeInsets(top: displayInsets.top >= 44 ? displayInsets.top : 0, left: displayInsets.left,
                bottom: displayInsets.bottom, right: displayInsets.right))
        }
        var insets: UIEdgeInsets
        if (displaySize.width > displaySize.height) == (orientation == "landscape") {
            insets = displayInsets
        } else if orientation == "landscape" {
            let cutout = displayInsets.top >= 44 ? displayInsets.top : 0
            insets = UIEdgeInsets(top: 0, left: cutout, bottom: min(21, displayInsets.bottom), right: cutout)
        } else {
            insets = UIEdgeInsets(top: max(displayInsets.top, max(displayInsets.left, displayInsets.right)), left: 0,
                bottom: displayInsets.bottom > 0 ? max(34, displayInsets.bottom) : 0, right: 0)
        }
        // Match immersive gameplay: retain physical cutouts, without reserving
        // a status-only inset on older phones.
        if insets.top < 44 { insets.top = 0 }
        return CGRect(origin: .zero, size: canvas).inset(by: insets)
    }
    var body: some View {
        GeometryReader { geometry in
            Group {
                if liveSize != nil {
                    ZStack {
                        preview
                        VStack {
                            if !toolbarAtBottom { liveHeader }
                            Spacer()
                            if toolbarAtBottom { liveHeader }
                        }.padding(.horizontal, max(12, max(displayInsets.left, displayInsets.right)))
                            .padding(.top, max(10, displayInsets.top)).padding(.bottom, max(10, displayInsets.bottom))
                    }.accessibilityIdentifier("liveControlsEditor")
                        .onChange(of: geometry.size) { _, size in liveSize = size }
                } else { standalone }
            }
        }.background {
            if liveSize == nil { ConsoleBackdrop() }
        }.background {
            HandheldDisplayMetrics { size, insets in displaySize = size; displayInsets = insets }
                .allowsHitTesting(false).accessibilityHidden(true)
        }.tint(accent).environment(\.clawAccent, accent).buttonStyle(ConsolePressStyle()).onAppear {
            if liveSize != nil { orientation = canvas.width > canvas.height ? "landscape" : "portrait" }
            load()
        }.onChange(of: liveSize) { old, new in
            guard let old, let new, (old.width > old.height) != (new.width > new.height) else { return }
            canvasDragOrigin = nil
            stash(); orientation = new.width > new.height ? "landscape" : "portrait"; load()
        }.onChange(of: combos) { old, new in
            let previous = draft.allFrames(in: bounds, system: system, combos: old, safeArea: safe)
            prepareDraft()
            let defaults = frames(draft)
            for combo in new where draft.controls[combo.key] == nil {
                if let frame = previous[combo.key] ?? defaults[combo.key] {
                    draft.set(combo.key, frame: frame, in: bounds)
                }
            }
        }.sheet(isPresented: $showTools, onDismiss: {
            toolbarAtBottom = (frames(draft)[selected]?.minY ?? 100) < 90
        }) {
            ConsoleSettingsPage(title: "Edit controls", subtitle: "Select a button, then adjust it.", symbol: "slider.horizontal.3", closeLabel: "Done") {
                adjustmentTools
            }.presentationDetents([.large]).presentationDragIndicator(.visible)
        }.alert("Layout could not be saved", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
            .ignoresSafeArea(.container, edges: liveSize != nil ? .all : [])
    }
    private var liveHeader: some View {
        HStack(spacing: 8) {
            Button { finish(false) } label: {
                Image(systemName: "xmark").font(.subheadline.weight(.semibold)).frame(width: 44, height: 44)
                    .background(ClawPalette.subtleFill, in: Circle())
            }.accessibilityLabel("Cancel")
            Button { showTools = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3").foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(selected)).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("Drag to move · Tap for tools").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }.accessibilityIdentifier("liveControlTools")
            Button(action: save) { Text("Save") }.buttonStyle(ClawPrimaryButton()).accessibilityIdentifier("saveHandheldLayout")
        }.padding(8).background(ClawPalette.card.opacity(0.97), in: Capsule())
            .overlay(Capsule().strokeBorder(ClawPalette.border, lineWidth: 0.8))
            .frame(maxWidth: 420).frame(maxWidth: .infinity)
    }
    private var standalone: some View {
        GeometryReader { geometry in
            VStack(spacing: 10) {
                HStack {
                    Button { finish(false) } label: { Text("Cancel").frame(minWidth: 64, minHeight: 44) }
                    Spacer()
                    VStack(spacing: 2) {
                        Text("Control layout").font(.headline)
                        Text(system.shortTitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: save) { Text("Save").fontWeight(.semibold).frame(minWidth: 64, minHeight: 44) }
                        .accessibilityIdentifier("saveHandheldLayout")
                }
                if geometry.size.width > geometry.size.height {
                    HStack(spacing: 20) {
                        preview
                        ScrollView {
                            VStack(spacing: 10) { selectors; instruction; adjustmentTools }
                        }.frame(width: min(300, geometry.size.width * 0.4))
                    }
                } else {
                    selectors
                    instruction
                    preview
                    Button { showTools = true } label: {
                        Label("Edit buttons & appearance", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(ClawPrimaryButton()).accessibilityIdentifier("standaloneControlTools")
                }
            }.padding(.horizontal, 18).padding(.vertical, 8)
        }
    }
    private func finish(_ saved: Bool) { if let onFinish { onFinish(saved) } else { dismiss() } }
    private var bounds: CGRect {
        // Persist against the same complete canvas in preview and gameplay.
        CGRect(origin: .zero, size: canvas)
    }
    private var keys: [String] { HandheldControl.available(for: system).map(\.rawValue) + combos.map(\.key) }
    private func title(_ key: String) -> String { combos.first { $0.key == key }?.name ?? HandheldControl(rawValue: key)?.title ?? "Button" }
    private func frames(_ layout: HandheldControlLayout) -> [String: CGRect] {
        layout.allFrames(in: bounds, system: system, combos: combos, safeArea: safe)
    }
    private var selectors: some View {
        ConsoleSegments(values: ["portrait", "landscape"], selection: orientationSelection) { $0.capitalized }
            .accessibilityLabel("Layout orientation")
    }
    private var instruction: some View {
        Text("Drag a button to move it, or drag the preview to move the selected control.")
            .font(.caption).foregroundStyle(.secondary)
    }
    private var adjustmentTools: some View {
        VStack(alignment: .leading, spacing: 20) {
            ClawSettingsSection(title: "Select a control") {
                ConsoleChoiceGrid(values: keys, selection: $selected) { title($0) }
            }
            ClawSettingsSection(title: "Size & appearance") {
                ClawSettingsSlider(title: title(selected) + " size", value: selectedSize, range: 0.65...1.8)
                Divider()
                ClawSettingsSlider(title: "Layout control opacity", value: $opacity, range: 0.15...0.8)
            }
            ClawSettingsSection(title: "Custom buttons") {
                HandheldComboList(system: system, combos: $combos, selected: $selected)
            }
            Button { draft = HandheldControlLayout() } label: {
                Label("Reset this layout", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity, minHeight: 44).consoleGlass()
            }
        }
    }
    private var preview: some View {
        GeometryReader { geometry in
            let scale = max(0.01, min(geometry.size.width / canvas.width, geometry.size.height / canvas.height))
            let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
            let frames = self.frames(draft)
            // Use the same complete canvas as immersive gameplay.
            let gameBounds = CGRect(origin: .zero, size: canvas)
            let game = HandheldViewport.frame(in: gameBounds, aspect: system.aspect)
            ZStack(alignment: .topLeading) {
                // Only empty canvas space moves the current selection. A drag
                // on a button has one owner, rather than competing with a
                // second gesture on the entire preview.
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("handheldEditor")).onChanged { value in
                        if canvasDragOrigin == nil { canvasDragOrigin = frames[selected] }
                        if let origin = canvasDragOrigin {
                            prepareDraft()
                            draft.set(selected, frame: origin.offsetBy(dx: value.translation.width / scale,
                                dy: value.translation.height / scale), in: bounds)
                        }
                    }.onEnded { _ in canvasDragOrigin = nil })
                if liveSize == nil {
                    RoundedRectangle(cornerRadius: 20).fill(ClawPalette.subtleFill).allowsHitTesting(false)
                    Rectangle().fill(ClawPalette.card)
                        .overlay { Text("Game screen").font(.caption).foregroundStyle(.secondary) }
                        .frame(width: game.width * scale, height: game.height * scale)
                        .position(x: game.midX * scale, y: game.midY * scale).allowsHitTesting(false)
                }
                ForEach(keys, id: \.self) { control in
                    if let frame = frames[control] {
                        HandheldEditorButton(control: HandheldControl(rawValue: control), title: title(control), id: control,
                            speed: combos.first(where: { $0.key == control })?.speed, joystick: movement == .joystick, frame: CGRect(x: frame.minX * scale, y: frame.minY * scale,
                            width: frame.width * scale, height: frame.height * scale), selected: selected == control,
                            opacity: opacity, onSelect: { selected = control }, onMove: { origin in
                                selected = control
                                prepareDraft()
                                draft.set(control, frame: CGRect(x: origin.x / scale, y: origin.y / scale,
                                    width: frame.width, height: frame.height), in: bounds)
                            }).id(control + orientation).zIndex(selected == control ? 1 : 0)
                    }
                }
            }.frame(width: size.width, height: size.height).coordinateSpace(name: "handheldEditor")
                .contentShape(Rectangle())
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(ClawPalette.border, lineWidth: 1).allowsHitTesting(false))
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                .accessibilityIdentifier("handheldEditorCanvas")
                .transaction { $0.animation = nil }
        }
    }
    private var selectedSize: Binding<Double> {
        Binding(get: {
            let original = frames(HandheldControlLayout())[selected] ?? CGRect(x: 0, y: 0, width: 64, height: 64)
            return (frames(draft)[selected] ?? CGRect(x: 0, y: 0, width: 64, height: 64)).width / original.width
        }, set: { value in
            let original = frames(HandheldControlLayout())[selected] ?? CGRect(x: 0, y: 0, width: 64, height: 64)
            let current = frames(draft)[selected] ?? CGRect(x: 0, y: 0, width: 64, height: 64)
            prepareDraft()
            draft.set(selected, frame: CGRect(x: current.midX - original.width * value / 2,
                y: current.midY - original.height * value / 2, width: original.width * value, height: original.height * value), in: bounds)
        })
    }
    private var orientationSelection: Binding<String> {
        Binding(get: { orientation }, set: { value in canvasDragOrigin = nil; stash(); orientation = value; load() })
    }
    private func prepareDraft() {
        draft.controls = draft.controls.filter { keys.contains($0.key) }
        draft = draft.migrated(in: bounds, safeArea: safe, system: system, combos: combos)
    }
    private func stash() { drafts[orientation] = draft }
    private func load() {
        draft = drafts[orientation] ?? HandheldControlsConfiguration.layout(system: system, orientation: orientation)
        toolbarAtBottom = (frames(draft)[selected]?.minY ?? 100) < 90
    }
    private func save() {
        stash()
        do {
            for (key, value) in drafts {
                var cleaned = value
                cleaned.controls = cleaned.controls.filter { keys.contains($0.key) }
                try HandheldControlsConfiguration.save(cleaned, system: system, orientation: key, opacity: opacity, combos: combos)
            }
            InterfaceHaptics.success()
            finish(true)
        } catch { self.error = error.localizedDescription }
    }
}

// Read the physical window once when attached and whenever its geometry changes.
// The editor uses the same device canvas as gameplay, including its safe area.
private struct HandheldDisplayMetrics: UIViewRepresentable {
    let changed: (CGSize, UIEdgeInsets) -> Void
    func makeUIView(context: Context) -> MetricsView {
        let view = MetricsView(); view.changed = changed; return view
    }
    func updateUIView(_ view: MetricsView, context: Context) { view.changed = changed }
    final class MetricsView: UIView {
        var changed: ((CGSize, UIEdgeInsets) -> Void)?
        private var lastSize = CGSize.zero
        private var lastInsets = UIEdgeInsets.zero
        override func didMoveToWindow() { super.didMoveToWindow(); publish() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); publish() }
        override func layoutSubviews() { super.layoutSubviews(); publish() }
        private func publish() {
            guard let window, window.bounds.width > 0, window.bounds.height > 0 else { return }
            let size = window.bounds.size, insets = window.safeAreaInsets
            guard size != lastSize || insets != lastInsets else { return }
            lastSize = size; lastInsets = insets
            DispatchQueue.main.async { [weak self] in self?.changed?(size, insets) }
        }
    }
}

private struct HandheldEditorButton: View {
    let control: HandheldControl?
    let title: String
    let id: String
    var speed: Int? = nil
    var joystick = false
    let frame: CGRect
    let selected: Bool
    let opacity: Double
    let onSelect: () -> Void
    let onMove: (CGPoint) -> Void
    @State private var origin: CGPoint?
    @Environment(\.clawAccent) private var accent
    private var radius: CGFloat { min(frame.width, frame.height) / 2 }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius)
                .fill(Color.primary.opacity(opacity * 0.18))
            if control == .dpad { Image(systemName: joystick ? "circle.circle.fill" : "dpad.fill").resizable().scaledToFit().padding(5).opacity(opacity) }
            else if let speed { FastForwardGlyph(triangles: speed).fill(.primary).padding(frame.width * 0.22).opacity(opacity) }
            else if control == .menu { Image(systemName: "gearshape").opacity(opacity) }
            else if control == .edit { Image(systemName: "hand.draw").opacity(opacity) }
            else { Text(title).font(.system(size: min(16, frame.height * 0.38), weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.35).padding(6).opacity(opacity) }
        }.frame(width: frame.width, height: frame.height)
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(selected ? accent : ClawPalette.border, lineWidth: selected ? 2 : 1))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle()).position(x: frame.midX, y: frame.midY)
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("handheldEditor"))
                .onChanged { value in
                    if origin == nil { origin = frame.origin; onSelect() }
                    if let origin, value.translation != .zero {
                        onMove(CGPoint(x: origin.x + value.translation.width, y: origin.y + value.translation.height))
                    }
                }.onEnded { _ in origin = nil })
            .accessibilityLabel(title).accessibilityHint("Drag to move")
            .accessibilityIdentifier("editControl-" + id)
    }
}

private struct HandheldComboList: View {
    let system: GameSystem
    @Binding var combos: [HandheldCombo]
    @Binding var selected: String
    @State private var editing: HandheldCombo?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { editing = HandheldCombo(name: "", inputs: []) } label: {
                Label("Add custom button", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.disabled(combos.count >= 16).accessibilityIdentifier("addComboButton")
            ForEach(combos) { combo in
                Divider()
                HStack(spacing: 8) {
                    Button { selected = combo.key } label: {
                        HStack(spacing: 10) {
                            if let speed = combo.speed {
                                FastForwardGlyph(triangles: speed).fill(.primary).frame(width: 28, height: 16)
                            } else { Image(systemName: "circle.grid.2x2").foregroundStyle(.secondary) }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(combo.name).font(.subheadline.weight(.medium))
                                Text(combo.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if selected == combo.key { Image(systemName: "checkmark.circle.fill") }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }
                    Button { selected = combo.key; editing = combo } label: {
                        Image(systemName: "pencil").frame(width: 44, height: 44).consoleGlass()
                    }.accessibilityLabel("Edit " + combo.name)
                    Button(role: .destructive) {
                        InterfaceHaptics.warning(); combos.removeAll { $0.id == combo.id }
                        if selected == combo.key { selected = HandheldControl.dpad.rawValue }
                    } label: {
                        Image(systemName: "trash").frame(width: 44, height: 44).consoleGlass()
                    }.accessibilityLabel("Delete " + combo.name)
                }
            }
        }.sheet(item: $editing) { combo in
            HandheldComboComposer(system: system, combo: combo) { saved in
                if let index = combos.firstIndex(where: { $0.id == saved.id }) { combos[index] = saved }
                else { combos.append(saved) }
                selected = saved.key
            }
        }
    }
}
private struct HandheldComboComposer: View {
    let system: GameSystem
    let onSave: (HandheldCombo) -> Void
    @State private var combo: HandheldCombo
    @State private var customName: String
    @FocusState private var naming: Bool
    @Environment(\.dismiss) private var dismiss
    init(system: GameSystem, combo: HandheldCombo, onSave: @escaping (HandheldCombo) -> Void) {
        self.system = system; self.onSave = onSave; _combo = State(initialValue: combo)
        _customName = State(initialValue: combo.name == HandheldCombo.automaticName(for: combo.inputs, speed: combo.speed) ? "" : combo.name)
    }
    private var resolved: HandheldCombo {
        var result = combo
        result.name = HandheldCombo.resolvedName(customName, inputs: combo.inputs, speed: combo.speed)
        return result
    }
    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    cancelButton
                    Spacer(minLength: 8)
                    Text("Custom button").font(.headline).fixedSize()
                    Spacer(minLength: 8)
                    saveButton
                }
                VStack(spacing: 4) {
                    Text("Custom button").font(.headline)
                    HStack { cancelButton; Spacer(); saveButton }
                }
            }.padding(.horizontal, 16).padding(.vertical, 8).background(ClawPalette.background)
            ScrollView {
              VStack(alignment: .leading, spacing: 20) {
                if system == .gba {
                    ClawSettingsSection(title: "Button action") {
                        ClawSpeedPicker(selection: Binding(get: { combo.speed ?? 1 }, set: { value in
                            combo.speed = value == 1 ? nil : value
                            if combo.speed != nil { combo.inputs.removeAll() }
                            InterfaceHaptics.selection()
                        }), normalTitle: "Combo").accessibilityIdentifier("customButtonAction")
                    }
                }
                ClawSettingsSection(title: "Name", footer: "A name is filled in automatically. You can give it your own name below.") {
                    LabeledContent("Button label", value: resolved.name.isEmpty ? "Choose buttons below" : resolved.name)
                        .accessibilityIdentifier("comboAutomaticName")
                    TextField("Custom name (optional)", text: $customName).accessibilityIdentifier("comboName")
                        .focused($naming).submitLabel(.done).onSubmit { naming = false }
                        .onChange(of: customName) { _, value in if value.count > 24 { customName = String(value.prefix(24)) } }
                        .padding(12).background(ClawPalette.subtleFill, in: Capsule())
                }
                if combo.speed == nil {
                    ClawSettingsSection(title: "Press together", footer: "Selected inputs stay pressed while you hold this button.") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                            ForEach(HandheldCombo.inputs(for: system)) { input in
                                Button {
                                    if combo.inputs.contains(input) { combo.inputs.removeAll { $0 == input } }
                                    else { combo.inputs.append(input) }
                                    InterfaceHaptics.selection()
                                } label: {
                                    HStack(spacing: 5) {
                                        Text(input.title).font(.subheadline.weight(.semibold))
                                        if combo.inputs.contains(input) { Image(systemName: "checkmark").font(.caption) }
                                    }.frame(maxWidth: .infinity, minHeight: 44)
                                        .foregroundStyle(combo.inputs.contains(input) ? Color.white : .primary)
                                        .background(combo.inputs.contains(input) ? accent.clawSelectionFill : ClawPalette.subtleFill, in: Capsule())
                                        .overlay(Capsule().strokeBorder(ClawPalette.border, lineWidth: 0.7))
                                }.accessibilityIdentifier("comboInput-" + input.rawValue)
                                    .accessibilityAddTraits(combo.inputs.contains(input) ? .isSelected : [])
                            }
                        }
                    }
                } else {
                    Text("Tap to turn fast forward on. Tap the active button again for normal speed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
              }.padding(16)
            }.scrollDismissesKeyboard(.interactively)
        }.background { ConsoleBackdrop() }.buttonStyle(ConsolePressStyle()).consoleBackSwipe { dismiss() }
    }
    @Environment(\.clawAccent) private var accent
    private var cancelButton: some View {
        Button { InterfaceHaptics.selection(); dismiss() } label: {
            Text("Cancel").fixedSize().frame(minWidth: 64, minHeight: 44)
        }.accessibilityIdentifier("cancelComboButton")
    }
    private var saveButton: some View {
        Button {
            onSave(resolved); InterfaceHaptics.success(); dismiss()
        } label: {
            Text("Save").fixedSize().frame(minWidth: 50, minHeight: 44)
        }.disabled(!resolved.valid(for: system)).accessibilityIdentifier("saveComboButton")
    }
}
