// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import SwiftUI
import UIKit

// Event-driven feedback only. No timers, render-loop work, or gesture observers.
@MainActor enum InterfaceHaptics {
    private static let picker = UISelectionFeedbackGenerator()
    private static let impact = UIImpactFeedbackGenerator(style: .rigid)
    private static let dockImpact = UIImpactFeedbackGenerator(style: .medium)
    private static let notification = UINotificationFeedbackGenerator()
    private static var lastFeedback: TimeInterval = 0
    private static func allowed() -> Bool {
        guard UserDefaults.standard.object(forKey: "libraryHaptics") as? Bool ?? true else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFeedback > 0.06 else { return false }
        lastFeedback = now
        return true
    }
    static func selection() { if allowed() { picker.selectionChanged() } }
    static func action() { if allowed() { impact.impactOccurred(intensity: 0.7) } }
    static func dock() { if allowed() { dockImpact.impactOccurred(intensity: 0.85) } }
    static func success() { if allowed() { notification.notificationOccurred(.success) } }
    static func warning() { if allowed() { notification.notificationOccurred(.warning) } }
}

// Each capsule owns its glass sampling scope. Unrelated rows must never fuse.
private struct ConsoleGlass: ViewModifier {
    var radius: CGFloat
    var tint: Color?
    var interactive: Bool
    var floating: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        Group {
#if compiler(>=6.2)
            if #available(iOS 26, *), floating, !reduceTransparency {
                GlassEffectContainer(spacing: 0) { native(content) }
            } else { fallback(content) }
#else
            fallback(content)
#endif
        }.overlay(edge).contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
#if compiler(>=6.2)
    @available(iOS 26, *)
    @ViewBuilder private func native(_ content: Content) -> some View {
        let effect = tint.map { Glass.regular.tint($0.opacity(0.08)) } ?? Glass.regular
        if interactive {
            content.glassEffect(effect.interactive(),
                                in: .rect(cornerRadius: radius))
        } else {
            content.glassEffect(effect,
                                in: .rect(cornerRadius: radius))
        }
    }
#endif
    private var edge: some View {
        RoundedRectangle(cornerRadius: radius)
            .strokeBorder(tint?.opacity(0.22) ?? ClawPalette.border, lineWidth: 0.7)
            .allowsHitTesting(false)
    }
    private func fallback(_ content: Content) -> some View {
        content.background {
            if reduceTransparency { RoundedRectangle(cornerRadius: radius).fill(ClawPalette.card) }
            else if floating { RoundedRectangle(cornerRadius: radius).fill(.thinMaterial) }
            else { RoundedRectangle(cornerRadius: radius).fill(ClawPalette.card.opacity(scheme == .dark ? 0.84 : 0.95)) }
        }
    }
}

// Content panels share the same light/shadow vocabulary without another live
// backdrop filter underneath every nested control or offscreen settings row.
private struct ConsolePanel: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.padding(16).background {
            RoundedRectangle(cornerRadius: 26, style: .continuous).fill(ClawPalette.card.opacity(reduceTransparency ? 1 : 0.88))
        }.overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(ClawPalette.border, lineWidth: 0.7)
        }.contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

extension View {
    func clawMessage(_ title: String, message: Binding<String?>) -> some View {
        sheet(isPresented: Binding(get: { message.wrappedValue != nil },
                                  set: { if !$0 { message.wrappedValue = nil } })) {
            ClawGamePrompt(title: title, message: message.wrappedValue ?? "", confirmTitle: "OK",
                           destructive: false, initialName: nil, cancelTitle: nil, onCancel: {}) { _ in }
        }
    }
    func consoleGlass(radius: CGFloat = 100, tint: Color? = nil, interactive: Bool = false, floating: Bool = false) -> some View {
        modifier(ConsoleGlass(radius: radius, tint: tint, interactive: interactive, floating: floating))
    }
    func consoleNeon(_ color: Color, active: Bool = true) -> some View {
        // A small focus halo, without stacked shadows or a broad neon bloom.
        shadow(color: active ? color.opacity(0.16) : .clear, radius: 4)
    }
    func consolePanel() -> some View {
        modifier(ConsolePanel())
    }
}

