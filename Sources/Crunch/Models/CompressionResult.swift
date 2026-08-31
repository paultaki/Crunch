import Foundation

struct CompressionResult: Identifiable {
    let id = UUID()
    let filename: String
    let originalSize: Int64
    let compressedSize: Int64?
    let error: String?

    var succeeded: Bool { compressedSize != nil }

    var reduction: Double {
        guard let compressed = compressedSize, originalSize > 0 else { return 0 }
        return Double(originalSize - compressed) / Double(originalSize) * 100
    }

    var colorTier: ColorTier {
        guard succeeded else { return .red }
        return ColorTier.from(reduction: reduction)
    }
}
