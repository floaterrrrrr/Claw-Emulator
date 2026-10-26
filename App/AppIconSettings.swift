// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

@MainActor
final class AppIconCoordinator: ObservableObject {
    static let shared = AppIconCoordinator()
    @Published private(set) var error: String?
    private var pending: AppIconColor?
    private var updating = false

    func request(_ color: AppIconColor) {
#if !CLAW_FRONTEND_FIXTURE
        guard UIApplication.shared.supportsAlternateIcons else { return }
        pending = color
        guard !updating else { return }
        updating = true
        Task { await applyPending() }
#endif
    }
    private func applyPending() async {
        defer { updating = false }
        while let target = pending {
            pending = nil
            guard UIApplication.shared.applicationState == .active else { return }
            guard UIApplication.shared.alternateIconName != target.alternateName else { error = nil; continue }
            do {
                try await UIApplication.shared.setAlternateIconName(target.alternateName)
                error = nil
            } catch {
                self.error = "The icon could not be changed. " + error.localizedDescription
            }
        }
    }
}

// Only attached to the library. Debouncing a color-wheel gesture avoids repeated
// icon changes, and the system API is never called while gameplay is presented.
@MainActor
struct AppIconSync: ViewModifier {
    let enabled: Bool
    @AppStorage("clawAccent") private var accent = ClawAccent.orange.rawValue
    @AppStorage("clawCustomAccentRGB") private var customRGB = ClawAccent.defaultCustomRGB
    @AppStorage("appIconMatchesAccent") private var matchAccent = true
    @AppStorage("appIconColorRGB") private var manualRGB = AppIconColor.orange.rgb
    @AppStorage("appIconOriginal") private var original = false
    @Environment(\.scenePhase) private var phase
    private var choice: AppIconColor {
        .resolve(accent: accent, customRGB: customRGB, matchAccent: matchAccent,
                 manualRGB: manualRGB, original: original)
    }
    func body(content: Content) -> some View {
        content.task(id: "\(choice.rawValue)-\(enabled)-\(phase)") {
            guard enabled, phase == .active else { return }
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled else { return }
            AppIconCoordinator.shared.request(choice)
        }
    }
}

@MainActor
struct AppIconSettings: View {
    @AppStorage("clawAccent") private var accentName = ClawAccent.orange.rawValue
    @AppStorage("clawCustomAccentRGB") private var customRGB = ClawAccent.defaultCustomRGB
    @AppStorage("appIconMatchesAccent") private var matchAccent = true
    @AppStorage("appIconColorRGB") private var manualRGB = AppIconColor.orange.rgb
    @AppStorage("appIconOriginal") private var original = false
    @ObservedObject private var coordinator = AppIconCoordinator.shared
    @Environment(\.clawAccent) private var accent
    private var selected: AppIconColor {
        .resolve(accent: accentName, customRGB: customRGB, matchAccent: matchAccent,
                 manualRGB: manualRGB, original: original)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("App icon", systemImage: "app.badge").font(.subheadline.weight(.semibold))
            Toggle("Match accent color", isOn: $matchAccent).accessibilityIdentifier("appIconMatchesAccent")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                ForEach(AppIconColor.choices) { color in
                    Button {
                        matchAccent = false
                        original = false
                        manualRGB = color.rgb
                    } label: {
                        VStack(spacing: 4) {
                            ClawMark().fill(ClawAccent.customColor(color.rgb))
                                .padding(11).frame(width: 50, height: 50)
                                .background(color == .original ? Color.white : Color(red: 0.05, green: 0.08, blue: 0.10),
                                            in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(selected == color ? accent : .clear, lineWidth: 2))
                            Text(color.title).font(.caption2).foregroundStyle(.primary)
                        }.frame(maxWidth: .infinity, minHeight: 70)
                    }.accessibilityLabel("\(color.title) app icon")
                        .accessibilityAddTraits(selected == color ? .isSelected : [])
                }
            }
            Button {
                matchAccent = false
                original = true
            } label: {
                HStack {
                    Label("Revert to original", systemImage: "arrow.uturn.backward")
                    Spacer()
                    if selected == .original { Image(systemName: "checkmark") }
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.accessibilityIdentifier("revertOriginalIcon")
            Text(matchAccent ? "The icon follows your accent. Custom colors use the closest available icon."
                 : "Using \(selected.title).")
                .font(.caption).foregroundStyle(.secondary)
            if let error = coordinator.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
