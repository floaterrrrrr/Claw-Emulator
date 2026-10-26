// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import ImageIO

struct SkinSettingsView: View {
    let games: [Game]
    let showsBack: Bool
    let importOnAppear: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var system = GameSystem.threeDS
    @State private var orientation = "portrait"
    @State private var gameID: UUID?
    @State private var choosingGame = false
    @State private var skins: [ImportedSkin] = []
    @State private var selected = "obsidian"
    @State private var importing = false
    @State private var busy = false
    @State private var message: String?
    @State private var error: String?
    @State private var preview: SkinPreviewChoice?
    @State private var presentedInitialImport = false
    @AppStorage("claw.skinRevision") private var revision = 0
    @Environment(\.clawAccent) private var accent
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    init(games: [Game], system: GameSystem = .threeDS, showsBack: Bool = false, importOnAppear: Bool = false) {
        self.games = games
        self.showsBack = showsBack
        self.importOnAppear = importOnAppear
        _system = State(initialValue: system)
    }
    private var key: String { ImportedSkin.assignmentKey(system: system, orientation: orientation, game: gameID) }
    private var selectedGameName: String {
        guard let gameID, let game = games.first(where: { $0.id == gameID }) else { return "System default" }
        return ConsoleCatalog.displayName(game.name)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    if showsBack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left").frame(width: 44, height: 44).consoleGlass()
                        }.accessibilityLabel("Back").buttonStyle(ConsolePressStyle())
                    }
                    ConsolePageHeading(title: "Skins", subtitle: "Your controls, in every orientation.", symbol: "gamecontroller.fill")
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("SYSTEM").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ConsoleChoiceGrid(values: GameSystem.allCases, selection: $system) { $0.shortTitle }
                        .accessibilityIdentifier("skinSystemPicker")
                    ConsoleSegments(values: ["portrait", "landscape"], selection: $orientation) { $0.capitalized }
                }.clawCard()
                HStack {
                    Text(orientation.capitalized + " layouts").font(.headline)
                    Spacer()
                    Text(system.shortTitle).font(.caption.weight(.medium)).foregroundStyle(accent)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                         count: orientation == "landscape" || typeSize.isAccessibilitySize ? 1 : 2), spacing: 14) {
                    choice(id: "obsidian", name: "Obsidian", preview: nil)
                    ForEach(skins.filter { $0.compatible(with: system) && $0.variant(orientation: orientation, edgeToEdge: true) != nil }) { skin in
                        choice(id: skin.id, name: skin.name, preview: skin)
                            .contextMenu {
                                Button("Delete skin", systemImage: "trash", role: .destructive) {
                                    InterfaceHaptics.warning()
                                    Task { await remove(skin) }
                                }
                            }
                    }
                    Button { importing = true } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "plus.circle").font(.title)
                            Text("Import skin").font(.subheadline.weight(.medium))
                        }.foregroundStyle(accent).frame(maxWidth: .infinity, minHeight: orientation == "portrait" ? 270 : 160)
                            .background(ClawPalette.subtleFill, in: RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(accent.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
                    }.buttonStyle(ConsolePressStyle()).disabled(busy).accessibilityIdentifier("importSkin")
                }
                if busy { ProgressView("Preparing skin…") }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Use as default", isOn: Binding(get: { gameID == nil }, set: { value in
                        gameID = value ? nil : games.first(where: { $0.platform == system })?.id
                        refreshSelection()
                    })).disabled(games.allSatisfy { $0.platform != system })
                    Text(gameID == nil ? "Apply to all games of this system." : "This choice applies only to the selected game.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { choosingGame = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "gamecontroller").foregroundStyle(accent)
                            Text(selectedGameName).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }.frame(minHeight: 44).padding(.horizontal, 12)
                            .background(ClawPalette.subtleFill, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ClawPalette.border, lineWidth: 0.8))
                    }.accessibilityLabel("Per-game skin")
                        .disabled(games.allSatisfy { $0.platform != system })
                    if gameID != nil {
                        Button {
                            UserDefaults.standard.removeObject(forKey: key)
                            revision += 1; refreshSelection()
                        } label: {
                            Text("Use system skin for this game").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    }
                    Divider()
                    Button { choose("obsidian") } label: {
                        Text("Reset to Obsidian").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }.clawCard()
                Text("A skin changes artwork and control positions. Your emulator, game saves and graphics settings stay the same. Some custom skin actions or animations may not be supported.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(20)
        }.background { ConsoleBackdrop() }.accessibilityIdentifier("skinBrowser")
            .navigationTitle("Controls & skins").navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .tint(accent)
            .toggleStyle(ConsoleToggleStyle())
            .consoleBackSwipe(enabled: showsBack) { dismiss() }
            .task(id: revision) { await reload(); refreshSelection() }
            .task {
                guard importOnAppear, !presentedInitialImport else { return }
                presentedInitialImport = true
                await Task.yield()
                guard !Task.isCancelled else { return }
                importing = true
            }
            .fullScreenCover(item: $preview) { choice in
                SkinFullPreview(choice: choice, system: system, orientation: orientation,
                                isSelected: selected == choice.id, onChoose: { choose(choice.id) })
            }
            .sheet(isPresented: $choosingGame) {
                ConsoleGamePicker(title: "Apply skin to", games: games.filter { $0.platform == system },
                                  selected: gameID, includesDefault: true) { gameID = $0 }
            }
            .onChange(of: system) { _, _ in gameID = nil; refreshSelection() }
            .onChange(of: orientation) { _, _ in refreshSelection() }
            .onChange(of: gameID) { _, _ in refreshSelection() }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.data]) { result in
                switch result {
                case .success(let url): Task { await importSkin(url) }
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .clawMessage("Could not import skin", message: $error)
    }
    private func choice(id: String, name: String, preview: ImportedSkin?) -> some View {
        VStack(spacing: 0) {
            Button { self.preview = SkinPreviewChoice(id: id, name: name, skin: preview) } label: {
                SkinPreviewArtwork(id: id, skin: preview, system: system, orientation: orientation)
                    .frame(height: orientation == "portrait" ? 270 : 180)
                    .overlay {
                        Label("Preview", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8).consoleGlass()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(ConsolePressStyle()).accessibilityLabel("Preview \(name), \(orientation)")
                .accessibilityIdentifier("previewSkin-\(id)")
            Button { choose(id) } label: {
                HStack {
                    Text(name).font(.subheadline.weight(.medium)).lineLimit(2)
                    Spacer(minLength: 0)
                    Image(systemName: selected == id ? "checkmark.circle.fill" : "circle").foregroundStyle(accent)
                }.foregroundStyle(.primary).frame(minHeight: 44).padding(.horizontal, 6)
                    .consoleGlass(radius: 12, tint: selected == id ? accent : nil)
            }.buttonStyle(ConsolePressStyle()).accessibilityLabel("Use \(name) for \(orientation)")
                .accessibilityAddTraits(selected == id ? .isSelected : [])
        }.padding(10).background(ClawPalette.card.opacity(reduceTransparency ? 1 : 0.55), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(selected == id ? accent : ClawPalette.border, lineWidth: selected == id ? 1.5 : 0.8))
    }
    private func choose(_ id: String) {
        UserDefaults.standard.set(id, forKey: key)
        UserDefaults.standard.set(true, forKey: "controllerSkin")
        if system.hasHandheldOverlay {
            UserDefaults.standard.set(false, forKey: HandheldControlsConfiguration.key(system, "enabled"))
            NotificationCenter.default.post(name: .handheldControlsChanged, object: nil)
        }
        selected = id; revision += 1
        message = "Applies when you next launch the game."
    }
    private func refreshSelection() {
        selected = ImportedSkin.selected(system: system, orientation: orientation, game: gameID, available: skins)
    }
    private func reload() async {
        do { skins = try await ImportedSkinStore.shared.list() }
        catch { self.error = error.localizedDescription }
    }
    private func importSkin(_ url: URL) async {
        busy = true
        defer { busy = false }
        do {
            let skin = try await ImportedSkinStore.shared.importFile(url)
            system = skin.system; gameID = nil
            if skin.variant(orientation: orientation, edgeToEdge: true) == nil {
                orientation = orientation == "portrait" ? "landscape" : "portrait"
            }
            await reload()
            message = "Imported \(skin.name). Select it to apply." +
                (skin.warnings.isEmpty ? "" : " " + skin.warnings.joined(separator: " "))
        } catch { self.error = error.localizedDescription }
    }
    private func remove(_ skin: ImportedSkin) async {
        do { try await ImportedSkinStore.shared.remove(skin.id); revision += 1 }
        catch { self.error = error.localizedDescription }
    }
}

private struct SkinPreviewChoice: Identifiable {
    let id: String
    let name: String
    let skin: ImportedSkin?
}

private struct SkinFullPreview: View {
    let choice: SkinPreviewChoice
    let system: GameSystem
    let orientation: String
    let isSelected: Bool
    let onChoose: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(choice.name).font(.headline)
                    Text(system.shortTitle + " · " + orientation.capitalized).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44).consoleGlass()
                }.accessibilityLabel("Close preview")
            }
            SkinPreviewArtwork(id: choice.id, skin: choice.skin, system: system, orientation: orientation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("Preview only. Game screens appear black.").font(.caption).foregroundStyle(.secondary)
            Button { onChoose(); dismiss() } label: {
                Label(isSelected ? "Selected skin" : "Use skin", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(ClawPrimaryButton())
        }.padding(20).background { ConsoleBackdrop() }.consoleBackSwipe { dismiss() }
    }
}

