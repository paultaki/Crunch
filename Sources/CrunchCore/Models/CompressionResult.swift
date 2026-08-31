import Foundation

public struct CompressionResult: Identifiable, Sendable {
    public let id = UUID()
    public let filename: String
    public let originalSize: Int64
    public let compressedSize: Int64?
    public let error: String?
    /// True when compression would have produced a same-or-larger file (same
    /// format) and the pipeline left the original in place instead of
    /// replacing it. `compressedSize` equals `originalSize` in this case.
    public var wasSkipped: Bool = false
    /// The file's final location on disk: the compressed/converted output,
    /// or the untouched original when `wasSkipped` is true. `nil` when
    /// compression failed and there's nothing on disk to reveal or drag.
    public let outputURL: URL?

    public init(
        filename: String,
        originalSize: Int64,
        compressedSize: Int64?,
        error: String?,
        wasSkipped: Bool = false,
        outputURL: URL? = nil
    ) {
        self.filename = filename
        self.originalSize = originalSize
        self.compressedSize = compressedSize
        self.error = error
        self.wasSkipped = wasSkipped
        self.outputURL = outputURL
    }

    public var succeeded: Bool { compressedSize != nil }

    public var reduction: Double {
        guard let compressed = compressedSize, originalSize > 0 else { return 0 }
        return Double(originalSize - compressed) / Double(originalSize) * 100
    }

    public var colorTier: ColorTier {
        guard succeeded else { return .red }
        if wasSkipped { return .skipped }
        return ColorTier.from(reduction: reduction)
    }
}
