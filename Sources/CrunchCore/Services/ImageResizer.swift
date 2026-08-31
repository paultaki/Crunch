import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageResizer {
    /// Resizes `input` to `width`×`height` and writes the result to a temp
    /// PNG file, returning its URL.
    ///
    /// `outputFormat` is the compressor's TARGET format, never the source
    /// file's extension — the caller must never pass `.webp` here, since
    /// WebP resizing is delegated to `cwebp -resize` instead (ImageIO can
    /// decode WebP but cannot encode it). The resize temp itself is always
    /// written as lossless PNG regardless of `outputFormat`: it's an
    /// intermediate feeding into `PNGCompressor`/`JPEGCompressor`, which
    /// already apply the caller's requested quality, so a lossless
    /// intermediate avoids a second, uncontrolled lossy generation.
    public static func resize(
        input: URL,
        width: Int,
        height: Int,
        outputFormat: ImageFormat
    ) async throws -> URL {
        assert(outputFormat != .webp, "WebP resize must go through cwebp -resize, not ImageResizer")

        guard let imageSource = CGImageSourceCreateWithURL(input as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw CompressionError.cannotReadImage(input.lastPathComponent)
        }

        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()

        // Always draw into a premultiplied (or alpha-free) 8-bit RGBA
        // context regardless of the source's alpha layout. `CGContext`
        // rejects several straight-alpha combinations outright, and even
        // when it doesn't, reinterpreting straight alpha as premultiplied
        // corrupts color at partially-transparent edges. Normalizing here
        // means the resized pixels are always well-formed.
        let hasAlpha = cgImage.alphaInfo != .none
            && cgImage.alphaInfo != .noneSkipFirst
            && cgImage.alphaInfo != .noneSkipLast
        let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: alphaInfo.rawValue
        ) else {
            throw CompressionError.cannotCreateContext(input.lastPathComponent)
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let resizedImage = context.makeImage() else {
            throw CompressionError.cannotReadImage(input.lastPathComponent)
        }

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")

        guard let destination = CGImageDestinationCreateWithURL(
            tempFile as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CompressionError.cannotWriteImage("temp resize file")
        }

        CGImageDestinationAddImage(destination, resizedImage, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw CompressionError.cannotWriteImage("temp resize file")
        }

        return tempFile
    }
}
