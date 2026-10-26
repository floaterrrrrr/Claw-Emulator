// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(ImageIO) && canImport(CoreGraphics)
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
#endif

enum SkinImageCodec {
    static func normalize(_ data: Data, extension ext: String) throws -> (data: Data, decodedBytes: Int) {
#if canImport(ImageIO) && canImport(CoreGraphics)
        // Drain decoder/encoder temporaries between assets, not at task exit.
        return try autoreleasepool { try normalizeImage(data, extension: ext) }
#else
        // Portable tests exercise archives/metadata, never Apple rasterization.
        guard ext.lowercased() == "png", data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw SkinImportError("Image preparation requires the Apple build.")
        }
        return (data, data.count)
#endif
    }

    static func acceptsSource(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= 8192 && height <= 8192 &&
            width <= (4 * 1024 * 1024) / height
    }

#if canImport(ImageIO) && canImport(CoreGraphics)
    private static func normalizeImage(_ data: Data, extension ext: String) throws -> (data: Data, decodedBytes: Int) {
        let image: CGImage
        if ext.lowercased() == "pdf" {
            guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
                  document.numberOfPages == 1, let page = document.page(at: 1) else {
                throw SkinImportError("A skin PDF could not be opened.")
            }
            let box = page.getBoxRect(.mediaBox)
            guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0,
                  box.width <= 8192, box.height <= 8192 else { throw SkinImportError("A skin image has invalid dimensions.") }
            let scale = min(2, 2048 / max(box.width, box.height))
            let width = max(1, Int((box.width * scale).rounded())), height = max(1, Int((box.height * scale).rounded()))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SkinImportError("The skin image could not be prepared.") }
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
            guard let rendered = context.makeImage() else { throw SkinImportError("The skin PDF could not be rendered.") }
            image = rendered
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  acceptsSource(width: width, height: height),
                  let rendered = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw SkinImportError("A skin image is invalid or too large.") }
            image = rendered
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw SkinImportError("The skin image could not be saved.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SkinImportError("The skin image could not be saved.") }
        return (output as Data, image.width * image.height * 4)
    }
#endif
}