// Built-ins are rendered once from the same production layout/artwork used in
// gameplay. Imported previews retain their authored aspect and control assets.
private struct SkinPreviewArtwork: View {
    let id: String
    let skin: ImportedSkin?
    let system: GameSystem
    let orientation: String
    @State private var bitmap: UIImage?
    @State private var failure: String?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.clawAccent) private var accent
    private var canvas: CGSize {
        orientation == "portrait" ? CGSize(width: 393, height: 852) : CGSize(width: 852, height: 393)
    }
    var body: some View {
        GeometryReader { geometry in
            let dimension = max(geometry.size.width, geometry.size.height)
            let desired = dimension.isFinite ? Int(min(1600, max(64, ceil(dimension * min(3, displayScale))))) : 64
            let pixels = min(1600, ((desired + 127) / 128) * 128)
            Group {
                if let bitmap {
                    Image(uiImage: bitmap).resizable().scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityIdentifier("skinPreviewBitmap-" + id)
                } else if let failure {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark").font(.title2)
                        Text(failure).font(.caption).multilineTextAlignment(.center)
                    }.foregroundStyle(.secondary).padding(12)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Color.black.overlay { ProgressView().tint(accent) }
                }
            }.task(id: "\(id)-\(system.rawValue)-\(orientation)-\(pixels)-\(accent.description)") {
                failure = nil
                guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                if let skin {
                    do {
                        guard let variant = skin.variant(orientation: orientation, edgeToEdge: true) else {
                            throw SkinImportError("No layout for this orientation.")
                        }
                        let directory = await ImportedSkinStore.shared.directory(skin.id)
                        let image = try await ImportedSkinPreviewRasterizer.shared.render(variant: variant,
                            directory: directory, maximumDimension: pixels)
                        guard !Task.isCancelled else { return }
                        bitmap = image.image
                    } catch {
                        if !Task.isCancelled { failure = "Preview unavailable. Try importing this skin again." }
                    }
                    return
                }
                await Task.yield()
                guard !Task.isCancelled else { return }
                let bounds = CGRect(origin: .zero, size: canvas)
                if id == "obsidian", let bundled = ControllerSkin.bundled,
                   let layout = ControllerSkinLayout.make(skin: bundled, in: bounds,
                       mainAspect: system.aspect, hasSecondScreen: system.dualScreen, hasAnalog: system == .threeDS) {
                    bitmap = SkinArtworkSnapshot.image(skin: bundled, layout: layout, opacity: 1,
                        system: system, imported: nil, size: canvas, displayScale: 1)
                } else {
                    let renderer = ImageRenderer(content: ClassicSkinPreview(system: system, size: canvas)
                        .frame(width: canvas.width, height: canvas.height).environment(\.clawAccent, accent))
                    renderer.scale = 1
                    bitmap = renderer.uiImage
                }
            }
        }.background(.black).clipped().allowsHitTesting(false)
            .onDisappear { bitmap = nil }
    }
}

