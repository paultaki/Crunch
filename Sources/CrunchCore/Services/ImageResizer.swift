import CoreGraphics
import Foundation

public enum ImageResizer {
    /// Resizes `input` to `width`×`height` and returns the pixels, without
    /// touching the disk.
    ///
    /// This used to encode the result to a lossless PNG in the system temp
    /// directory and return that URL, which the next compressor immediately
    /// re-decoded. The *lossless* half of that reasoning was right and still
    /// holds — an intermediate must not stack a second, uncontrolled
    /// generation of loss underneath the quality the user actually asked for.
    /// What it missed is that a `CGImage` handed straight to the encoder is
    /// lossless in the strongest available sense: there is no intermediate
    /// encoding at all. Measured on a 4032x3024 photo at 50%, writing that
    /// intermediate and reading it back cost 247 ms per file and 6.2 MB of
    /// throwaway writes, against 68 ms of real decode-draw-encode work.
    ///
    /// Deleting it also closed a staging bug rather than fixing one. The temp
    /// went to `FileManager.default.temporaryDirectory` on the boot volume
    /// even when the user's photos lived on an external drive — the last
    /// staging path that ignored the volume rule `StagingArea` exists to
    /// enforce. Pixels in memory have no volume.
    ///
    /// WebP never arrives here: `cwebp -resize` does its own resizing and
    /// ImageIO cannot encode WebP at all. `CompressionPipeline` is what keeps
    /// that true — see `needsManualResize` there, which is now the only
    /// guard, since there is no longer an output format to assert against.
    ///
    /// pngquant is the one consumer that cannot take pixels, so the PNG path
    /// writes these out to a file itself; `CompressionPipeline` says why.
    public static func resize(input: URL, width: Int, height: Int) throws -> CGImage {
        let cgImage = try ImageDecoder.decode(input)

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

        return resizedImage
    }
}
