import Foundation
import ImageIO

/// Encodes AVIF via native ImageIO — no subprocess, unlike PNG (pngquant)
/// and WebP (cwebp). Mirrors `JPEGCompressor`'s shape exactly; the only
/// difference is the destination UTI.
///
/// The UI only offers AVIF when `OutputFormat.avifEncodingSupported` is
/// true (see `ControlsView`), but a file's *resolved* format can still land
/// here unpicked — e.g. `.same` resolving an AVIF-format drop on a machine
/// that can decode but not encode AVIF. Guarding here, rather than only at
/// the picker, keeps that path a clear error instead of a raw ImageIO nil.
enum AVIFCompressor {
    /// `metadata` comes from the user's ORIGINAL file, never from `input` —
    /// see `JPEGCompressor.compress` for why.
    ///
    /// AVIF is the one format where orientation cannot ride along as a tag:
    /// ImageIO's AVIF encoder forces it to 1 regardless of what it is handed
    /// (measured 2026-10-19). The rotation is therefore applied to the pixels
    /// before encoding, and the tag rewritten to "upright" so nothing rotates
    /// it twice. Everything else — capture date, camera, GPS — does survive
    /// as ordinary metadata.
    static func compress(
        input: URL,
        output: URL,
        quality: Int,
        metadata: ImageMetadata?
    ) async throws {
        guard OutputFormat.avifEncodingSupported else {
            throw CompressionError.avifNotSupported
        }

        let qualityFloat = Double(quality) / 100.0

        guard let imageSource = CGImageSourceCreateWithURL(input as CFURL, nil),
              let decoded = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw CompressionError.cannotReadImage(input.lastPathComponent)
        }

        let orientation = metadata?.orientation ?? 1
        let cgImage = OrientationBaker.bake(decoded, orientation: orientation) ?? decoded
        let uprightMetadata = OrientationBaker.isUpright(orientation)
            ? metadata
            : metadata?.markedUpright()

        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL,
            OutputFormat.avifTypeIdentifier as CFString,
            1,
            nil
        ) else {
            throw CompressionError.cannotWriteImage(output.lastPathComponent)
        }

        let options = ImageMetadata.destinationOptions(
            metadata: uprightMetadata,
            quality: qualityFloat
        )

        CGImageDestinationAddImage(destination, cgImage, options)

        guard CGImageDestinationFinalize(destination) else {
            throw CompressionError.cannotWriteImage(output.lastPathComponent)
        }
    }
}