// One uniform surface at every navigation depth. A gradient local to each
// inset page restarts at its edges and exposes rectangular seams against its
// parent. Every page uses the same adaptive charcoal or light surface.
struct ConsoleBackdrop: View {
    var body: some View {
        ClawPalette.background.ignoresSafeArea().allowsHitTesting(false)
    }
}

extension View {
    func consoleBackSwipe(enabled: Bool = true, perform: @escaping () -> Void) -> some View {
        background { ConsoleBackSwipe(enabled: enabled, action: perform) }
    }
}

// A physical left-edge gesture also works when SwiftUI hides the navigation
// bar, or Search is a state-driven page rather than a NavigationStack push.
private struct ConsoleBackSwipe: UIViewControllerRepresentable {
    let enabled: Bool
    let action: () -> Void
    func makeUIViewController(context: Context) -> EdgeController { EdgeController() }
    func updateUIViewController(_ controller: EdgeController, context: Context) {
        controller.action = action; controller.enabled = enabled
        if !enabled { controller.uninstall() }
    }
    static func dismantleUIViewController(_ controller: EdgeController, coordinator: ()) { controller.uninstall() }
    final class EdgeController: UIViewController, UIGestureRecognizerDelegate {
        var action: (() -> Void)?
        var enabled = true
        private var edge: UIScreenEdgePanGestureRecognizer?
        private weak var nativePop: UIGestureRecognizer?
        private var nativeWasEnabled = false
        override func loadView() {
            view = UIView(); view.backgroundColor = .clear; view.isUserInteractionEnabled = false
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard enabled, edge == nil, let window = view.window else { return }
            let gesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(swiped(_:)))
            gesture.edges = .left; gesture.maximumNumberOfTouches = 1; gesture.delegate = self
            gesture.delaysTouchesBegan = false
            nativePop = navigationController?.interactivePopGestureRecognizer
            nativeWasEnabled = nativePop?.isEnabled ?? false
            nativePop?.isEnabled = false
            window.addGestureRecognizer(gesture); edge = gesture
        }
        override func viewWillDisappear(_ animated: Bool) { uninstall(); super.viewWillDisappear(animated) }
        func uninstall() {
            if let edge { edge.view?.removeGestureRecognizer(edge) }
            edge = nil; nativePop?.isEnabled = nativeWasEnabled; nativePop = nil
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard enabled, view.window != nil, let edge else { return false }
            var owner: UIViewController = self
            while let parent = owner.parent { owner = parent }
            guard owner.presentedViewController == nil else { return false }
            let velocity = edge.velocity(in: edge.view)
            return velocity.x > abs(velocity.y)
        }
        @objc private func swiped(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard gesture.state == .ended, enabled else { return }
            let distance = gesture.translation(in: gesture.view), velocity = gesture.velocity(in: gesture.view)
            if distance.x > 70 || (distance.x > 20 && velocity.x > 500) { action?() }
        }
    }
}

struct ConsoleActionTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    var prominent = false
    @Environment(\.clawAccent) private var accent
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: prominent ? 27 : 23, weight: .medium))
                .foregroundStyle(accent).frame(width: 44, height: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(accent)
        }.frame(maxWidth: .infinity, minHeight: prominent ? 70 : 52, alignment: .leading)
            .padding(16)
            .background(accent.opacity(prominent ? 0.08 : 0.025), in: RoundedRectangle(cornerRadius: 20))
            .consoleGlass(radius: 20, tint: prominent ? accent : nil, interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}

