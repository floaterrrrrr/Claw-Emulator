// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit
import Metal

// Identity is presentation only. Recommendations come from the native engine,
// rather than a second Swift policy that can drift out of sync.
private struct DeviceProfileSummary: Sendable {
    let identifier: String
    let name: String
    let memoryGB: Int
    let cpu: String
    let resolution: Int
    let metalFX: Int
    var rendering: String { metalFX == 2 ? "2× → 4× · MetalFX" : "Native \(resolution)×" }
    static let current: DeviceProfileSummary = {
        let identifier = String(cString: Claw3DSDeviceModel())
        let names = [
            "iPhone11,8": "iPhone XR", "iPhone11,2": "iPhone XS",
            "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max",
            "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone12,8": "iPhone SE (2nd generation)",
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12",
            "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
            "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,6": "iPhone SE (3rd generation)", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
            "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
            "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air"
        ]
        #if targetEnvironment(simulator)
        let name = "iOS Simulator · \(names[identifier] ?? identifier)"
        #else
        let name = names[identifier] ?? (identifier.hasPrefix("iPhone") ? "iPhone" : "Apple device")
        #endif
        return DeviceProfileSummary(identifier: identifier, name: name,
            memoryGB: Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()),
            cpu: cpuName(identifier),
            resolution: Int(Claw3DSDefaultResolution()), metalFX: Int(Claw3DSDefaultMetalFXInput()))
    }()
    private static func cpuName(_ identifier: String) -> String {
#if targetEnvironment(simulator)
        return "Simulator host · \(ProcessInfo.processInfo.processorCount) cores"
#else
        // Apple's Metal device identity includes the actual A-series SoC.
        // Read it once; this also recognizes chips newer than our model list.
        if let name = MTLCreateSystemDefaultDevice()?.name,
           name.range(of: "^Apple A[0-9]+", options: .regularExpression) != nil {
            return name.replacingOccurrences(of: " GPU", with: "")
        }
        let known: [String: String] = [
            "iPhone16,1": "A17 Pro", "iPhone16,2": "A17 Pro",
            "iPhone17,1": "A18 Pro", "iPhone17,2": "A18 Pro",
            "iPhone17,3": "A18", "iPhone17,4": "A18", "iPhone17,5": "A18",
            "iPhone18,1": "A19 Pro", "iPhone18,2": "A19 Pro", "iPhone18,3": "A19", "iPhone18,4": "A19 Pro"
        ]
        if let chip = known[identifier] { return "Apple " + chip }
        let generation = Int(identifier.replacingOccurrences(of: "iPhone", with: "").split(separator: ",").first ?? "")
        let chips = [11: "A12 Bionic", 12: "A13 Bionic", 13: "A14 Bionic", 14: "A15 Bionic", 15: "A16 Bionic"]
        if identifier.hasPrefix("iPhone"), let generation, let chip = chips[generation] { return "Apple " + chip }
        return "Apple silicon · \(ProcessInfo.processInfo.processorCount) cores"
#endif
    }
}