// Immutable bitmap returned from the serial background renderer. Decoders and
// control images are released one at a time; only the bounded composite is kept.
private struct SkinPreviewBitmap: @unchecked Sendable { let image: UIImage }
private actor ImportedSkinPreviewRasterizer {
    static let shared = ImportedSkinPreviewRasterizer()
    func render(variant: DeltaSkinVariant, directory: URL, maximumDimension: Int) throws -> SkinPreviewBitmap {
        try Task.checkCancellation()
        guard let layout = ImportedSkinPreviewLayout(width: variant.width, height: variant.height,
                                                     maximumDimension: maximumDimension),
              let context = CGContext(data: nil, width: Int(layout.size.width), height: Int(layout.size.height),
                  bitsPerComponent: 8, bytesPerRow: Int(layout.size.width) * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SkinImportError("The preview canvas is invalid.")
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: layout.size))
        context.setBlendMode(.normal)
        context.interpolationQuality = .high
        func draw(_ name: String, frame: SkinRect) throws {
            try Task.checkCancellation()
            try autoreleasepool {
                let rect = layout.drawingRect(frame)
                let pixels = max(1, Int(ceil(max(rect.width, rect.height))))
                guard let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(name) as CFURL,
                          [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: pixels,
                        kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                    throw SkinImportError("A preview image is missing.")
                }
                // Source-over preserves alpha: transparent controls never gain
                // the opaque card rectangles used by game-cover placeholders.
                context.draw(image, in: rect)
            }
        }
        try draw(variant.background, frame: SkinRect(x: 0, y: 0, width: variant.width, height: variant.height))
        for screen in variant.screens { context.fill(layout.drawingRect(screen)) }
        for control in variant.controls {
            if let asset = control.asset { try draw(asset, frame: control.frame) }
        }
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw SkinImportError("The preview could not be rendered.") }
        return SkinPreviewBitmap(image: UIImage(cgImage: image))
    }
}

