// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
enum DiskStore {
    static let gamesDirectory = URL(fileURLWithPath: "/tmp")
    static let coverDirectory = gamesDirectory
}
@main enum ImportedSkinTests {
    static func main() async throws {
        precondition(SkinImageCodec.acceptsSource(width: 2048, height: 2048))
        precondition(SkinImageCodec.acceptsSource(width: 1242, height: 2688))
        for (w, h) in [(8192, 4096), (2048, 2049), (Int.max, 1), (1, Int.max), (0, 1), (1, 0)] {
            precondition(!SkinImageCodec.acceptsSource(width: w, height: h))
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
#if canImport(ImageIO) && canImport(CoreGraphics)
        var oversizedImageRejected = false
        do {
            _ = try SkinImageCodec.normalize(Data(contentsOf: source.appendingPathComponent("oversized-source.png")), extension: "png")
        } catch { oversizedImageRejected = true }
        precondition(oversizedImageRejected, "Oversized source reached the raster decoder")
#endif
        func archive(_ name: String) throws -> DeltaSkinArchive {
            try DeltaSkinArchive(data: Data(contentsOf: source.appendingPathComponent(name + ".deltaskin")))
        }
        for system in GameSystem.allCases {
            let name = system == .ds ? "ds" : system.rawValue
            let skin = try ImportedSkin.parse(archive(name))
            precondition(skin.system == system && skin.variants.count == 2)
            for orientation in ["portrait", "landscape"] {
                let variant = skin.variant(orientation: orientation, edgeToEdge: true)!
                for limit in [64, 384, 1024, 1600, 4096] {
                    let preview = ImportedSkinPreviewLayout(width: variant.width, height: variant.height,
                                                           maximumDimension: limit)!
                    let canvas = CGRect(origin: .zero, size: preview.size)
                    precondition(max(preview.size.width, preview.size.height) <= CGFloat(min(1600, limit)))
                    precondition(abs(preview.size.width / preview.size.height - variant.width / variant.height) < 0.04)
                    for frame in variant.screens + variant.controls.map(\.frame) {
                        let drawn = preview.drawingRect(frame)
                        precondition(canvas.insetBy(dx: -0.001, dy: -0.001).contains(drawn))
                        precondition(drawn.width > 0 && drawn.height > 0)
                    }
                    // Top/bottom author coordinates must not be transposed or
                    // centered a second time by a view-level scale transform.
                    let marker = SkinRect(x: 0, y: 0, width: variant.width / 4, height: variant.height / 4)
                    let drawn = preview.drawingRect(marker)
                    precondition(drawn.minX == 0 && abs(drawn.maxY - preview.size.height) < 0.001)
                }
                let safe = orientation == "portrait" ? CGRect(x: 12, y: 62, width: 378, height: 778) : CGRect(x: 62, y: 4, width: 750, height: 377)
                let layout = variant.layout(in: safe, mainAspect: system.aspect, hasSecondScreen: system.dualScreen)!
                precondition(abs(layout.gameplay.top.width / layout.gameplay.top.height - system.aspect) < 0.001)
                precondition(safe.contains(layout.canvas) && safe.contains(layout.gameplay.gear))
                if system.dualScreen { precondition(abs(layout.gameplay.bottom.width / layout.gameplay.bottom.height - 4 / 3) < 0.001) }
                else { precondition(layout.gameplay.bottom == .zero && layout.hitFrames["x"] == nil) }
            }
        }
        let directional = try ImportedSkin.parse(archive("digital-thumbstick"))
        for variant in directional.variants.values {
            precondition(variant.controls.contains { $0.key == "dpad" })
            precondition(variant.controls.contains { $0.key == "circle" && $0.digitalDirections == true })
            let layout = variant.layout(in: CGRect(x: 0, y: 0, width: variant.width, height: variant.height),
                                        mainAspect: GameSystem.ds.aspect, hasSecondScreen: true)!
            precondition(!layout.gameplay.circle.isEmpty && !layout.gameplay.dpad.isEmpty)
        }
        if CommandLine.arguments.count > 2 {
            let supplied = try ImportedSkin.parse(DeltaSkinArchive(data: Data(contentsOf:
                URL(fileURLWithPath: CommandLine.arguments[2]))))
            if supplied.system == .threeDS {
                precondition(supplied.variants.count == 4)
                precondition(supplied.variants.values.allSatisfy { $0.controls.contains { $0.key == "circle" } })
                print("PASS: real 3DS skin package, four iPhone variants and standard controls")
            } else {
            precondition(supplied.system == .ds)
            let landscape = supplied.variant(orientation: "landscape", edgeToEdge: true)!
            precondition(landscape.controls.contains { $0.key == "circle" && $0.digitalDirections == true })
            precondition(landscape.controls.contains { $0.key == "dpad" })
            precondition(landscape.layout(in: CGRect(x: 0, y: 0, width: 874, height: 402),
                                         mainAspect: GameSystem.ds.aspect, hasSecondScreen: true) != nil)
            print("PASS: supplied Atomic NDS skin metadata and landscape layout")
            }
        }
        let stored = try ImportedSkin.parse(archive("stored"))
        precondition(ImportedSkinPreviewLayout(width: .nan, height: 100, maximumDimension: 900) == nil)
        precondition(ImportedSkinPreviewLayout(width: 100, height: 0, maximumDimension: 900) == nil)
        precondition(ImportedSkinPreviewLayout(width: 100, height: 100, maximumDimension: 0) == nil)
        precondition(stored.system == .gb)
        for name in ["traversal", "duplicate", "corrupt", "oversized", "symlink", "not-a-skin", "wrong-system", "resource-traversal", "bad-frame"] {
            var rejected = false
            do { _ = try ImportedSkin.parse(archive(name)) } catch { rejected = true }
            precondition(rejected, "Accepted malformed fixture: \(name)")
        }
        // A missing menu is optional: the app supplies its own gear button.
        let noMenu = try ImportedSkin.parse(archive("missing-menu"))
        precondition(noMenu.warnings.contains { $0.localizedCaseInsensitiveContains("menu") })
        let noMenuVariant = noMenu.variant(orientation: "portrait", edgeToEdge: false)!
        let noMenuLayout = noMenuVariant.layout(in: CGRect(x: 0, y: 0, width: noMenuVariant.width,
                                                            height: noMenuVariant.height),
                                                  mainAspect: GameSystem.gb.aspect, hasSecondScreen: false)!
        precondition(!noMenuLayout.gameplay.gear.isEmpty)

        // Duplicate visual regions for one input are valid. Every authored
        // frame must survive; the first remains the primary hit target.
        let duplicates = try ImportedSkin.parse(archive("duplicate-controls"))
        for variant in duplicates.variants.values {
            let aControls = variant.controls.enumerated().filter { $0.element.key == "a" }
            precondition(aControls.count == 2)
            let layout = variant.layout(in: CGRect(x: 0, y: 0, width: variant.width, height: variant.height),
                                        mainAspect: GameSystem.gb.aspect, hasSecondScreen: false)!
            precondition(layout.importedFrames.count == variant.controls.count)
            precondition(layout.hitFrames["a"] != nil)
            let first = layout.importedFrames[aControls[0].offset]
            let second = layout.importedFrames[aControls[1].offset]
            precondition(first == layout.hitFrames["a"])
            precondition(second != first)
            precondition(layout.importedFrames.allSatisfy {
                CGRect(x: 0, y: 0, width: variant.width, height: variant.height).contains($0)
            })
        }

        // Edge-to-edge canvases fit the full display; standard canvases stay
        // inside the safe area. Both orientations exercise a notch/home
        // indicator-sized safe inset.
        let edgeSkin = try ImportedSkin.parse(archive("edge-to-edge"))
        // Fill validation must include every duplicate, not just the first
        // region for an input. A second A region at the edge of a square canvas
        // would be entirely outside this tall phone if fill were accepted.
        func control(_ key: String, _ x: Double, _ y: Double, _ w: Double = 60, _ h: Double = 60) -> DeltaSkinControl {
            DeltaSkinControl(key: key, frame: SkinRect(x: x, y: y, width: w, height: h))
        }
        let croppedDuplicate = DeltaSkinVariant(width: 1000, height: 1000, background: "background.png",
            screens: [SkinRect(x: 400, y: 100, width: 200, height: 160)],
            controls: [control("dpad", 400, 600), control("a", 550, 600), control("b", 450, 700),
                       control("start", 450, 850, 40, 40), control("select", 500, 850, 40, 40),
                       control("a", 0, 600, 50, 50)])
        let phoneBounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let duplicateLayout = croppedDuplicate.layout(in: CGRect(x: 0, y: 59, width: 390, height: 751),
            bounds: phoneBounds, mainAspect: GameSystem.gb.aspect, hasSecondScreen: false, edgeToEdge: true)!
        precondition(duplicateLayout.importedFrames.allSatisfy { phoneBounds.contains($0) })
        precondition(duplicateLayout.canvas.width <= phoneBounds.width)
        // A taller authored canvas can have all its mapped buttons on-screen
        // with aspect-fill while still losing its decorative top/bottom edges.
        // Preserve those edges too, as on imported portrait 3DS skins.
        let tallCanvas = DeltaSkinVariant(width: 390, height: 960, background: "background.png",
            screens: [SkinRect(x: 40, y: 100, width: 300, height: 200)],
            controls: [control("dpad", 20, 700), control("a", 280, 700), control("b", 220, 760),
                       control("start", 190, 800), control("select", 120, 800)])
        let uncropped = tallCanvas.layout(in: CGRect(x: 0, y: 59, width: 390, height: 751),
            bounds: phoneBounds, mainAspect: GameSystem.gb.aspect, hasSecondScreen: false, edgeToEdge: true)!
        precondition(phoneBounds.insetBy(dx: -0.001, dy: -0.001).contains(uncropped.canvas))
        precondition(abs(uncropped.canvas.minY) < 0.001 && abs(uncropped.canvas.maxY - phoneBounds.maxY) < 0.001)
        precondition(uncropped.canvas.width < phoneBounds.width)
        precondition(edgeSkin.variants.count == 4)
        let portraitSafe = CGRect(x: 0, y: 59, width: 390, height: 750)
        let portraitBounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let landscapeSafe = CGRect(x: 59, y: 0, width: 750, height: 390)
        let landscapeBounds = CGRect(x: 0, y: 0, width: 844, height: 390)
        for (orientation, safe, bounds) in [("portrait", portraitSafe, portraitBounds),
                                           ("landscape", landscapeSafe, landscapeBounds)] {
            let edge = edgeSkin.variant(orientation: orientation, edgeToEdge: true)!
            let filled = edge.layout(in: safe, bounds: bounds, mainAspect: GameSystem.gb.aspect,
                                     hasSecondScreen: false, edgeToEdge: true)!
            precondition(bounds.insetBy(dx: -0.001, dy: -0.001).contains(filled.canvas))
            precondition(abs(filled.canvas.width - bounds.width) < 0.5 || abs(filled.canvas.height - bounds.height) < 0.5)
            precondition(abs(filled.canvas.width / filled.canvas.height - CGFloat(edge.width / edge.height)) < 0.001)
            precondition(bounds.contains(filled.gameplay.top))
            let standard = edgeSkin.variant(orientation: orientation, edgeToEdge: false)!
            let fitted = standard.layout(in: safe, bounds: bounds, mainAspect: GameSystem.gb.aspect,
                                         hasSecondScreen: false, edgeToEdge: false)!
            precondition(safe.contains(fitted.canvas))
            // Layout is derived from the current safe area, not a size captured
            // once in viewDidLoad. A safe-area change must move/resize controls.
            let insetSafe = safe.insetBy(dx: 12, dy: 12)
            let refitted = standard.layout(in: insetSafe, bounds: bounds, mainAspect: GameSystem.gb.aspect,
                                           hasSecondScreen: false, edgeToEdge: false)!
            precondition(refitted.canvas != fitted.canvas)
            precondition(refitted.gameplay.dpad != fitted.gameplay.dpad)
            precondition(insetSafe.contains(refitted.canvas))
        }
        let optional = try ImportedSkin.parse(archive("optional-action"))
        precondition(!optional.warnings.isEmpty)
        let root = source.appendingPathComponent("installed")
        let store = ImportedSkinStore(root: root)
        let manicStore = ImportedSkinStore(root: source.appendingPathComponent("installed-manic"))
        let manic = try await manicStore.importFile(source.appendingPathComponent("manic.manicskin"))
        precondition(manic.system == .gb && manic.variants.count == 2)
        let imported = try await store.importFile(source.appendingPathComponent("gb.deltaskin"))
        let installed = try await store.list()
        precondition(installed.count == 1 && installed[0].id == imported.id)
        var failed = false
        do { _ = try await store.importFile(source.appendingPathComponent("bad-image.deltaskin")) } catch { failed = true }
        precondition(failed)
        let stillInstalled = try await store.list()
        precondition(stillInstalled.count == 1)
        let dirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        precondition(dirs.count == 1, "Failed import left partial skin files")
        let suite = "ClawSkinTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let game = UUID()
        defaults.set(imported.id, forKey: ImportedSkin.assignmentKey(system: .gb, orientation: "portrait"))
        precondition(ImportedSkin.selected(system: .gb, orientation: "portrait", game: game, defaults: defaults) == imported.id)
        precondition(ImportedSkin.selected(system: .gb, orientation: "landscape", defaults: defaults) == "obsidian")
        defaults.set("standard", forKey: ImportedSkin.assignmentKey(system: .gb, orientation: "portrait", game: game))
        precondition(ImportedSkin.selected(system: .gb, orientation: "portrait", game: game, defaults: defaults) == "obsidian")
        defaults.set("standard", forKey: ImportedSkin.assignmentKey(system: .gb, orientation: "landscape"))
        precondition(ImportedSkin.selected(system: .gb, orientation: "landscape", defaults: defaults) == "obsidian")
        let stale = UUID().uuidString
        defaults.set(stale, forKey: ImportedSkin.assignmentKey(system: .gb, orientation: "portrait", game: game))
        precondition(ImportedSkin.selected(system: .gb, orientation: "portrait", game: game,
                                          defaults: defaults, available: [imported]) == imported.id)
        // Removing one skin clears its overrides, preserving unrelated defaults.
        ImportedSkin.clearAssignments(for: stale, defaults: defaults)
        precondition(defaults.string(forKey: ImportedSkin.assignmentKey(system: .gb, orientation: "portrait", game: game)) == nil)
        precondition(ImportedSkin.selected(system: .gb, orientation: "portrait", game: game,
                                          defaults: defaults, available: [imported]) == imported.id)
        try await store.remove(imported.id)
        precondition(ImportedSkin.selected(system: .gb, orientation: "portrait", game: game,
                                          defaults: defaults, available: []) == "obsidian")
        let empty = try await store.list()
        precondition(empty.isEmpty)
        print("PASS: Delta/Manic stored/deflate/CRC, six-system metadata and aspect-correct layouts, duplicate regions, optional menu fallback, full-canvas edge-to-edge and standard fit, invalid archive/resource rejection, transactional import, optional-feature warnings, orientation defaults and per-game overrides")
    }
}