struct ClawSettings: View {
    var games: [Game] = []
    let exporting: Bool
    let onImportKeys: () -> Void
    let onExport: () -> Void
    @AppStorage("clawAccent") private var accentName = ClawAccent.orange.rawValue
    @AppStorage("clawCustomAccentRGB") private var customRGB = ClawAccent.defaultCustomRGB
    @AppStorage("clawAppearance") private var appearance = ClawAppearance.dark.rawValue
    @AppStorage("clawLibraryInterface") private var libraryInterface = ConsoleLibraryInterface.modern.rawValue
    @AppStorage("automaticGraphicsProfile") private var automatic = true
    @AppStorage("resolution") private var resolution = 2
    @AppStorage("metalFXInput") private var metalFX = 2
    @AppStorage("cpuClock") private var clock = 100
    @AppStorage("gameVolume") private var volume = 1.0
    @AppStorage("controllerSkin") private var skin = true
    @AppStorage("gameOrientation") private var orientation = GameplayOrientation.automatic.rawValue
    @AppStorage("showGameStats") private var stats = true
    @AppStorage("controlHaptics") private var haptics = true
    @AppStorage("controlOpacity") private var opacity = 0.85
    @AppStorage("autosaveEnabled") private var autosave = true
    @AppStorage("autosaveMinutes") private var autosaveMinutes = 5
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ConsolePageHeading(title: "Settings", subtitle: "Make Claw yours.", symbol: "gearshape.fill")
                section("YOUR LIBRARY") {
                    NavigationLink { SkinSettingsView(games: games, showsBack: true) } label: {
                        row("Skins", "Portrait and landscape layouts", "gamecontroller")
                    }.accessibilityIdentifier("settingsSkins")
                    Divider()
                    NavigationLink { ConsoleLibrarySettings() } label: {
                        row("Library & status", "Playtime, clock, battery and feedback", "slider.horizontal.3")
                    }
                }
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Library interface", systemImage: "rectangle.3.group")
                        ConsoleSegments(values: ConsoleLibraryInterface.allCases.map(\.rawValue), selection: $libraryInterface) {
                            (ConsoleLibraryInterface(rawValue: $0) ?? .modern).title
                        }.accessibilityIdentifier("libraryInterface")
                        Text((ConsoleLibraryInterface(rawValue: libraryInterface) ?? .modern).summary)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Appearance", systemImage: "paintpalette")
                        ConsoleSegments(values: ClawAppearance.allCases.map(\.rawValue), selection: $appearance) { $0.capitalized }
                            .accessibilityIdentifier("clawAppearance")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Accent color").font(.subheadline)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4),
                                  alignment: .leading, spacing: 8) {
                            ForEach(ClawAccent.allCases.filter { $0 != .custom }) { accent in
                                Button { accentName = accent.rawValue } label: {
                                    Circle().fill(accent == .custom ? ClawAccent.customColor(customRGB) : accent.color)
                                        .frame(width: 28, height: 28).padding(8)
                                        .overlay(Circle().stroke(accentName == accent.rawValue ? Color.primary : .clear, lineWidth: 2))
                                }.accessibilityLabel("\(accent.rawValue.capitalized) accent")
                                    .accessibilityAddTraits(accentName == accent.rawValue ? .isSelected : [])
                            }
                        }
                        ColorPicker("Custom accent", selection: customAccentColor, supportsOpacity: false)
                            .frame(minHeight: 44).accessibilityIdentifier("customAccentColor")
                        if accentName == ClawAccent.custom.rawValue {
                            Label("Custom color selected", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    AppIconSettings()
                }.clawCard()
                section("PLAY YOUR WAY") {
                    NavigationLink { graphics } label: {
                        row("Graphics", automatic ? "Automatic · \(DeviceProfileSummary.current.name)" : "Manual · \(resolution)×", "gamecontroller")
                    }.accessibilityIdentifier("settingsGraphics")
                    Divider()
                    NavigationLink { controls } label: {
                        row("Controls & skins", skin ? "Obsidian" : "Standard controls", "gamecontroller")
                    }
                    Divider()
                    NavigationLink { HandheldControlsSettingsPage() } label: {
                        row("Handheld controls", "Button layout, combos & opacity", "dpad")
                    }.accessibilityIdentifier("settingsHandheldControls")
                    Divider()
                    NavigationLink { audio } label: { row("Audio", "Mix with your music", "speaker.wave.2") }
                }
                section("YOUR PROGRESS") {
                    NavigationLink { saveSettings } label: {
                        row("Save states", autosave ? "Auto Save every \(autosaveMinutes) \(autosaveMinutes == 1 ? "minute" : "minutes")" : "Auto Save off", "clock.arrow.circlepath")
                    }
                    Divider()
                    Button(action: onExport) { row("Back up your saves", exporting ? "Preparing…" : "Export a copy", "square.and.arrow.up") }
                        .disabled(exporting)
                }
                section("ABOUT CLAW") {
                    NavigationLink { help } label: { row("Help & support", nil, "questionmark.circle") }
                    Divider()
                    NavigationLink { legal } label: { row("Legal & Licenses", nil, "doc.text") }
                }
            }.padding(4)
        }.background { ConsoleBackdrop() }.foregroundStyle(.primary)
            .toolbar(.hidden, for: .navigationBar)
    }
    private var customAccentColor: Binding<Color> {
        Binding(get: { ClawAccent.customColor(customRGB) }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
            func channel(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
            customRGB = (channel(r) << 16) | (channel(g) << 8) | channel(b)
            accentName = ClawAccent.custom.rawValue
        })
    }
    private func section<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(spacing: 14, content: content).clawCard()
        }
    }
    private func row(_ title: String, _ subtitle: String?, _ icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }.frame(minHeight: 44).contentShape(Rectangle())
    }
    private var graphics: some View {
        ConsoleSettingsPage(title: "Graphics", subtitle: "Built around your device.", symbol: "sparkles.tv") {
            ClawSettingsSection(title: "Rendering", footer: "Applies to 3DS games on your next launch. Other systems use their native resolution.") {
                Toggle("Automatic device settings", isOn: $automatic)
            }
            ClawSettingsSection(title: "Your device") {
                Text(DeviceProfileSummary.current.name).font(.headline)
                Divider()
                LabeledContent("Memory", value: "\(DeviceProfileSummary.current.memoryGB) GB")
                LabeledContent("CPU", value: DeviceProfileSummary.current.cpu)
                LabeledContent("Recommended", value: DeviceProfileSummary.current.rendering)
            }
            ClawSettingsSection(title: "Resolution", footer: automatic ? "Managed by your device profile." : "MetalFX uses a 2× input to produce a 4× image.") {
                ConsoleSegments(values: Array(1...4), selection: Binding(get: {
                    automatic ? DeviceProfileSummary.current.resolution : resolution
                }, set: { resolution = $0 })) { "\($0)×" }
                    .disabled(automatic || (Claw3DSMetalFXSupported() && metalFX != 0))
            }
            ClawSettingsSection(title: "MetalFX", footer: Claw3DSMetalFXSupported() ? nil : "MetalFX is unavailable on this device.") {
                ConsoleSegments(values: [0, 2], selection: Binding(get: {
                    Claw3DSMetalFXSupported() ? (automatic ? DeviceProfileSummary.current.metalFX : metalFX) : 0
                }, set: { metalFX = $0 })) { $0 == 0 ? "Off" : "2× → 4×" }
                    .disabled(automatic || !Claw3DSMetalFXSupported())
            }
            ClawSettingsSection(title: "Emulated CPU", footer: "Changes the emulated CPU clock. Underclocking may cause freezes. JIT remains disabled.") {
                ConsoleSegments(values: [100, 75], selection: Binding(get: { automatic ? 100 : clock }, set: { clock = $0 })) {
                    $0 == 100 ? "100% · recommended" : "75% · experimental"
                }.disabled(automatic)
            }
            Button {
                automatic = true; resolution = Int(Claw3DSDefaultResolution())
                metalFX = Int(Claw3DSDefaultMetalFXInput()); clock = 100
            } label: {
                Label("Restore recommended settings", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(ClawPrimaryButton())
        }
    }
    private var controls: some View {
        ConsoleSettingsPage(title: "Controls", subtitle: "Make every press feel right.", symbol: "gamecontroller.fill") {
            ClawSettingsSection(title: "Display") {
                Text("Orientation").font(.subheadline.weight(.medium))
                ConsoleSegments(values: GameplayOrientation.allCases.map(\.rawValue), selection: $orientation) {
                    GameplayOrientation(rawValue: $0)?.title ?? $0
                }
            }
            ClawSettingsSection(title: "Skin & layout") {
                NavigationLink { SkinSettingsView(games: games, showsBack: true) } label: {
                    ClawSettingsRow(title: "Choose a skin", symbol: "rectangle.on.rectangle", subtitle: "Browse or import your own")
                }
                Divider()
                NavigationLink { HandheldControlsSettingsPage() } label: {
                    ClawSettingsRow(title: "Game Boy controls", symbol: "dpad", subtitle: "Screen and button layout")
                }
                Divider()
                Toggle("Obsidian controls", isOn: $skin)
                Divider()
                ClawSettingsSlider(title: "Skin control opacity", value: $opacity, range: 0.35...1)
            }
            ClawSettingsSection(title: "Feedback") {
                Toggle("Control haptics", isOn: $haptics)
                Divider()
                Toggle("Show performance", isOn: $stats)
            }
        }
    }
    private var audio: some View {
        ConsoleSettingsPage(title: "Audio", subtitle: "Your games. Your mix.", symbol: "speaker.wave.2.fill") {
            ClawSettingsSection(title: "Volume") {
                ClawSettingsSlider(title: "Game volume", value: $volume)
            }
            ClawSettingsSection(title: "Playback speed") {
                Label("2× · Faster, higher-pitched audio", systemImage: "forward.fill")
                Divider()
                Label("4× · Game audio muted", systemImage: "speaker.slash.fill")
            }
        }
    }
    private var saveSettings: some View {
        ConsoleSettingsPage(title: "Save states", subtitle: "Pick up where you left off.", symbol: "externaldrive.fill") {
            ClawSettingsSection(title: "Automatic saves", footer: "Three rotating snapshots, kept separately from your eight manual save slots.") {
                Toggle("Auto Save", isOn: $autosave)
                Divider()
                ConsoleMinuteStepper(minutes: $autosaveMinutes).disabled(!autosave)
            }
            ClawSettingsSection(title: "About snapshots") {
                Label("Manual saves ask for confirmation.", systemImage: "checkmark.shield")
                Divider()
                Text("Capturing a snapshot briefly pauses the game. It finishes saving in the background.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Label("Keep using the game’s own save menu for lasting progress.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
    }
    private var help: some View {
        ConsoleSettingsPage(title: "Help & support", subtitle: "Ready for your next adventure.", symbol: "questionmark.circle") {
            ClawSettingsSection(title: "Getting started", footer: "Import only games you have the right to use. ZIP and 7z archives containing one game are supported.") {
                Text("Import your games from the Library using the Import button.")
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Supported files").font(.subheadline.weight(.medium))
                    Text("3DS · .cia, .cci, .3ds, .3dsx, .cxi, .app\nDS · .nds    GBA · .gba\nGB · .gb    GBC · .gbc    NES · .nes")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Encrypted 3DS files require console keys supplied by you.").font(.caption).foregroundStyle(.secondary)
                }
            }
            ClawSettingsSection(title: "Console setup", footer: "Import keys from your own console when needed for your games.") {
                Button(action: onImportKeys) {
                    ClawSettingsRow(title: "Import console keys", symbol: "key", subtitle: "Choose your console’s key file")
                }
            }
            ClawSettingsSection(title: "Quick tips") {
                Label("Touch and hold a game to change its cover artwork.", systemImage: "photo")
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Label("Save and load snapshots from the in-game menu.", systemImage: "clock.arrow.circlepath")
                    .fixedSize(horizontal: false, vertical: true)
            }
            ClawSettingsSection(title: "Need a hand?") {
                Link(destination: URL(string: "mailto:feedback@salamlabs.io?subject=Claw%20support")!) {
                    ClawSettingsRow(title: "Contact support", symbol: "envelope", subtitle: "We’re here to help", external: true)
                }
            }
        }
    }
    private var legal: some View {
        ConsoleSettingsPage(title: "Legal & licenses", subtitle: "Privacy, source and third-party notices.", symbol: "lock.shield") {
            ClawSettingsSection(title: "Privacy") {
                legalLink("Privacy policy", resource: "PrivacyPolicy", symbol: "hand.raised")
            }
            ClawSettingsSection(title: "Licenses & notices") {
                legalLink("Open source notices", resource: "ThirdPartyNotices", symbol: "doc.text")
                Divider()
                legalLink("Third-party licenses", resource: "DependencyLicenses", symbol: "doc.on.doc")
                Divider()
                legalLink("Emulator licences", resource: "RetroCoreLicenses", symbol: "gamecontroller")
                Divider()
                legalLink("GNU GPL v3", resource: "GPL-3.0", symbol: "doc.plaintext")
            }
            ClawSettingsSection(title: "Source & credits") {
                Link(destination: URL(string: "https://github.com/floaterrrrrr/Claw-Emulator")!) {
                    ClawSettingsRow(title: "Claw source", symbol: "chevron.left.forwardslash.chevron.right", external: true)
                }

            }
            ClawSettingsSection(title: "Trademarks") {
                Text("Claw is an independent emulator and is not affiliated with, authorized, sponsored, or endorsed by Nintendo. Nintendo and its console names are trademarks of Nintendo. All console names and other trademarks belong to their respective owners and are used solely to identify platform compatibility.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func legalLink(_ title: String, resource: String, symbol: String) -> some View {
        NavigationLink { LegalDocumentView(title: title, resource: resource) } label: {
            ClawSettingsRow(title: title, symbol: symbol)
        }
    }
}