struct ConsolePill<Value: Hashable>: View {
    let title: String
    let value: Value
    @Binding var selection: Value
    @Environment(\.clawAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var selected: Bool { value == selection }
    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { selection = value }
        } label: {
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, 17).frame(height: 32)
                .background(selected ? accent.clawSelectionFill : .clear, in: Capsule())
                .consoleGlass(tint: selected ? accent : nil)
                .foregroundStyle(selected ? Color.white : .primary)
                .frame(minHeight: 44)
        }.buttonStyle(ConsolePressStyle()).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
struct ConsoleSegments<Value: Hashable>: View {
    let values: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(values, id: \.self) { value in
                    ConsolePill(title: title(value), value: value, selection: $selection)
                }
            }.padding(.vertical, 5).padding(.horizontal, 2)
        }.scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true)
    }
}

// Wrapping choices keep every system visible without reducing touch targets.
struct ConsoleChoiceGrid<Value: Hashable>: View {
    let values: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    @Environment(\.clawAccent) private var accent
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 110 : 70), spacing: 8)], spacing: 8) {
            ForEach(values, id: \.self) { value in
                Button { selection = value; InterfaceHaptics.selection() } label: {
                    Text(title(value)).font(.caption.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44).padding(.horizontal, 4)
                        .foregroundStyle(selection == value ? Color.white : .primary)
                        .background(selection == value ? accent.clawSelectionFill : ClawPalette.subtleFill, in: Capsule())
                        .overlay(Capsule().strokeBorder(selection == value ? accent.opacity(0.6) : ClawPalette.border, lineWidth: 0.7))
                }.buttonStyle(ConsolePressStyle()).accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }.accessibilityElement(children: .contain)
    }
}

// Original transparent vector artwork, shared by the picker, editor and UIKit
// gameplay buttons. The button supplies its circular outline.
struct FastForwardGlyph: Shape {
    var triangles = 2
    func path(in rect: CGRect) -> Path {
        let count = max(1, min(4, triangles))
        let height = min(rect.height, rect.width / (CGFloat(count) * 0.7))
        let width = height * 0.62, gap = height * 0.08
        let start = rect.midX - (CGFloat(count) * width + CGFloat(count - 1) * gap) / 2
        var path = Path()
        for index in 0..<count {
            let x = start + CGFloat(index) * (width + gap)
            path.move(to: CGPoint(x: x, y: rect.midY - height / 2))
            path.addLine(to: CGPoint(x: x + width, y: rect.midY))
            path.addLine(to: CGPoint(x: x, y: rect.midY + height / 2))
            path.closeSubpath()
        }
        return path
    }
    @MainActor static func image(speed: Int) -> UIImage {
        let size = CGSize(width: speed == 4 ? 32 : 24, height: 18)
        let format = UIGraphicsImageRendererFormat(); format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.addPath(FastForwardGlyph(triangles: speed).path(in: CGRect(origin: .zero, size: size)).cgPath)
            context.cgContext.setFillColor(UIColor.white.cgColor); context.cgContext.fillPath()
        }.withRenderingMode(.alwaysTemplate)
    }
}

struct ClawSpeedPicker: View {
    @Binding var selection: Int
    var normalTitle = "1×"
    @Environment(\.clawAccent) private var accent
    var body: some View {
        HStack(spacing: 8) {
            ForEach([1, 2, 4], id: \.self) { speed in
                Button { selection = speed } label: {
                    HStack(spacing: 5) {
                        if speed > 1 { FastForwardGlyph(triangles: speed).fill(.primary).frame(width: speed == 4 ? 26 : 18, height: 12) }
                        Text(speed == 1 ? normalTitle : "\(speed)×").font(.caption.weight(.semibold))
                    }.frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(selection == speed ? Color.white : .primary)
                        .background(selection == speed ? accent.clawSelectionFill : ClawPalette.subtleFill, in: Capsule())
                        .overlay(Capsule().strokeBorder(selection == speed ? accent.opacity(0.6) : ClawPalette.border, lineWidth: 0.7))
                }.accessibilityLabel(speed == 1 ? normalTitle : "\(speed)×")
                    .accessibilityAddTraits(selection == speed ? .isSelected : [])
            }
        }
    }
}

