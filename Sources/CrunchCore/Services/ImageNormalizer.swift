import CoreGraphics
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
    /// `metadata` is embedded into the substitute when the caller needs the
    /// original's metadata to survive the hop. Only `WebPCompressor` does:
    /// cwebp can copy metadata only out of the file it is handed, so a bare
    /// substitute would leave `-metadata all` with nothing to copy.
    /// `PNGCompressor` passes nil because pngquant discards metadata
    /// regardless and gets it written back afterwards instead.
    ///
    /// The caller owns the returned file and must delete it.
    static func encodeAsPNG(from source: URL, metadata: ImageMetadata?) throws -> URL {
        try encodeAsPNG(from: ImageDecoder.decode(source), metadata: metadata)
    }

    /// Writes already-decoded pixels out as a lossless PNG temp.
    ///
    /// This is the resize path's one remaining exit to disk. `ImageResizer`
    /// hands back a `CGImage` precisely so nothing has to go through a file,
    /// but pngquant decodes PNG files through libpng and cannot be given
    /// pixels, so the PNG output format alone still needs the intermediate
    /// written. Lossless, so the only generation of loss is the quantization
    /// the user asked for.
    ///
    /// The caller owns the returned file and must delete it.
    static func encodeAsPNG(from image: CGImage, metadata: ImageMetadata?) throws -> URL {
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

        CGImageDestinationAddImage(destination, image, metadata?.properties as CFDictionary?)

        guard CGImageDestinationFinalize(destination) else {
            throw CompressionError.cannotWriteImage(tempURL.lastPathComponent)
        }

        return tempURL
    }
}
