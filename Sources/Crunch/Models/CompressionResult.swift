import Foundation

struct CompressionResult: Identifiable {
    let id = UUID()
    let filename: String
    let originalSize: Int64
    let compressedSize: Int64?
    let error: String?
    /// True when compression would have produced a same-or-larger file (same
    /// format) and the pipeline left the original in place instead of
    /// replacing it. `compressedSize` equals `originalSize` in this case.
    var wasSkipped: Bool = false

    var succeeded: Bool { compressedSize != nil }

    var reduction: Double {
        guard let compressed = compressedSize, originalSize > 0 else { return 0 }
        return Double(originalSize - compressed) / Double(originalSize) * 100
    }

    var colorTier: ColorTier {
        guard succeeded else { return .red }
        if wasSkipped { return .skipped }
        return ColorTier.from(reduction: reduction)
    }
}