// Shared by Claw and Authentic libraries: the same hardware cards, selection
// treatment and horizontal scrolling, with a larger target for larger text.
struct ConsoleSystemBar: View {
    @Binding var selection: GameSystem?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let systems: [GameSystem?] = [nil] + GameSystem.allCases.map(Optional.some)
    var body: some View {
        GeometryReader { geometry in
            let layout = ConsoleSystemBarLayout(width: geometry.size.width, largeText: typeSize >= .xxLarge)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: layout.spacing) {
                        ForEach(systems, id: \.self) { value in
                            ConsoleSystemChoice(value: value, selected: selection == value,
                                width: layout.itemWidth, height: layout.itemHeight) {
                                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { selection = value }
                                }.id(value?.rawValue ?? "all")
                        }
                    }.padding(.horizontal, 3).padding(.vertical, 6)
                        .frame(minWidth: geometry.size.width)
                }.scrollIndicators(.hidden)
                    .onAppear { proxy.scrollTo(selection?.rawValue ?? "all", anchor: .center) }
                    .onChange(of: selection) { _, value in
                        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9)) {
                            proxy.scrollTo(value?.rawValue ?? "all", anchor: .center)
                        }
                    }
            }
        }.frame(height: typeSize >= .xxLarge ? ConsoleSystemBarLayout.largeTextHeight : ConsoleSystemBarLayout.regularHeight)
            .accessibilityIdentifier("consoleSystemBar")
    }
}
struct ConsoleSystemChoice: View {
    let value: GameSystem?
    let selected: Bool
    var width: CGFloat = 92
    var height: CGFloat = 60
    let action: () -> Void
    @Environment(\.clawAccent) private var accent
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Group {
                    if let value { ConsoleSystemIcon(system: value) }
                    else { Image(systemName: "square.grid.2x2").resizable().scaledToFit().padding(1) }
                }.frame(width: 32, height: 26)
                Text(value?.shortTitle ?? "All systems").font(.caption.weight(.semibold)).lineLimit(1)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }.foregroundStyle(selected ? Color.white : .primary)
                .frame(width: width, height: height)
                .background(selected ? accent.clawSelectionFill : .clear, in: RoundedRectangle(cornerRadius: 15))
                .consoleGlass(radius: 15, tint: selected ? accent : nil)
                .contentShape(RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(ConsolePressStyle()).accessibilityLabel(value?.title ?? "All systems")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("consoleSystem-" + (value?.rawValue ?? "all"))
    }
}
struct ConsolePageHeading: View {
    let title: String
    let subtitle: String
    let symbol: String
    @Environment(\.clawAccent) private var accent
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(accent)
                .frame(width: 44, height: 44).background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.bold()).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 8)
    }
}
struct ConsoleEmptyState: View {
    let title: String
    let symbol: String
    let message: String
    var compact = false
    @Environment(\.clawAccent) private var accent
    var body: some View {
        Group {
            if compact {
                HStack(spacing: 14) {
                    icon.frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.subheadline.weight(.semibold))
                        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }.padding(14)
            } else {
                VStack(spacing: 12) {
                    icon.frame(width: 64, height: 64)
                    Text(title).font(.headline).multilineTextAlignment(.center)
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity).padding(24)
            }
        }.background {
            RoundedRectangle(cornerRadius: 22).fill(
                LinearGradient(colors: [ClawPalette.card, ClawPalette.background],
                               startPoint: .topLeading, endPoint: .bottomTrailing))
        }.overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(ClawPalette.border, lineWidth: 0.8))
            .accessibilityElement(children: .combine)
    }
    private var icon: some View {
        Image(systemName: symbol).font(.system(size: compact ? 20 : 28, weight: .semibold))
            .foregroundStyle(accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: compact ? 14 : 18))
    }
}

