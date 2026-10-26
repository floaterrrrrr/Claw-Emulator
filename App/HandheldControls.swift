// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension GameSystem {
    var hasHandheldOverlay: Bool { self == .gb || self == .gbc || self == .gba }
}

enum HandheldControl: String, CaseIterable, Identifiable, Codable {
    case dpad, a, b, l, r, select, start, menu, edit, up, down, left, right
    var id: String { rawValue }
    var title: String { self == .dpad ? "D-pad" : self == .menu ? "Menu" : self == .edit ? "Edit shortcut" : rawValue.capitalized }
    static func available(for system: GameSystem) -> [Self] {
        [.dpad, .a, .b, .l, .r, .select, .start, .menu, .edit].filter { system == .gba || ($0 != .l && $0 != .r) }
    }
}
enum HandheldMovement: String, CaseIterable, Identifiable {
    case dpad, joystick
    var id: String { rawValue }
    var title: String { self == .dpad ? "D-pad" : "Joystick" }
}
struct HandheldCombo: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var inputs: [HandheldControl]
    // Nil keeps existing saved button combos compatible with speed buttons.
    var speed: Int? = nil
    var key: String { "combo-" + id.uuidString }
    static func automaticName(for inputs: [HandheldControl], speed: Int? = nil) -> String {
        if let speed { return "\(speed)×" }
        return inputs.map { input in
            switch input {
            case .start, .select: return "S"
            case .up: return "↑"
            case .down: return "↓"
            case .left: return "←"
            case .right: return "→"
            default: return input.rawValue.uppercased()
            }
        }.joined(separator: "+")
    }
    static func resolvedName(_ name: String, inputs: [HandheldControl], speed: Int? = nil) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? automaticName(for: inputs, speed: speed) : trimmed
    }
    static func inputs(for system: GameSystem) -> [HandheldControl] {
        HandheldControl.available(for: system).filter { $0 != .dpad && $0 != .menu && $0 != .edit } + [.up, .down, .left, .right]
    }
    func valid(for system: GameSystem) -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 24 else { return false }
        if let speed { return system == .gba && (speed == 2 || speed == 4) && inputs.isEmpty }
        return !inputs.isEmpty && Set(inputs).count == inputs.count &&
            inputs.allSatisfy { Self.inputs(for: system).contains($0) }
    }
    var summary: String { speed.map { "\($0)× fast forward" } ?? inputs.map(\.title).joined(separator: " + ") }
    var keys: [PadKey] { inputs.sorted { ($0 == .l || $0 == .r ? 0 : 1) < ($1 == .l || $1 == .r ? 0 : 1) }.compactMap {
        switch $0 { case .a: return .a; case .b: return .b; case .l: return .l; case .r: return .r
        case .select: return .select; case .start: return .start
        case .up: return .up; case .down: return .down; case .left: return .left; case .right: return .right
        default: return nil }
    } }
}
// One viewport policy for both orientations: show the complete original image.
enum HandheldViewport {
    static func frame(in bounds: CGRect, aspect: Double) -> CGRect {
        guard aspect.isFinite, aspect > 0 else { return bounds }
        let width = min(bounds.width, bounds.height * aspect), height = width / aspect
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }
}

