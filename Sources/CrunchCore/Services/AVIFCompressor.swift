import CoreGraphics
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
    /// Takes already-decoded pixels for the same reason `JPEGCompressor`
    /// does, and `metadata` likewise comes from the user's ORIGINAL file.
    ///
    /// AVIF is the one format where orientation cannot ride along as a tag:
    /// ImageIO's AVIF encoder forces it to 1 regardless of what it is handed
    /// (measured 2026-10-19). The rotation is therefore applied to the pixels
    /// before encoding, and the tag rewritten to "upright" so nothing rotates
    /// it twice. Everything else — capture date, camera, GPS — does survive
    /// as ordinary metadata.
    static func compress(
        image: CGImage,
        output: URL,
        quality: Int,
        metadata: ImageMetadata?
    ) async throws {
        guard OutputFormat.avifEncodingSupported else {
            throw CompressionError.avifNotSupported
        }

        let qualityFloat = Double(quality) / 100.0

        // Under a resize this is a second redraw of the same pixels, the
        // first being the resize itself, and folding the orientation
        // transform into that one draw was considered and rejected. Measured
        // on a 4032x3024 photo at 50%: AVIF costs 119 ms with an upright
        // source and 129 ms with an orientation-6 one, so the extra draw is
        // ~10 ms of ~129 ms. Buying that back means teaching `ImageResizer`
        // about orientation and then telling this function its pixels arrived
        // pre-baked — orientation logic spread across three files, and a
        // resize that silently does two different things. Not worth 8%.
        //
        // Without a resize the bake is unavoidable and much dearer (a full
        // 12MP redraw, 174 ms -> ~290 ms), since there is no other draw to
        // fold it into.
        let orientation = metadata?.orientation ?? 1
        let cgImage = OrientationBaker.bake(image, orientation: orientation) ?? image
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