struct ConsoleSettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let content: Content
    let closeLabel: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.clawAccent) private var accent
    @Environment(\.dynamicTypeSize) private var typeSize
    init(title: String, subtitle: String, symbol: String, closeLabel: String = "Back", @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.closeLabel = closeLabel; self.content = content()
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Group {
                        if closeLabel == "Back" { Image(systemName: "chevron.left") }
                        else { Text(closeLabel).font(.caption.weight(.semibold)) }
                    }.font(.subheadline.weight(.semibold)).frame(minWidth: 44, minHeight: 44)
                        .background(ClawPalette.subtleFill, in: Circle())
                }.buttonStyle(ConsolePressStyle()).accessibilityLabel(closeLabel).accessibilityIdentifier("consoleBack")
                if !typeSize.isAccessibilitySize {
                    Image(systemName: symbol).font(.system(size: 20, weight: .medium))
                        .foregroundStyle(accent).frame(width: 42, height: 42)
                        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }.padding(14)
                .background(ClawPalette.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(ClawPalette.border, lineWidth: 0.7))
                .frame(maxWidth: 640).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) { content }
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(16).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { ConsoleBackdrop() }.foregroundStyle(.primary)
            .toggleStyle(ClawSettingsToggleStyle()).toolbar(.hidden, for: .navigationBar)
            .consoleBackSwipe { dismiss() }
    }
}

struct ClawOptionsPage<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        ConsoleSettingsPage(title: title, subtitle: "", symbol: symbol) {
            content()
        }
    }
}

struct ClawSettingsSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !title.isEmpty {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 4).accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 12, content: content)
                .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                .padding(16).background(ClawPalette.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(ClawPalette.border, lineWidth: 0.7))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}

struct ClawSettingsRow: View {
    let title: String
    let symbol: String
    var subtitle: String? = nil
    var value: String? = nil
    var external = false
    @Environment(\.clawAccent) private var accent
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                .foregroundStyle(accent).frame(width: 30, height: 34).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if let value {
                Text(value).font(.subheadline.monospacedDigit().weight(.medium)).foregroundStyle(accent)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Image(systemName: external ? "arrow.up.right" : "chevron.right")
                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
    }
}

// Detail pages opt in; the approved main pages keep their existing controls.
struct ClawSettingsToggleStyle: ToggleStyle {
    @Environment(\.clawAccent) private var accent
    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) { configuration.label }
            .toggleStyle(.switch).tint(accent.clawSelectionFill).frame(minHeight: 44)
    }
}

struct ClawSettingsSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    @Environment(\.clawAccent) private var accent
    private var percentage: String { value.formatted(.percent.precision(.fractionLength(0))) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(percentage).font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(accent)
                    .fixedSize().accessibilityHidden(true)
            }
            Slider(value: $value, in: range).accessibilityLabel(title).accessibilityValue(percentage)
        }
    }
}

