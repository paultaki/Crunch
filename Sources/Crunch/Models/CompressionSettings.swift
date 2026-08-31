import Foundation

struct CompressionSettings: Equatable {
    var outputFormat: OutputFormat = .same
    var resolutionPercent: Int = 100
    var quality: Int = 80
}
