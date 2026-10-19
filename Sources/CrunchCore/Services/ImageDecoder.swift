import CoreGraphics
import Foundation
import ImageIO

/// Decodes an image file to a `CGImage` — the one place in the package that
/// does it.
///
/// Four services were each running the same two-call `CGImageSource` dance
/// and throwing the same error, and the in-memory resize change would have
/// made it five. A single copy keeps the failure message consistent: it names
/// the user's file, which is the only part of a decode failure they can act
/// on.
enum ImageDecoder {
    /// Worth knowing before timing anything here: ImageIO decodes lazily, so
    /// the returned `CGImage` may not have touched a pixel yet and the real
    /// cost lands on whoever first draws or encodes it. A benchmark that
    /// times this call alone measures almost nothing.
    static func decode(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw CompressionError.cannotReadImage(url.lastPathComponent)
        }
        return image
    }
}