struct ConsoleGamePicker: View {
    let title: String
    let games: [Game]
    let selected: UUID?
    var includesDefault = false
    let onSelect: (UUID?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.clawAccent) private var accent
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                Button { dismiss() } label: {
                    Text("Done").font(.subheadline.weight(.semibold)).frame(minWidth: 64, minHeight: 44)
                }.foregroundStyle(accent)
            }.padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if includesDefault {
                        row("System default", subtitle: "All games on this system", image: nil, chosen: selected == nil) {
                            onSelect(nil); dismiss()
                        }
                    }
                    ForEach(games) { game in
                        row(ConsoleCatalog.displayName(game.name), subtitle: game.platform.title,
                            image: game, chosen: selected == game.id) {
                            onSelect(game.id); dismiss()
                        }
                    }
                }
            }
        }.padding(20).background { ConsoleBackdrop() }
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            .consoleBackSwipe { dismiss() }
    }
    private func row(_ title: String, subtitle: String, image: Game?, chosen: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if let image { GameCoverArtwork(game: image) }
                    else { Image(systemName: "square.stack.3d.up").foregroundStyle(accent) }
                }.frame(width: 44, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if chosen { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(ClawPalette.card, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(chosen ? accent.opacity(0.65) : ClawPalette.border))
        }.buttonStyle(ConsolePressStyle())
    }
}
struct ConsoleMinuteStepper: View {
    @Binding var minutes: Int
    @Environment(\.clawAccent) private var accent
    var body: some View {
        HStack(spacing: 12) {
            Text("Save every").font(.subheadline)
            Spacer()
            Button { minutes = max(1, minutes - 1) } label: {
                Image(systemName: "minus").frame(width: 44, height: 44)
                    .background(ClawPalette.subtleFill, in: RoundedRectangle(cornerRadius: 12))
            }.disabled(minutes <= 1).accessibilityLabel("Decrease Auto Save interval")
            Text("\(minutes) min").font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(accent).frame(minWidth: 48).accessibilityIdentifier("autosaveIntervalValue")
            Button { minutes = min(10, minutes + 1) } label: {
                Image(systemName: "plus").frame(width: 44, height: 44)
                    .background(ClawPalette.subtleFill, in: RoundedRectangle(cornerRadius: 12))
            }.disabled(minutes >= 10).accessibilityLabel("Increase Auto Save interval")
        }.frame(minHeight: 44)
    }
}
struct ConsoleToggleStyle: ToggleStyle {
    @Environment(\.clawAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: 14) {
                configuration.label.foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? accent.clawSelectionFill : ClawPalette.subtleFill)
                    Circle().fill(.white).padding(4).frame(width: 30, height: 30)
                }.frame(width: 52, height: 30)
                    .overlay(Capsule().strokeBorder(configuration.isOn ? accent : ClawPalette.border, lineWidth: 1))
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(ConsolePressStyle()).accessibilityValue(configuration.isOn ? "On" : "Off")
            .accessibilityAddTraits(.isButton)
    }
}
struct ConsolePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .contentShape(Rectangle())
            .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.4)
            .animation(reduceMotion ? nil : .spring(response: 0.23, dampingFraction: 0.8), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed && enabled { InterfaceHaptics.action() }
            }
    }
}

// In-app branding always follows the UI accent. The installed app icon has
// its own independent preferences, managed by AppIconSync.
struct ConsoleBrand: View {
    @Environment(\.clawAccent) private var accent
    var body: some View {
        HStack(spacing: 9) {
            ClawMark().fill(accent)
                .frame(width: 30, height: 32)
                .accessibilityHidden(true)
            Text("Claw").font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
        }.foregroundStyle(.primary).frame(minHeight: 44)
            .accessibilityElement(children: .combine).accessibilityIdentifier("clawBrand")
    }
}

