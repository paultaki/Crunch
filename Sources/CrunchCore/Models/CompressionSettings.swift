import Foundation

public struct CompressionSettings: Equatable, Sendable {
    public var outputFormat: OutputFormat = .same
    public var resolutionPercent: Int = 100
    public var quality: Int = 80

    public init(
        outputFormat: OutputFormat = .same,
        resolutionPercent: Int = 100,
        quality: Int = 80
    ) {
        self.outputFormat = outputFormat
        self.resolutionPercent = resolutionPercent
        self.quality = quality
    }
}
