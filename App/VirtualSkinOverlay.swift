// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

// SwiftUI constructs the artwork only while taking this snapshot. Gameplay
// retains just a UIImageView, so Canvas/drawing groups have no live view graph
// or offscreen control layers competing with the emulator during playback.
@MainActor enum SkinArtworkSnapshot {
    static func image(skin: ControllerSkin?, layout: ControllerSkinLayout?, opacity: Double,
                      system: GameSystem, imported: ImportedSkinSession?, size: CGSize,
                      displayScale: CGFloat) -> UIImage? {
        guard let layout, let scale = SkinRasterBudget.scale(for: size, displayScale: displayScale) else { return nil }
        let artwork = VirtualSkinOverlay(skin: skin, layout: layout, opacity: opacity,
                                         system: system, imported: imported)
            .frame(width: size.width, height: size.height)
            .environment(\.displayScale, scale)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: artwork)
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.uiImage
    }
}

// Original scalable artwork. Nothing is drawn over a game window; all touch
// handling belongs to the UIKit controls using the exact same layout geometry.
struct VirtualSkinOverlay: View {
    let skin: ControllerSkin?
    let layout: ControllerSkinLayout?
    let opacity: Double
    var system: GameSystem = .threeDS
    var imported: ImportedSkinSession? = nil
    var body: some View {
        ZStack(alignment: .topLeading) {
            if let imported, let layout {
                if let background = imported.images[imported.variant.background] {
                    Image(uiImage: background).resizable()
                        .frame(width: layout.canvas.width, height: layout.canvas.height)
                        .position(x: layout.canvas.midX, y: layout.canvas.midY)
                }
                // Enumerate rather than keying by input: a valid skin may draw
                // the same input in more than one visual region. The layout
                // preserves one converted frame per control, in author order.
                ForEach(Array(imported.variant.controls.enumerated()), id: \.offset) { index, control in
                    if control.key != "circle", let asset = control.asset,
                       let image = imported.images[asset],
                       layout.importedFrames.indices.contains(index) {
                        let frame = layout.importedFrames[index]
                        Image(uiImage: image).resizable().frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
            } else if let skin, let layout {
                shell(layout)
                ForEach(Array([layout.gameplay.top, layout.gameplay.bottom].filter { !$0.isEmpty }.enumerated()), id: \.offset) { _, frame in
                    RoundedRectangle(cornerRadius: 8).stroke(
                        LinearGradient(colors: [.black, .white.opacity(0.18), .black],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 3)
                        .frame(width: frame.width + 6, height: frame.height + 6)
                        .position(x: frame.midX, y: frame.midY)
                }
                ForEach(skin.controls.filter { system.showsControl($0.key) }, id: \.key) { control in
                    if let frame = layout.artFrames[control.key] {
                        ObsidianControlArtwork(key: control.key)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea().opacity(opacity).allowsHitTesting(false).accessibilityHidden(true)
    }
    private func shell(_ layout: ControllerSkinLayout) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30)
                .fill(LinearGradient(colors: [Color(white: 0.12), Color(white: 0.025), Color(white: 0.08)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 30).stroke(
                    LinearGradient(colors: [.white.opacity(0.38), .black, .white.opacity(0.14)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 3))
                .overlay(RoundedRectangle(cornerRadius: 26).inset(by: 6).stroke(.black.opacity(0.8), lineWidth: 3))
                .overlay {
                    Canvas { context, size in
                        // Deterministic static grain. This view changes only on
                        // layout/skin updates, independently of emulated frames.
                        var grain = Path()
                        for row in stride(from: 0, to: Int(size.height), by: 8) {
                            for column in stride(from: 0, to: Int(size.width), by: 8) {
                                let offset = (row * 31 + column * 17) % 7
                                grain.addEllipse(in: CGRect(x: CGFloat(column + offset), y: CGFloat(row), width: 0.6, height: 0.6))
                            }
                        }
                        context.fill(grain, with: .color(.white.opacity(0.035)))
                    }.clipShape(RoundedRectangle(cornerRadius: 30))
                }
            HStack {
                ClawScratches().stroke(.white.opacity(0.12), lineWidth: 1).frame(width: 22, height: 90)
                Spacer()
                ClawScratches().stroke(.white.opacity(0.12), lineWidth: 1).frame(width: 22, height: 90)
            }.padding(.horizontal, 10)
        }.frame(width: layout.canvas.width, height: layout.canvas.height)
            .position(x: layout.canvas.midX, y: layout.canvas.midY)
    }
}
private struct ObsidianDPad: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [(CGFloat, CGFloat)] = [(0.35,0.03),(0.65,0.03),(0.65,0.35),(0.97,0.35),
            (0.97,0.65),(0.65,0.65),(0.65,0.97),(0.35,0.97),(0.35,0.65),(0.03,0.65),(0.03,0.35),(0.35,0.35)]
        var path = Path()
        path.addLines(points.map { CGPoint(x: rect.minX + $0.0 * rect.width, y: rect.minY + $0.1 * rect.height) })
        path.closeSubpath(); return path
    }
}
private struct ObsidianControlArtwork: View {
    let key: String
    private var fill: LinearGradient {
        LinearGradient(colors: [Color(white: 0.17), Color(white: 0.035)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            ZStack {
                if key == "dpad" {
                    ObsidianDPad().fill(fill).padding(5)
                    ObsidianDPad().stroke(Color(white: 0.76), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round)).padding(5)
                    ForEach(0..<4, id: \.self) { index in
                        Capsule().fill(Color(white: 0.8)).frame(width: 2, height: h * 0.10)
                            .offset(y: -h * 0.28).rotationEffect(.degrees(Double(index) * 90))
                    }
                } else if key == "circle" {
                    Circle().fill(fill).overlay(Circle().stroke(.black, lineWidth: 3))
                    Circle().stroke(LinearGradient(colors: [.white.opacity(0.85), .gray, .white.opacity(0.7)],
                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 3).padding(w * 0.09)
                    Circle().fill(.black.opacity(0.8)).padding(w * 0.15)
                } else if ["l", "r"].contains(key) {
                    Capsule().fill(fill).overlay(Capsule().stroke(.gray.opacity(0.55), lineWidth: 1))
                    Text(key.uppercased()).font(.system(size: min(h * 0.55, 22), weight: .medium)).foregroundStyle(.white.opacity(0.85))
                } else if ["start", "select"].contains(key) {
                    Circle().fill(fill).overlay(Circle().stroke(.gray.opacity(0.7), lineWidth: 1))
                    Text(key.uppercased()).font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9)).lineLimit(1).minimumScaleFactor(0.8)
                } else {
                    Circle().fill(fill).overlay(Circle().stroke(.gray.opacity(0.7), lineWidth: 1))
                    Text(key.uppercased()).font(.system(size: h * 0.50, weight: .light)).foregroundStyle(.white.opacity(0.85))
                }
            // GeometryReader aligns an intrinsically sized ZStack at its top
            // edge. Center the fixed-size Start/Select art in its full hit frame
            // so the circle's negative offset cannot be clipped above the view.
            }.frame(width: w, height: h)
        }
    }
}

private struct ClawScratches: Shape {
    func path(in rect: CGRect) -> Path {
        var result = Path()
        for offset in [CGFloat(0), 0.20, 0.40] {
            result.move(to: CGPoint(x: rect.minX, y: rect.maxY - offset * rect.height))
            result.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + offset * rect.height),
                                control: CGPoint(x: rect.midX, y: rect.midY))
        }
        return result
    }
}