struct ConsoleSortMenu: View {
    @Binding var selection: String
    let count: Int
    let total: Int
    var showsLabel = false
    var system: Binding<GameSystem?>? = nil
    var favoritesOnly: Binding<Bool>? = nil
    @State private var showing = false
    @Environment(\.clawAccent) private var accent
    var body: some View {
        Button { showing = true } label: {
            if showsLabel {
                HStack(spacing: 12) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(accent)
                    Text(system == nil ? "Sort games" : "Sort & filter").font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                    Text((ConsoleSort(rawValue: selection) ?? .recent).title)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 52).padding(.horizontal, 16)
                    .consoleGlass(radius: 28).contentShape(Capsule())
            } else {
                Image(systemName: "line.3.horizontal.decrease").font(.subheadline)
                    .foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(Rectangle())
            }
        }.accessibilityLabel(system == nil ? "Sort games" : "Sort and filter games")
            .accessibilityValue("\(count) games, " + (ConsoleSort(rawValue: selection) ?? .recent).title)
            .accessibilityIdentifier("librarySort")
            .sheet(isPresented: $showing) {
              ConsoleSettingsPage(title: "Sort & filter", subtitle: "\(count) of \(total) games", symbol: "line.3.horizontal.decrease", closeLabel: "Done") {
            if let system {
                ConsoleSegments(values: [Optional<GameSystem>.none] + GameSystem.allCases.map { Optional($0) }, selection: system) { $0?.shortTitle ?? "All" }
            }
            if let favoritesOnly { Toggle("Favorites only", isOn: favoritesOnly) }
            ForEach(ConsoleSort.allCases) { option in
                Button { selection = option.rawValue; showing = false } label: {
                    HStack {
                        Text(option.title)
                        Spacer()
                        if selection == option.rawValue { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
                    }.frame(minHeight: 44).consolePanel()
                }.buttonStyle(ConsolePressStyle())
            }
              }.presentationDetents([.medium, .large])
            }
    }
}

// One live battery source for the library and the in-game menu. Consumers are
// reference-counted, observers are installed exactly once, and app transitions
// suspend hardware reads without clearing the last valid readings.
@MainActor
final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()
    @Published private(set) var level: Float = -1
    @Published private(set) var charging = false

    private var consumers = 0
    private var ownsMonitoring = false
    private var suspended = false
    private var observers: [NSObjectProtocol] = []

    var percentText: String { BatteryPresentation.percentText(level) }
    var chargingText: String { BatteryPresentation.accessibilityText(level, charging: charging) }

    func begin() {
        consumers += 1
        guard consumers == 1 else { refresh(); return }
        installObservers()
        suspended = UIApplication.shared.applicationState != .active
        guard !suspended else { return }
        enableMonitoring()
        refresh()
    }
    func end() {
        guard consumers > 0 else { return }
        consumers -= 1
        guard consumers == 0 else { return }
        removeObservers()
        disableMonitoring()
        suspended = false
    }
    func refresh() {
        guard consumers > 0, !suspended else { return }
        let nextLevel = UIDevice.current.batteryLevel
        if nextLevel.isFinite, nextLevel >= 0 {
            let clamped = min(1, max(0, nextLevel))
            if level != clamped { level = clamped }
        }
        let nextCharging: Bool
        switch UIDevice.current.batteryState {
        case .charging, .full: nextCharging = true
        case .unplugged: nextCharging = false
        case .unknown: nextCharging = charging
        @unknown default: nextCharging = charging
        }
        if charging != nextCharging { charging = nextCharging }
    }
    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIDevice.batteryLevelDidChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(center.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        })
    }
    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
    private func enableMonitoring() {
        guard !UIDevice.current.isBatteryMonitoringEnabled else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        ownsMonitoring = true
    }
    private func disableMonitoring() {
        guard ownsMonitoring else { return }
        UIDevice.current.isBatteryMonitoringEnabled = false
        ownsMonitoring = false
    }
    private func suspend() {
        guard consumers > 0 else { return }
        suspended = true
        disableMonitoring()
    }
    private func resume() {
        guard consumers > 0 else { return }
        suspended = false
        enableMonitoring()
        refresh()
    }
}

@MainActor
struct BatteryStatusLabel: View {
    @ObservedObject var monitor: BatteryMonitor
    let accent: Color
    var showsBackground = false
    var identifier = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Image(systemName: BatteryPresentation.symbolName(monitor.level))
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7, weight: .black))
                    .opacity(monitor.charging ? 1 : 0)
            }.frame(width: 24, height: 16)
            Text(monitor.percentText)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                .frame(width: 38, alignment: .trailing)
                .contentTransition(reduceMotion ? .identity : .numericText(value: Double(monitor.level)))
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(accent)
        .consoleNeon(accent)
        .padding(.horizontal, showsBackground ? 10 : 0)
        .padding(.vertical, showsBackground ? 5 : 0)
        .background {
            if showsBackground {
                Capsule().fill(ClawPalette.card.opacity(0.55))
                    .overlay(Capsule().strokeBorder(accent.opacity(0.45), lineWidth: 0.8))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: monitor.level)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: monitor.charging)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(monitor.chargingText)
        .accessibilityIdentifier(identifier)
    }
}