private struct ClassicSkinPreview: View {
    let system: GameSystem
    let size: CGSize
    @Environment(\.clawAccent) private var accent
    var body: some View {
        let layout = GameplayLayout.make(in: CGRect(origin: .zero, size: size),
            mainAspect: system.aspect, hasSecondScreen: system.dualScreen)
        ZStack(alignment: .topLeading) {
            Color(white: 0.06)
            ForEach(Array([layout.top, layout.bottom].filter { !$0.isEmpty }.enumerated()), id: \.offset) { _, rect in
                RoundedRectangle(cornerRadius: 8).fill(.black)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.15), lineWidth: 1))
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
            }
            Image(systemName: "dpad.fill").resizable().scaledToFit().foregroundStyle(.gray)
                .frame(width: layout.dpad.width, height: layout.dpad.height)
                .position(x: layout.dpad.midX, y: layout.dpad.midY)
            if system == .threeDS {
                Circle().fill(.gray.opacity(0.4)).padding(16)
                    .frame(width: layout.circle.width, height: layout.circle.height)
                    .position(x: layout.circle.midX, y: layout.circle.midY)
            }
            let side = layout.face.width / 3
            ForEach(Array(["x", "y", "a", "b"].enumerated()), id: \.offset) { index, key in
                if system.showsControl(key) {
                    let offsets: [CGPoint] = [CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 2, y: 1), CGPoint(x: 1, y: 2)]
                    Text(key.uppercased()).font(.system(size: 20, weight: .semibold)).foregroundStyle(accent)
                        .frame(width: side, height: side).background(.gray.opacity(0.2), in: Circle())
                        .position(x: layout.face.minX + (offsets[index].x + 0.5) * side,
                                  y: layout.face.minY + (offsets[index].y + 0.5) * side)
                }
            }
            control("SELECT", layout.select); control("START", layout.start)
            if system.showsControl("l") { control("L", layout.leftShoulder); control("R", layout.rightShoulder) }
        }
    }
    private func control(_ title: String, _ frame: CGRect) -> some View {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            .frame(width: frame.width, height: frame.height).background(.gray.opacity(0.2), in: Capsule())
            .position(x: frame.midX, y: frame.midY)
    }
}
