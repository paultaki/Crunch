import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum JPEGCompressor {
    /// Takes already-decoded pixels rather than a file, because under a
    /// resize they come straight from `ImageResizer` and never touch the
    /// disk. `CompressionPipeline` decodes the original when there is no
    /// resize, so this does no reading at all.
    ///
    /// `metadata` comes from the user's ORIGINAL file. That used to be a rule
    /// a reader had to take on trust — the obvious-looking shortcut was to
    /// source it from `input`, which under a resize was a bare intermediate
    /// carrying none of it, so metadata survived at 100% resolution and
    /// vanished at 99%. Now there is no input file here to be tempted by,
    /// which is a better guarantee than a comment.
    ///
    /// Nil means the user asked for metadata to be stripped, which here is
    /// simply the absence of anything to merge: an ImageIO destination writes
    /// only what it is given.
    static func compress(
        image: CGImage,
        output: URL,
        quality: Int,
        metadata: ImageMetadata?
    ) async throws {
        let qualityFloat = Double(quality) / 100.0

        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CompressionError.cannotWriteImage(output.lastPathComponent)
        }

        let options = ImageMetadata.destinationOptions(
            metadata: metadata,
            quality: qualityFloat
        )

        CGImageDestinationAddImage(destination, image, options)

        guard CGImageDestinationFinalize(destination) else {
            throw CompressionError.cannotWriteImage(output.lastPathComponent)
        }
    }
}

enum CompressionError: LocalizedError {
    case cannotReadImage(String)
    case cannotCreateContext(String)
    case cannotWriteImage(String)
    /// Nothing on the destination's *volume* can hold a temporary file —
    /// neither a private replacement directory nor the destination's own
    /// folder. See `StagingArea` for the ladder that has to fail all the way
    /// down before this is thrown.
    ///
    /// Volume-scoped, not folder-scoped: a read-only folder on a writable
    /// volume does NOT reach here, because the replacement directory is
    /// created against the volume and succeeds. That case fails one step
    /// later, at delivery, with a permissions error from `replaceItemAt`.
    ///
    /// Carries the destination folder's name because that is the part of the
    /// path the user recognizes, even though the cause is usually the volume
    /// (read-only mount, out of space).
    case cannotStageOutput(String)
    case toolMissing(String)
    case avifNotSupported

    var errorDescription: String? {
        switch self {
        case .cannotReadImage(let name): "Cannot read image: \(name)"
        case .cannotCreateContext(let name): "Cannot create drawing context for: \(name)"
        case .cannotWriteImage(let name): "Cannot write image: \(name)"
        case .cannotStageOutput(let folder):
            "Cannot write a temporary file in the folder “\(folder)” — check its permissions."
        case .toolMissing(let name): "Required tool not found: \(name)"
        case .avifNotSupported: MissingToolsMessage.avifUnsupported
        }
    }
}