struct HandheldPlacement: Codable, Equatable {
    // v3: center follows the canvas axes; both dimensions use its shortest side.
    let x, y, width, height: Double
    var valid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && (0...1).contains(x) && (0...1).contains(y) &&
            width > 0 && width <= 1 && height > 0 && height <= 1
    }
}
struct HandheldControlLayout: Codable, Equatable {
    var version = 3
    var controls: [String: HandheldPlacement] = [:]
    var valid: Bool {
        [1, 2, 3].contains(version) && controls.count <= 25 && controls.allSatisfy {
            Self.validKey($0.key) && $0.value.valid
        }
    }
    static func validKey(_ key: String) -> Bool {
        HandheldControl(rawValue: key) != nil || (key.hasPrefix("combo-") && UUID(uuidString: String(key.dropFirst(6))) != nil)
    }
    static func defaults(in safe: CGRect, system: GameSystem) -> [HandheldControl: CGRect] {
        let b = safe.insetBy(dx: 12, dy: 8)
        let landscape = safe.width > safe.height
        let pad = min(116, max(80, b.width * 0.31))
        let face = min(68, max(52, b.width * 0.17))
        let shoulderY = landscape ? b.minY + 48 : b.maxY - 256
        let frames: [HandheldControl: CGRect] = [
            .dpad: CGRect(x: b.minX, y: b.maxY - pad - 48, width: pad, height: pad),
            .a: CGRect(x: b.maxX - face, y: b.maxY - 196, width: face, height: face),
            .b: CGRect(x: b.maxX - face * 2 - 12, y: b.maxY - 128, width: face, height: face),
            .l: CGRect(x: b.minX, y: shoulderY, width: 76, height: 44),
            .r: CGRect(x: b.maxX - 76, y: shoulderY, width: 76, height: 44),
            .select: CGRect(x: b.midX - 60, y: b.maxY - 52, width: 52, height: 52),
            .start: CGRect(x: b.midX + 8, y: b.maxY - 52, width: 52, height: 52),
            .menu: CGRect(x: b.maxX - 44, y: b.minY, width: 44, height: 44),
            .edit: CGRect(x: b.maxX - 94, y: b.minY, width: 44, height: 44)]
        return Dictionary(uniqueKeysWithValues: HandheldControl.available(for: system).map { ($0, shaped($0.rawValue, frame: frames[$0]!, in: safe)) })
    }
    func frames(in bounds: CGRect, system: GameSystem, safeArea: CGRect? = nil) -> [HandheldControl: CGRect] {
        var frames = Self.defaults(in: safeArea ?? bounds, system: system)
        guard valid else { return frames }
        for control in HandheldControl.available(for: system) {
            if let value = placement(control.rawValue, in: bounds, safeArea: safeArea) { frames[control] = value }
        }
        return frames
    }
    func allFrames(in bounds: CGRect, system: GameSystem, combos: [HandheldCombo], safeArea: CGRect? = nil) -> [String: CGRect] {
        var result = Dictionary(uniqueKeysWithValues: frames(in: bounds, system: system, safeArea: safeArea).map { ($0.key.rawValue, $0.value) })
        let columns = max(1, min(combos.count, Int(bounds.width / 80)))
        let rows = max(1, (combos.count + columns - 1) / columns)
        for (index, combo) in combos.enumerated() {
            result[combo.key] = placement(combo.key, in: bounds, safeArea: safeArea) ?? Self.clamped(
                CGRect(x: bounds.midX - 32 + (Double(index % columns) - Double(columns - 1) / 2) * 72,
                       y: bounds.midY - 32 + (Double(index / columns) - Double(rows - 1) / 2) * 72, width: 64, height: 64), in: bounds)
        }
        return result
    }
    private func placement(_ key: String, in bounds: CGRect, safeArea: CGRect?) -> CGRect? {
        guard valid, let value = controls[key] else { return nil }
        let area = version == 1 ? safeArea ?? bounds : bounds
        let unit = min(area.width, area.height)
        let width = value.width * (version == 3 ? unit : area.width)
        let height = value.height * (version == 3 ? unit : area.height)
        return Self.shaped(key, frame: CGRect(x: area.minX + value.x * area.width - width / 2,
            y: area.minY + value.y * area.height - height / 2, width: width, height: height), in: bounds)
    }
    func migrated(in bounds: CGRect, safeArea: CGRect, system: GameSystem, combos: [HandheldCombo] = []) -> Self {
        guard version != 3 else { return self }
        var migrated = Self()
        for (key, frame) in allFrames(in: bounds, system: system, combos: combos, safeArea: safeArea) {
            migrated.set(key, frame: frame, in: bounds)
        }
        return migrated
    }
    mutating func set(_ control: HandheldControl, frame: CGRect, in bounds: CGRect) { set(control.rawValue, frame: frame, in: bounds) }
    mutating func set(_ key: String, frame: CGRect, in bounds: CGRect) {
        guard Self.validKey(key), bounds.width >= 44, bounds.height >= 44,
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) else { return }
        let rect = Self.shaped(key, frame: frame, in: bounds)
        let unit = min(bounds.width, bounds.height)
        controls[key] = HandheldPlacement(x: (rect.midX - bounds.minX) / bounds.width,
            y: (rect.midY - bounds.minY) / bounds.height, width: rect.width / unit, height: rect.height / unit)
    }
    static func shaped(_ key: String, frame: CGRect, in bounds: CGRect) -> CGRect {
        let ratio = key == "l" || key == "r" ? 76.0 / 44.0 : 1.0
        let width = min(min(bounds.width, bounds.height), max(44 * ratio, frame.width))
        let height = width / ratio
        return clamped(CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2,
                              width: width, height: height), in: bounds)
    }
    static func clamped(_ frame: CGRect, in safe: CGRect) -> CGRect {
        let width = min(safe.width, max(44, frame.width)), height = min(safe.height, max(44, frame.height))
        return CGRect(x: min(safe.maxX - width, max(safe.minX, frame.minX)),
            y: min(safe.maxY - height, max(safe.minY, frame.minY)), width: width, height: height)
    }
}

