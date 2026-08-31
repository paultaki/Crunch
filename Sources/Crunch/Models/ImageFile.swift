import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// A single image queued for compression.
///
/// Loading happens once when the user drops a file; from then on the struct
/// is a pure value carrying metadata and a cached thumbnail. The thumbnail is
/// stored as a `CGImage` (thread-safe immutable) so `ImageFile` is `Sendable`
/// and can be constructed on a background task before hand-off to the main
/// actor.
struct ImageFile: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let originalSize: Int64
    let format: ImageFormat
    let thumbnail: CGImage
    let pixelWidth: Int
    let pixelHeight: Int

    var filename: String { url.lastPathComponent }

    func resizedDimensions(percent: Int) -> (width: Int, height: Int) {
        let scale = Double(percent) / 100.0
        return (
            width: Int(Double(pixelWidth) * scale),
            height: Int(Double(pixelHeight) * scale)
        )
    }

    /// Loads an image from disk using `ImageIO` so we never fully decode the
    /// source — we only ask for a thumbnail of a fixed max pixel size.
    /// Callable from any thread.
    static func load(from url: URL) -> ImageFile? {
        guard let format = ImageFormat.from(extension: url.pathExtension) else {
            return nil
        }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .flatMap { Int64($0) } ?? 0

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 128
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary
        ) else {
            return nil
        }

        return ImageFile(
            url: url,
            originalSize: fileSize,
            format: format,
            thumbnail: thumbnail,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }
}
