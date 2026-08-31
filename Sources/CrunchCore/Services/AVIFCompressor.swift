import AppKit
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
    static func compress(input: URL, output: URL, quality: Int) async throws {
        guard OutputFormat.avifEncodingSupported else {
            throw CompressionError.avifNotSupported
        }

        let qualityFloat = Double(quality) / 100.0

        guard let imageSource = CGImageSourceCreateWithURL(input as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw CompressionError.cannotReadImage(input.lastPathComponent)
        }

        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL,
            OutputFormat.avifTypeIdentifier as CFString,
            1,
            nil
        ) else {
            throw CompressionError.cannotWriteImage(output.lastPathComponent)
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: qualityFloat
        ]

        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw CompressionError.cannotWriteImage(output.lastPathComponent)
        }
    }
}