extension Notification.Name { static let handheldControlsChanged = Notification.Name("ClawHandheldControlsChanged") }
struct HandheldControlsConfiguration {
    let enabled: Bool
    let movement: HandheldMovement
    let combos: [HandheldCombo]
    let opacity: Double
    let portrait, landscape: HandheldControlLayout
    static func key(_ system: GameSystem, _ name: String) -> String { "handheldControls.\(system.rawValue).\(name)" }
    static func load(system: GameSystem, defaults: UserDefaults = .standard) -> Self {
        let opacity = defaults.object(forKey: key(system, "opacity")) as? Double ?? 0.45
        return Self(enabled: system.hasHandheldOverlay && (defaults.object(forKey: key(system, "enabled")) as? Bool ?? true),
            movement: HandheldMovement(rawValue: defaults.string(forKey: key(system, "movement")) ?? "") ?? .dpad,
            combos: combos(system: system, defaults: defaults),
            opacity: opacity.isFinite ? min(0.8, max(0.15, opacity)) : 0.45,
            portrait: layout(system: system, orientation: "portrait", defaults: defaults),
            landscape: layout(system: system, orientation: "landscape", defaults: defaults))
    }
    static func combos(system: GameSystem, defaults: UserDefaults = .standard) -> [HandheldCombo] {
        guard let data = defaults.data(forKey: key(system, "combos")), data.count < 16_384,
              let combos = try? JSONDecoder().decode([HandheldCombo].self, from: data), combos.count <= 16,
              Set(combos.map(\.id)).count == combos.count, combos.allSatisfy({ $0.valid(for: system) }) else { return [] }
        return combos
    }
    static func layout(system: GameSystem, orientation: String, defaults: UserDefaults = .standard) -> HandheldControlLayout {
        guard let data = defaults.data(forKey: key(system, orientation)), data.count < 16_384,
              let value = try? JSONDecoder().decode(HandheldControlLayout.self, from: data), value.valid else { return HandheldControlLayout() }
        return value
    }
    static func save(_ layout: HandheldControlLayout, system: GameSystem, orientation: String, opacity: Double,
                     combos: [HandheldCombo]? = nil, defaults: UserDefaults = .standard) throws {
        guard system.hasHandheldOverlay, ["portrait", "landscape"].contains(orientation), layout.valid, opacity.isFinite else {
            throw CocoaError(.coderInvalidValue)
        }
        if let combos {
            guard combos.count <= 16, Set(combos.map(\.id)).count == combos.count,
                  combos.allSatisfy({ $0.valid(for: system) }) else { throw CocoaError(.coderInvalidValue) }
            defaults.set(try JSONEncoder().encode(combos), forKey: key(system, "combos"))
        }
        let data = try JSONEncoder().encode(layout)
        defaults.set(data, forKey: key(system, orientation))
        defaults.set(min(0.8, max(0.15, opacity)), forKey: key(system, "opacity"))
        defaults.set(true, forKey: key(system, "enabled"))
        NotificationCenter.default.post(name: .handheldControlsChanged, object: nil)
    }
}
