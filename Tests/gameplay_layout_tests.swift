// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@main struct LayoutTests {
    static func main() {
        // Physical safe rectangles: small iPhone, iPhone 17, Max; both rotations.
        let sizes = [CGSize(width: 375, height: 647), CGSize(width: 402, height: 778),
                     CGSize(width: 440, height: 860), CGSize(width: 667, height: 354),
                     CGSize(width: 750, height: 381), CGSize(width: 832, height: 419)]
        for size in sizes {
            for larger in [false, true] {
                let safe = CGRect(origin: CGPoint(x: 62, y: 24), size: size)
                let layout = GameplayLayout.make(in: safe, largerTouchScreen: larger)
                let frames = [layout.top, layout.bottom, layout.circle, layout.dpad, layout.face,
                              layout.leftShoulder, layout.rightShoulder, layout.select, layout.start, layout.gear]
                for frame in frames {
                    precondition(frame.width >= 44 && frame.height >= 44, "Small touch target: \(size), \(frame)")
                    precondition(safe.contains(frame), "Unsafe frame: \(size), \(frame)")
                }
                for i in frames.indices {
                    for j in frames.indices where j > i {
                        let intersection = frames[i].intersection(frames[j])
                        precondition(intersection.isNull || intersection.width < 0.01 || intersection.height < 0.01,
                                     "Overlapping controls/screens: \(size), \(i), \(j)")
                    }
                }
                precondition(abs(layout.top.width / layout.top.height - 5.0 / 3.0) < 0.001)
                precondition(abs(layout.bottom.width / layout.bottom.height - 4.0 / 3.0) < 0.001)
                if layout.landscape {
                    precondition(layout.top.maxX <= layout.bottom.minX)
                    precondition(layout.face.maxY <= layout.bottom.minY)
                    precondition(layout.dpad.maxY <= layout.circle.minY)
                    precondition(layout.circle.maxX <= layout.top.minX)
                    precondition(layout.top.width * layout.top.height > layout.bottom.width * layout.bottom.height * 3)
                } else {
                    precondition(layout.top.maxY <= layout.bottom.minY)
                }
            }
        }
        let directions: [(CGPoint, DPadAxes)] = [
            (CGPoint(x: 50, y: 50), DPadAxes(horizontal: 0, vertical: 0)),
            (CGPoint(x: 0, y: 50), DPadAxes(horizontal: -1, vertical: 0)),
            (CGPoint(x: 100, y: 50), DPadAxes(horizontal: 1, vertical: 0)),
            (CGPoint(x: 50, y: 0), DPadAxes(horizontal: 0, vertical: 1)),
            (CGPoint(x: 50, y: 100), DPadAxes(horizontal: 0, vertical: -1)),
            (CGPoint(x: 0, y: 0), DPadAxes(horizontal: -1, vertical: 1)),
            (CGPoint(x: 100, y: 100), DPadAxes(horizontal: 1, vertical: -1))]
        for (point, expected) in directions { precondition(DPadAxes.at(point, size: CGSize(width: 100, height: 100)) == expected) }
        precondition(DPadAxes.at(CGPoint(x: Double.nan, y: 0), size: .zero) == DPadAxes(horizontal: 0, vertical: 0))
        print("PASS: six phone safe areas, two touch-screen sizes, no overlap, 44pt targets, aspect ratios, dominant side-by-side main display, outer controls, diagonal/neutral input")
    }
}
