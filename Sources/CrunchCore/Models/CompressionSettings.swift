import Foundation

public struct CompressionSettings: Equatable, Sendable {
    public var outputFormat: OutputFormat = .same
    public var resolutionPercent: Int = 100
    public var quality: Int = 80

    /// Discard EXIF, TIFF, GPS and IPTC metadata instead of carrying it into
    /// the compressed file.
    ///
    /// Defaults to false — preserving — because losing a photo's capture
    /// date, camera and orientation is data loss, and doing it silently was a
    /// bug. Removing GPS before publishing a photo is a real and reasonable
    /// thing to want, though, so it stays available as a deliberate choice.
    public var stripMetadata: Bool = false

    public init(
        outputFormat: OutputFormat = .same,
        resolutionPercent: Int = 100,
        quality: Int = 80,
        stripMetadata: Bool = false
    ) {
        self.outputFormat = outputFormat
        self.resolutionPercent = resolutionPercent
        self.quality = quality
        self.stripMetadata = stripMetadata
    }
}
