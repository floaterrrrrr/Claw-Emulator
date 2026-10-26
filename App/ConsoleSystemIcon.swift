// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

// Original, resolution-independent silhouettes based on each console's
// hardware layout. No font glyph substitutes or downloaded brand logos.
struct ConsoleSystemIcon: View {
    let system: GameSystem
    var body: some View {
        ConsoleSystemGlyph(system: system)
            .stroke(style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
            .aspectRatio(1.25, contentMode: .fit).accessibilityHidden(true)
    }
}

private struct ConsoleSystemGlyph: Shape {
    let system: GameSystem
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat = 1) {
            p.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: radius, height: radius))
        }
        func line(_ x: CGFloat, _ y: CGFloat, _ a: CGFloat, _ b: CGFloat) {
            p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: a, y: b))
        }
        func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat = 0.8) {
            p.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        func dpad(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat = 2.3) {
            line(x - r, y, x + r, y); line(x, y - r, x, y + r)
        }
        switch system {
        case .threeDS:
            box(7, 1, 26, 12, 2); box(10, 3, 20, 8)
            line(6, 15, 34, 15); box(5, 16, 30, 15, 3); box(14, 18, 12, 9)
            dot(9.5, 20, 1.1); dpad(9.5, 25, 1.8)
            dot(30, 20.5); dot(32.5, 23); dot(30, 25.5); dot(27.5, 23)
            line(15, 29, 18, 29); line(22, 29, 25, 29)
        case .ds:
            box(6, 1, 28, 13, 2); box(12, 3, 16, 9)
            line(8, 6, 9, 6); line(8, 9, 9, 9); line(31, 6, 32, 6); line(31, 9, 32, 9)
            line(6, 15.5, 34, 15.5); box(6, 17, 28, 14, 2); box(12, 19, 16, 9)
            dpad(9, 23, 1.8); dot(30.5, 20.5, 0.65); dot(32.5, 22.5, 0.65)
            dot(30.5, 24.5, 0.65); dot(28.5, 22.5, 0.65)
        case .gba:
            box(1, 5, 38, 23, 7); box(10.5, 8, 19, 16, 2)
            line(4, 4, 11, 4); line(29, 4, 36, 4)
            dpad(6, 16, 3); dot(33, 17, 1.4); dot(36, 13, 1.4)
            line(31, 22, 34, 22); line(30, 25, 33, 25)
        case .gb:
            box(9, 1, 22, 30, 3); box(12, 5, 16, 12, 2); box(15, 7, 10, 8)
            dpad(15, 23, 2.8); dot(24, 22, 1.4); dot(28, 20, 1.4)
            line(18, 29, 20, 28); line(23, 29, 25, 28)
        case .gbc:
            p.move(to: CGPoint(x: 10, y: 5))
            p.addQuadCurve(to: CGPoint(x: 30, y: 5), control: CGPoint(x: 20, y: -2))
            p.addLine(to: CGPoint(x: 29, y: 27))
            p.addQuadCurve(to: CGPoint(x: 11, y: 27), control: CGPoint(x: 20, y: 35))
            p.closeSubpath()
            box(13, 5, 14, 13, 2); box(15, 7, 10, 8)
            dpad(15, 23, 2.6); dot(24, 23, 1.3); dot(27.5, 20.5, 1.3)
            line(18, 28, 20, 28); line(23, 28, 25, 28)
        case .nes:
            box(2, 9, 36, 20, 2); box(5, 3, 30, 6)
            box(6, 12, 21, 7); line(7, 15, 26, 15)
            line(31, 11, 31, 19); line(34, 11, 34, 19)
            box(6, 23, 3, 2, 0.3); box(12, 23, 3, 2, 0.3)
            line(3, 21, 37, 21)
        }
        return p.applying(CGAffineTransform(scaleX: rect.width / 40, y: rect.height / 32)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}
