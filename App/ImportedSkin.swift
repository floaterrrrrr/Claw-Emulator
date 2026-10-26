// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct DeltaSkinControl: Codable, Sendable {
    let key: String
    let frame: SkinRect
    var asset: String?
    var digitalDirections: Bool? = nil
}
struct DeltaSkinVariant: Codable, Sendable {
    let width, height: Double
    var background: String
    let screens: [SkinRect]
    var controls: [DeltaSkinControl]
}
struct ImportedSkin: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let system: GameSystem
    var variants: [String: DeltaSkinVariant]
    let warnings: [String]
    // Keep the actual key so callers know whether the selected artwork was an
    // edge-to-edge canvas or a standard canvas reached through fallback.
    func variantKey(orientation: String, edgeToEdge: Bool) -> String? {
        let preferred = (edgeToEdge ? "edgeToEdge" : "standard") + "." + orientation
        if variants[preferred] != nil { return preferred }
        let standard = "standard." + orientation
        if variants[standard] != nil { return standard }
        let edge = "edgeToEdge." + orientation
        if variants[edge] != nil { return edge }
        return nil
    }
    func variant(orientation: String, edgeToEdge: Bool) -> DeltaSkinVariant? {
        variantKey(orientation: orientation, edgeToEdge: edgeToEdge).flatMap { variants[$0] }
    }
    func compatible(with other: GameSystem) -> Bool {
        system == other || ([GameSystem.gb, .gbc].contains(system) && [GameSystem.gb, .gbc].contains(other))
    }
    var assets: Set<String> {
        Set(variants.values.flatMap { [$0.background] + $0.controls.compactMap(\.asset) })
    }
    static func assignmentKey(system: GameSystem, orientation: String, game: UUID? = nil) -> String {
        "claw.skin." + (game.map { "game." + $0.uuidString } ?? system.rawValue) + "." + orientation
    }
    static func selected(system: GameSystem, orientation: String, game: UUID? = nil,
                         defaults: UserDefaults = .standard, available: [ImportedSkin]? = nil) -> String {
        func usable(_ value: String) -> Bool {
            if value == "obsidian" { return true }
            guard let available else { return UUID(uuidString: value) != nil }
            return available.contains { $0.id == value && $0.compatible(with: system) &&
                $0.variant(orientation: orientation, edgeToEdge: true) != nil }
        }
        if let game, let value = defaults.string(forKey: assignmentKey(system: system, orientation: orientation, game: game)),
           value == "standard" { return "obsidian" }
        if let game, let value = defaults.string(forKey: assignmentKey(system: system, orientation: orientation, game: game)),
           usable(value) { return value }
        if let value = defaults.string(forKey: assignmentKey(system: system, orientation: orientation)),
           value == "standard" { return "obsidian" }
        if let value = defaults.string(forKey: assignmentKey(system: system, orientation: orientation)),
           usable(value) { return value }
        return "obsidian"
    }
    static func clearAssignments(for id: String, defaults: UserDefaults = .standard) {
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("claw.skin.") {
            if value as? String == id { defaults.removeObject(forKey: key) }
        }
    }
    static func parse(_ archive: DeltaSkinArchive) throws -> ImportedSkin {
        let manifests = archive.files.keys.filter { $0 == "info.json" || $0.hasSuffix("/info.json") }
        guard manifests.count == 1, let manifest = manifests.first, let data = archive.files[manifest],
              data.count <= 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = root["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 120, let identifier = root["gameTypeIdentifier"] as? String else {
            throw SkinImportError("This skin is missing a valid info.json file.")
        }
        let platform = identifier.lowercased().split(separator: ".").last.map(String.init) ?? ""
        // Delta uses "ds"; some Manic packages use the native "nds" spelling.
        let normalizedPlatform = ["ds", "nds"].contains(platform) ? GameSystem.ds.rawValue : platform
        guard let system = GameSystem(rawValue: normalizedPlatform),
              let representations = root["representations"] as? [String: Any],
              let iphone = representations["iphone"] as? [String: Any] else {
            throw SkinImportError("This skin does not support a system available in Claw on iPhone.")
        }
        let folder = manifest == "info.json" ? "" : String(manifest.dropLast(9))
        func resource(_ name: String) throws -> String {
            let path = folder + name
            guard DeltaSkinArchive.safePath(name), let bytes = archive.files[path], !bytes.isEmpty,
                  ["png", "jpg", "jpeg", "pdf"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else {
                throw SkinImportError("A required PNG, JPEG or PDF skin image is missing.")
            }
            return path
        }
        // JSONSerialization represents whole numbers as NSNumber. Accept both
        // integer and floating-point spellings used by Delta and Manic editors.
        func number(_ value: Any?) -> Double? {
            if let value = value as? Double { return value }
            if let value = value as? NSNumber { return value.doubleValue }
            if let value = value as? Int { return Double(value) }
            return nil
        }
        func rectangle(_ object: Any?, width: Double, height: Double) throws -> SkinRect {
            guard let value = object as? [String: Any],
                  let x = number(value["x"]), let y = number(value["y"]),
                  let w = number(value["width"]), let h = number(value["height"]),
                  x.isFinite, y.isFinite, w.isFinite, h.isFinite,
                  x >= 0, y >= 0, w > 0, h > 0, x + w <= width + 0.01, y + h <= height + 0.01 else {
                throw SkinImportError("This skin has a screen or control outside its canvas.")
            }
            return SkinRect(x: x, y: y, width: w, height: h)
        }
        let aliases = ["a": "a", "b": "b", "x": "x", "y": "y", "l": "l", "r": "r",
                       "l1": "l", "r1": "r", "leftshoulder": "l", "rightshoulder": "r",
                       "start": "start", "select": "select", "menu": "menu",
                       "quicksave": "save", "savestate": "save", "quickload": "load", "loadstate": "load",
                       "dpad": "dpad", "directionalpad": "dpad",
                       "leftthumbstick": "circle", "leftstick": "circle", "analogstick": "circle"]
        var variants: [String: DeltaSkinVariant] = [:], warnings = Set<String>()
        for trait in ["standard", "edgeToEdge"] {
            guard let orientations = iphone[trait] as? [String: Any] else { continue }
            for orientation in ["portrait", "landscape"] {
                guard let value = orientations[orientation] as? [String: Any] else { continue }
                guard let mapping = value["mappingSize"] as? [String: Any],
                      let width = number(mapping["width"]), let height = number(mapping["height"]),
                      width.isFinite, height.isFinite, width >= 100, height >= 100, width <= 4096, height <= 4096,
                      let assets = value["assets"] as? [String: String],
                      let asset = assets["resizable"] ?? assets["large"] ?? assets["medium"] ?? assets["small"],
                      let rawScreens = value["screens"] as? [[String: Any]],
                      rawScreens.count == (system.dualScreen ? 2 : 1),
                      let items = value["items"] as? [[String: Any]], items.count <= 64 else {
                    throw SkinImportError("This skin needs a valid iPhone canvas and separate game-screen rectangles.")
                }
                let screens = try rawScreens.map { try rectangle($0["outputFrame"] ?? $0, width: width, height: height) }
                var controls: [DeltaSkinControl] = [], keys = Set<String>()
                for item in items {
                    var key: String?
                    var digitalDirections = false
                    if let directions = item["inputs"] as? [String: String] {
                        let values = directions.values.map { $0.lowercased() }
                        if Set(values) == Set(["up", "down", "left", "right"]) {
                            digitalDirections = item["thumbstick"] != nil
                            key = digitalDirections ? "circle" : "dpad"
                        } else if values.contains(where: { $0.hasPrefix("leftthumbstick") }) {
                            key = "circle"
                        } else if values.contains(where: { $0.hasPrefix("rightthumbstick") }) {
                            warnings.insert("Right-thumbstick mappings are not used by this system.")
                        } else if values.contains(where: { $0.hasPrefix("touchscreen") }) {
                            continue // The screen view already owns exact touch mapping.
                        } else if Set(values).count == 1, let value = Set(values).first, let mapped = aliases[value] {
                            key = mapped
                        } else if !values.isEmpty {
                            warnings.insert("Combined-button mappings are not supported.")
                        }
                    } else {
                        let inputs = ((item["inputs"] as? [String]) ?? (item["inputs"] as? String).map { [$0] } ?? [])
                            .map { $0.lowercased() }
                        if Set(inputs) == Set(["up", "down", "left", "right"]) {
                            digitalDirections = item["thumbstick"] != nil
                            key = digitalDirections ? "circle" : "dpad"
                        } else if inputs.contains(where: { $0.hasPrefix("leftthumbstick") }) {
                            key = "circle"
                        } else if inputs.contains(where: { $0.hasPrefix("rightthumbstick") }) {
                            warnings.insert("Right-thumbstick mappings are not used by this system.")
                        } else if inputs.contains(where: { $0.hasPrefix("touchscreen") }) {
                            continue
                        } else if inputs.count == 1, let mapped = aliases[inputs[0]] {
                            key = mapped
                        } else if !inputs.isEmpty {
                            warnings.insert("Combined-button mappings are not supported.")
                        }
                    }
                    guard let key, system.showsControl(key) else {
                        warnings.insert("Some optional skin controls are not supported by this system.")
                        continue
                    }
                    // Multiple visual regions may intentionally send the same
                    // input (for example a decorative duplicate face button).
                    // Keep every control so all author geometry and artwork
                    // survive; the layout keeps one primary hit frame per key.
                    keys.insert(key)
                    let frame = try rectangle(item["frame"], width: width, height: height)
                    let asset = item["asset"]
                    let art = (asset as? [String: Any])?["normal"] as? String ?? asset as? String
                    let stick = (item["thumbstick"] as? [String: Any])?["name"] as? String
                    controls.append(DeltaSkinControl(key: key, frame: frame, asset: try (art ?? stick).map(resource),
                                                      digitalDirections: digitalDirections ? true : nil))
                    if item["animation"] != nil { warnings.insert("Custom animations use a static appearance.") }
                }
                var required: Set<String> = ["dpad", "a", "b", "start", "select"]
                if system.dualScreen { required.formUnion(["x", "y", "l", "r"]) }
                if system == .gba { required.formUnion(["l", "r"]) }
                if system == .threeDS { required.insert("circle") }
                guard required.isSubset(of: keys) else {
                    throw SkinImportError("This skin is missing required controls: " + required.subtracting(keys).sorted().joined(separator: ", ") + ".")
                }
                if !keys.contains("menu") {
                    warnings.insert("No menu control was mapped; Claw's built-in menu button will be used.")
                }
                variants[trait + "." + orientation] = DeltaSkinVariant(width: width, height: height,
                    background: try resource(asset), screens: screens, controls: controls)
            }
        }
        guard !variants.isEmpty else { throw SkinImportError("This skin has no supported iPhone layouts.") }
        return ImportedSkin(id: UUID().uuidString, name: name, system: system, variants: variants, warnings: warnings.sorted())
    }
}

