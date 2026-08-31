import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Bridges formats the external compressors can't decode into ones they can.
///
/// `pngquant` reads PNG only and `cwebp` reads a short list of formats;
/// neither knows anything about AVIF, which ImageIO on macOS 15 decodes
/// natively. Re-encoding to a lossless PNG first costs one extra temp file
/// and keeps every source format usable with every output format.
enum ImageNormalizer {
    /// Input extensions `cwebp` decodes on its own. Anything else has to be
    /// normalized to PNG first (AVIF is the case that matters today).
    static let cwebpDecodableExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "webp"]

    /// Decodes any image `ImageIO` understands and re-encodes it as a
    /// lossless PNG to a unique file in the system temp directory. Lossless
    /// because this is an intermediate — the real compressor applies the
    /// user's quality setting downstream, and a lossy hop here would stack a
    /// second, uncontrolled generation of loss on top of it.
    ///
    /// The caller owns the returned file and must delete it.
    static func encodeAsPNG(from source: URL) throws -> URL {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw CompressionError.cannotReadImage(source.lastPathComponent)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")

        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CompressionError.cannotWriteImage(tempURL.lastPathComponent)
        }

        CGImageDestinationAddImage(destination, cgImage, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw CompressionError.cannotWriteImage(tempURL.lastPathComponent)
        }

        return tempURL
    }
}
