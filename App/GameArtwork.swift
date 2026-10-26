// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

// Immutable decoded images can safely cross the decoding actor boundary.
private struct DecodedArtwork: @unchecked Sendable { let image: UIImage }
private let artworkMemoryTrimmed = Notification.Name("ClawArtworkMemoryTrimmed")
private actor ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, UIImage>()
    private var maximumPixels = 900
    init() { cache.totalCostLimit = 24 * 1024 * 1024; cache.countLimit = 48 }
    func load(_ url: URL, key: String) -> DecodedArtwork? {
        guard !Task.isCancelled else { return nil }
        if let image = cache.object(forKey: key as NSString) { return DecodedArtwork(image: image) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cg)
        guard !Task.isCancelled else { return nil }
        cache.setObject(image, forKey: key as NSString, cost: cg.bytesPerRow * cg.height)
        return DecodedArtwork(image: image)
    }
    func clear(memoryPressure: Bool) {
        cache.removeAllObjects()
        // Rebuild visible thumbnails at a smaller size after real pressure.
        // Gameplay handoff starts a fresh library image budget later.
        maximumPixels = memoryPressure ? 450 : 900
    }
}
struct DiskArtwork: View {
    static func clearLibraryCache(memoryPressure: Bool = false) async {
        await ArtworkCache.shared.clear(memoryPressure: memoryPressure)
        if memoryPressure {
            await MainActor.run { NotificationCenter.default.post(name: artworkMemoryTrimmed, object: nil) }
        }
    }
    let url: URL?
    var revision = ""
    var fill = true
    @State private var image: UIImage?
    @State private var loadedKey: String?
    @State private var visible = false
    @State private var reload = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var key: String { (url?.path ?? "") + revision }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ClawPalette.card
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .id(loadedKey).transition(.opacity)
                } else {
                    Image(systemName: "gamecontroller").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: "\(key)-\(reload)") {
            guard let url else { releaseImage(); return }
            guard loadedKey != key || image == nil else { return }
            // Keep the previous bitmap on screen while the replacement decodes.
            // Clearing it here produced a visible placeholder flash whenever a
            // cover view was recycled or briefly covered by a sheet.
            let value = await ArtworkCache.shared.load(url, key: key)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                image = value?.image
                loadedKey = key
            }
        }
        .onAppear { visible = true }
        .onDisappear {
            visible = false
            releaseIfOffscreen(active: scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            releaseIfOffscreen(active: phase == .active)
        }
        .onReceive(NotificationCenter.default.publisher(for: artworkMemoryTrimmed)) { _ in
            releaseImage()
            if visible { reload &+= 1 }
        }
    }
    private func releaseIfOffscreen(active: Bool) {
        if CoverArtLifecycle.shouldReleaseImage(visible: visible, active: active) { releaseImage() }
    }
    private func releaseImage() {
        image = nil
        loadedKey = nil
    }
}

// Use only artwork supplied by the player or embedded in the imported file.
// Files without an icon get a locally rendered system badge.
struct GameCoverArtwork: View {
    let game: Game
    var fill = true
    @Environment(\.clawAccent) private var accent
    var body: some View {
        Group {
            if let url = game.coverURL { DiskArtwork(url: url, fill: fill) }
            else {
                GeometryReader { geometry in
                    ZStack {
                        LinearGradient(colors: [accent.opacity(0.20), ClawPalette.card], startPoint: .topLeading, endPoint: .bottomTrailing)
                        VStack(spacing: 10) {
                            ConsoleSystemIcon(system: game.platform)
                                .frame(width: max(20, min(46, geometry.size.width * 0.25)),
                                       height: max(16, min(37, geometry.size.width * 0.20)))
                            if geometry.size.width >= 100 {
                                Text(ConsoleCatalog.displayName(game.name)).font(.caption.weight(.semibold)).lineLimit(3)
                                    .multilineTextAlignment(.center)
                            }
                            Text(game.platform.shortTitle).font(.caption2.weight(.bold))
                        }.padding(12).foregroundStyle(accent)
                    }
                }
            }
        }
    }
}
enum CoverImporter {
    static func store(source: URL, gameID: UUID) throws -> String {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(input, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1200] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try DiskStore.prepare()
        let name = "\(gameID.uuidString)-\(UUID().uuidString).jpg"
        let url = DiskStore.coverDirectory.appendingPathComponent(name)
        guard let data = CFDataCreateMutable(nil, 0) else { throw CocoaError(.fileWriteUnknown) }
        guard let target = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(target, cg, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { throw CocoaError(.fileWriteUnknown) }
        guard let bytes = CFDataGetBytePtr(data) else { throw CocoaError(.fileWriteUnknown) }
        try Data(bytes: bytes, count: CFDataGetLength(data)).write(to: url, options: .atomic)
        return name
    }
}

extension CoverImporter {
    static func embeddedIcon(from url: URL, gameID: UUID) -> String? {
        guard let data = try? GameFileIdentity.iconRGBA(at: url),
              let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: 48, height: 48, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 48 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        do {
            try DiskStore.prepare()
            let name = "\(gameID.uuidString)-icon.png"
            guard let bytes = CFDataCreateMutable(nil, 0) else { return nil }
            guard let output = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(output, cg, nil)
            guard CGImageDestinationFinalize(output) else { return nil }
            guard let pointer = CFDataGetBytePtr(bytes) else { return nil }
            try Data(bytes: pointer, count: CFDataGetLength(bytes)).write(to: DiskStore.coverDirectory.appendingPathComponent(name), options: .atomic)
            return name
        } catch { return nil }
    }
}