// The only clock/battery observation lives here; it never invalidates the
// carousel. The clock remains rendered while inactive so Control Center and the
// app switcher cannot collapse or replay the pill.
@MainActor
struct ConsoleStatusCapsule: View {
    @AppStorage("showLibraryClock") private var showClock = true
    @AppStorage("showLibraryBattery") private var showBattery = true
    @Environment(\.clawAccent) private var accent
    @ObservedObject private var battery = BatteryMonitor.shared
    @State private var observingBattery = false
    var body: some View {
        HStack(spacing: 7) {
            if showClock {
                TimelineView(.periodic(from: Date(timeIntervalSince1970:
                    (Date().timeIntervalSince1970 / 60).rounded(.down) * 60), by: 60)) { context in
                        Text(context.date, format: .dateTime.hour().minute())
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                            .frame(width: 67).frame(minHeight: 44)
                }.accessibilityIdentifier("libraryClock")
            }
            if showClock && showBattery { Rectangle().fill(ClawPalette.border).frame(width: 1, height: 14) }
            if showBattery {
                BatteryStatusLabel(monitor: battery, accent: accent, identifier: "libraryBattery")
            }
        }.font(.caption2.weight(.medium)).foregroundStyle(.primary)
            .padding(.horizontal, 10).frame(minHeight: 44)
            .background { Color.clear.frame(height: 32).consoleGlass().allowsHitTesting(false) }
            .fixedSize(horizontal: true, vertical: false)
            .onAppear { syncBatteryMonitoring() }
            .onDisappear { stopBatteryMonitoring() }
            .onChange(of: showBattery) { _, _ in syncBatteryMonitoring() }
    }
    private func syncBatteryMonitoring() {
        if showBattery && !observingBattery {
            battery.begin(); observingBattery = true
        } else if !showBattery && observingBattery {
            battery.end(); observingBattery = false
        }
    }
    private func stopBatteryMonitoring() {
        guard observingBattery else { return }
        battery.end(); observingBattery = false
    }
}

struct ConsolePlaytimeBadge: View {
    let seconds: Double?
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.fill")
            VStack(alignment: .leading, spacing: 1) {
                Text("Time played").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(ConsoleCatalog.playtime(seconds)).font(.caption.weight(.semibold)).monospacedDigit()
            }
        }.padding(.horizontal, 12).padding(.vertical, 6)
            .consoleGlass(radius: 18, interactive: false).allowsHitTesting(false)
            .accessibilityElement(children: .combine)
    }
}

struct ConsoleGameActions: View {
    let game: Game
    let onFavorite: (Game) -> Void
    let onCover: (Game) -> Void
    let onRemoveCover: (Game) -> Void
    let onDelete: (Game) -> Void
    @AppStorage("showLibraryPlaytime") private var showPlaytime = true
    var body: some View {
        if showPlaytime { Text("Time played: \(ConsoleCatalog.playtime(game.playedSeconds))") }
        Button(game.favorite == true ? "Remove from favorites" : "Add to favorites", systemImage: "heart") { onFavorite(game) }
        Button("Choose cover artwork", systemImage: "photo") { onCover(game) }
        if game.coverFile != nil {
            Button("Remove cover artwork", systemImage: "trash", role: .destructive) {
                InterfaceHaptics.warning(); onRemoveCover(game)
            }
        }
        Divider()
        Button("Delete ROM", systemImage: "trash", role: .destructive) { onDelete(game) }
    }
}
