// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum AppIconColor: String, CaseIterable, Identifiable, Sendable {
    case original, orange, blue, green, red
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var alternateName: String? { self == .original ? nil : "AppIcon" + title }
    var rgb: Int {
        switch self {
        case .original: return 0x111111
        case .blue: return 0x338FFA
        case .green: return 0x26AD61
        case .red: return 0xDB3D42
        case .orange: return 0xFF8538
        }
    }
    static let choices: [Self] = [.orange, .blue, .green, .red]
    // iOS accepts bundled alternate icons, not an image generated at runtime.
    // A color-wheel selection deterministically chooses the closest bundled mark.
    static func closest(to rgb: Int) -> Self {
        func distance(_ candidate: Self) -> Int {
            let r = ((rgb >> 16) & 255) - ((candidate.rgb >> 16) & 255)
            let g = ((rgb >> 8) & 255) - ((candidate.rgb >> 8) & 255)
            let b = (rgb & 255) - (candidate.rgb & 255)
            return r * r + g * g + b * b
        }
        return choices.min { distance($0) < distance($1) } ?? .orange
    }
    static func resolve(accent: String, customRGB: Int, matchAccent: Bool,
                        manualRGB: Int, original: Bool) -> Self {
        guard matchAccent else { return original ? .original : closest(to: manualRGB) }
        if accent == "custom" { return closest(to: customRGB) }
        if accent == "gold" { return closest(to: 0xEB991A) }
        return Self(rawValue: accent).flatMap { $0 == .original ? nil : $0 } ?? .orange
    }
}