actor ImportedSkinStore {
    static let shared = ImportedSkinStore()
    let root: URL
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClawSkins", isDirectory: true)) { self.root = root }
    func list() throws -> [ImportedSkin] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }.compactMap {
                guard let data = try? Data(contentsOf: $0.appendingPathComponent("skin.json")) else { return nil }
                return try? JSONDecoder().decode(ImportedSkin.self, from: data)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    func load(_ id: String) throws -> ImportedSkin? { try list().first { $0.id == id } }
    func directory(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func remove(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { return }
        try FileManager.default.removeItem(at: directory(id))
        ImportedSkin.clearAssignments(for: id)
    }
    func importFile(_ url: URL) throws -> ImportedSkin {
        guard ["deltaskin", "manicskin"].contains(url.pathExtension.lowercased()) else { throw SkinImportError("Choose a compatible skin file.") }
#if os(iOS) || os(macOS)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
#endif
        var archiveData: Data?
        var readError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: readable.path)
                guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 32 * 1024 * 1024 else {
                    throw SkinImportError("The skin file is too large.")
                }
                archiveData = try Data(contentsOf: readable)
            } catch { readError = error }
        }
        if let error = coordinationError { throw error }
        if let error = readError { throw error }
        guard let archiveData else { throw SkinImportError("The skin file could not be read.") }
        let archive = try DeltaSkinArchive(data: archiveData)
        var skin = try ImportedSkin.parse(archive)
        let folder = directory(skin.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: folder) } }
        var names: [String: String] = [:], memory = 0
        for (index, name) in skin.assets.sorted().enumerated() {
            let normalized = try SkinImageCodec.normalize(archive.files[name]!, extension: URL(fileURLWithPath: name).pathExtension)
            memory += normalized.decodedBytes
            guard memory <= 48 * 1024 * 1024 else { throw SkinImportError("This skin uses too much image memory. Try a smaller skin.") }
            let target = "asset-\(index).png"
            try normalized.data.write(to: folder.appendingPathComponent(target), options: .atomic)
            names[name] = target
        }
        for key in Array(skin.variants.keys) {
            var variant = skin.variants[key]!
            variant.background = names[variant.background]!
            for index in variant.controls.indices {
                if let old = variant.controls[index].asset { variant.controls[index].asset = names[old] }
            }
            skin.variants[key] = variant
        }
        try JSONEncoder().encode(skin).write(to: folder.appendingPathComponent("skin.json"), options: .atomic)
        committed = true
        return skin
    }
}
