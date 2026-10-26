// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

enum ClawAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
enum ClawAccent: String, CaseIterable, Identifiable {
    case orange, blue, green, red, custom
    var id: String { rawValue }
    // Preserve a removed preset as the user's custom color on upgrade.
    static func legacyRGB(for name: String) -> Int? {
        ["violet": 0x7A4AF5, "teal": 0x149EA6, "pink": 0xE6529E, "gold": 0xEB991A][name]
    }
    static let defaultCustomRGB = 0x7A4AF5
    static func customColor(_ rgb: Int) -> Color {
        Color(red: Double((rgb >> 16) & 255) / 255,
              green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    var color: Color {
        switch self {
        case .orange: return Self.customColor(0xFF8538)
        case .blue: return Color(red: 0.20, green: 0.56, blue: 0.98)
        case .green: return Color(red: 0.15, green: 0.68, blue: 0.38)
        case .red: return Color(red: 0.86, green: 0.24, blue: 0.26)
        case .custom: return Self.customColor(Self.defaultCustomRGB)
        }
    }
}
// Choose the higher-contrast label for opaque user-selected accents.
extension Color {
    // Preserve the chosen hue while keeping white selected-tab labels readable.
    var clawSelectionFill: Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
        let brightness = max(r, max(g, b))
        let factor: CGFloat = clawReadableLabel == .black ? 0.44 / max(0.44, brightness) : 1
        return Color(red: Double(r * factor), green: Double(g * factor), blue: Double(b * factor))
    }
    var clawReadableLabel: Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return .white }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return luminance > 0.179 ? .black : .white
    }
}
private struct ClawAccentKey: EnvironmentKey { static let defaultValue = ClawAccent.orange.color }
extension EnvironmentValues {
    var clawAccent: Color {
        get { self[ClawAccentKey.self] }
        set { self[ClawAccentKey.self] = newValue }
    }
}
enum ClawPalette {
    static let background = adaptive(
        dark: UIColor(red: 0.115, green: 0.125, blue: 0.13, alpha: 1),
        light: UIColor(red: 0.965, green: 0.969, blue: 0.980, alpha: 1))
    static let card = adaptive(
        dark: UIColor(red: 0.09, green: 0.105, blue: 0.12, alpha: 1),
        light: UIColor.white)
    static let border = adaptive(
        dark: UIColor.white.withAlphaComponent(0.12),
        light: UIColor.black.withAlphaComponent(0.10))
    static let subtleFill = adaptive(
        dark: UIColor.white.withAlphaComponent(0.05),
        light: UIColor.black.withAlphaComponent(0.05))

    private static func adaptive(dark: UIColor, light: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}
struct ClawStyle: ViewModifier {
    @AppStorage("clawAccent") private var accent = ClawAccent.orange.rawValue
    @AppStorage("clawAppearance") private var appearance = ClawAppearance.dark.rawValue
    @AppStorage("clawCustomAccentRGB") private var customRGB = ClawAccent.defaultCustomRGB
    func body(content: Content) -> some View {
        let selected = ClawAccent(rawValue: accent) ?? .orange
        let legacy = ClawAccent.legacyRGB(for: accent)
        let color = legacy.map(ClawAccent.customColor) ??
            (selected == .custom ? ClawAccent.customColor(customRGB) : selected.color)
        content.tint(color).environment(\.clawAccent, color).toggleStyle(ConsoleToggleStyle()).buttonStyle(ConsolePressStyle())
            .preferredColorScheme((ClawAppearance(rawValue: appearance) ?? .dark).colorScheme)
            .task(id: accent) {
                if let legacy { customRGB = legacy; accent = ClawAccent.custom.rawValue }
            }
    }
}
extension View {
    func clawCard() -> some View {
        consolePanel()
    }
}
struct ClawPrimaryButton: ButtonStyle {
    @Environment(\.clawAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold)).foregroundStyle(accent.clawReadableLabel)
            .padding(.horizontal, 22).frame(minHeight: 44)
            .background(accent.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.4)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.85), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed && enabled { InterfaceHaptics.action() }
            }
    }
}
// The connected, hooked silhouette of the app icon, fitted without distortion.
struct ClawMark: Shape {
    func path(in r: CGRect) -> Path {
        let side = min(r.width, r.height)
        let origin = CGPoint(x: r.midX - side / 2, y: r.midY - side / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * side, y: origin.y + y * side)
        }
        var path = Path()
        path.move(to: point(0.682, 0.002))
        path.addCurve(to: point(0.000, 0.456), control1: point(0.355, -0.012), control2: point(0.105, 0.176))
        path.addCurve(to: point(0.425, 0.096), control1: point(0.105, 0.268), control2: point(0.261, 0.158))
        path.addCurve(to: point(0.161, 0.668), control1: point(0.292, 0.257), control2: point(0.195, 0.447))
        path.addCurve(to: point(0.650, 0.290), control1: point(0.274, 0.488), control2: point(0.449, 0.356))
        path.addCurve(to: point(0.306, 0.834), control1: point(0.494, 0.452), control2: point(0.373, 0.655))
        path.addCurve(to: point(0.854, 0.554), control1: point(0.465, 0.658), control2: point(0.649, 0.558))
        path.addCurve(to: point(0.472, 1.000), control1: point(0.794, 0.672), control2: point(0.539, 0.769))
        path.addCurve(to: point(0.998, 0.498), control1: point(0.607, 0.735), control2: point(0.941, 0.685))
        path.addCurve(to: point(0.500, 0.582), control1: point(0.809, 0.474), control2: point(0.658, 0.520))
        path.addCurve(to: point(0.969, 0.175), control1: point(0.600, 0.397), control2: point(0.770, 0.270))
        path.addCurve(to: point(0.334, 0.371), control1: point(0.732, 0.172), control2: point(0.516, 0.225))
        path.addCurve(to: point(0.682, 0.002), control1: point(0.412, 0.194), control2: point(0.535, 0.074))
        path.closeSubpath()
        return path
    }
}
