import Foundation
import ImageIO

/// The metadata lifted off a user's **original** file, ready to be written
/// back onto whatever the compressors produce.
///
/// The "original" part is the whole point. Before this type existed, every
/// compressor decoded its input to a bare `CGImage` and wrote it out with
/// nothing but a quality key, so orientation, capture date, camera and GPS
/// were discarded on every run — a phone photo stored as landscape pixels
/// plus an EXIF "rotate 90°" tag came out of Crunch visibly rotated.
///
/// Threading it from the original rather than from the compressor's input is
/// not pedantry: under 100% resolution `CompressionPipeline` routes through
/// `ImageResizer`, whose intermediate PNG carries none of the user's
/// metadata. A fix that read from the compressor's input would work at 100%
/// and silently lose everything the moment the resolution slider moved.
public struct ImageMetadata: @unchecked Sendable {
    /// Immutable after `init`, and only ever read. `Any` defeats the
    /// compiler's `Sendable` checking, hence `@unchecked`; nothing here is
    /// mutated or shared for writing.
    let properties: [CFString: Any]

    /// The property dictionaries worth carrying from one encoding to the
    /// next, in the order ImageIO names them.
    ///
    /// Deliberately a allowlist rather than "copy everything". The full
    /// dictionary also carries `PixelWidth`, `Depth`, `ColorModel`,
    /// `ProfileName` and format-private blocks like `{JFIF}` or `{PNG}` —
    /// facts about the *source encoding*, which are wrong or meaningless once
    /// re-encoded, possibly at a different size and into a different format.
    /// ImageIO derives all of those from the `CGImage` it is handed anyway.
    ///
    /// Computed rather than stored because `CFString` is not `Sendable`, and
    /// a stored static would be shared mutable state under Swift 6. Six
    /// constants per call is not worth a workaround.
    private static var preservedKeys: [CFString] {[
        kCGImagePropertyExifDictionary,
        kCGImagePropertyExifAuxDictionary,
        kCGImagePropertyTIFFDictionary,
        kCGImagePropertyGPSDictionary,
        kCGImagePropertyIPTCDictionary,
        kCGImagePropertyOrientation
    ]}

    private init(properties: [CFString: Any]) {
        self.properties = properties
    }

    /// Reads the preserved metadata from `url`, or `nil` when the file
    /// carries none (or cannot be read at all — a missing source is the
    /// compressor's problem to report, not this type's).
    public static func read(from url: URL) -> ImageMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let all = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        var kept: [CFString: Any] = [:]
        for key in preservedKeys where all[key] != nil {
            kept[key] = all[key]
        }
        return kept.isEmpty ? nil : ImageMetadata(properties: kept)
    }

    /// The EXIF orientation, or 1 ("already upright") when the file does not
    /// say. Read from the top-level key first and the TIFF dictionary second,
    /// because ImageIO populates whichever the container happens to use.
    public var orientation: Int {
        if let top = properties[kCGImagePropertyOrientation] as? Int { return top }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let value = tiff[kCGImagePropertyTIFFOrientation] as? Int {
            return value
        }
        return 1
    }

    /// The same metadata with every orientation tag forced to 1.
    ///
    /// For destinations where the rotation has been applied to the pixels
    /// instead (see `OrientationBaker` and `AVIFCompressor`). Leaving the tag
    /// behind would tell a reader to rotate an image that is already upright.
    public func markedUpright() -> ImageMetadata {
        var updated = properties
        updated[kCGImagePropertyOrientation] = 1
        if var tiff = updated[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            updated[kCGImagePropertyTIFFDictionary] = tiff
        }
        return ImageMetadata(properties: updated)
    }


    /// The options dictionary for `CGImageDestinationAddImage`: this
    /// metadata, plus the caller's quality.
    ///
    /// Quality is applied *after* the merge so it always wins. The allowlist
    /// above can never contain the quality key today, but writing it in this
    /// order means that stays true if the allowlist grows.
    ///
    /// Note that ImageIO overwrites the EXIF pixel-dimension tags with the
    /// dimensions of the `CGImage` it is actually writing, so passing an
    /// original's metadata alongside a resized image does *not* leave stale
    /// dimensions behind (measured 2026-10-19).
    static func destinationOptions(
        metadata: ImageMetadata?,
        quality: Double
    ) -> CFDictionary {
        var options = metadata?.properties ?? [:]
        options[kCGImageDestinationLossyCompressionQuality] = quality
        return options as CFDictionary
    }
}
