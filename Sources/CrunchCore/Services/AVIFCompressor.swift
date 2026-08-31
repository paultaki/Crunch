import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes AVIF via native ImageIO — no subprocess, unlike PNG (pngquant)
/// and WebP (cwebp). Mirrors `JPEGCompressor`'s shape exactly; the only
/// difference is the destination UTI.
///
/// Callers must check `OutputFormat.avifEncodingSupported` before routing
/// here — `CGImageDestinationCreateWithURL` fails outright on a system
/// whose ImageIO can't encode AVIF, and this type has no fallback for that.
enum AVIFCompressor {
    static func compress(input: URL, output: URL, quality: Int) async throws {
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
