import Foundation
import ImageIO
import UniformTypeIdentifiers

enum JPEGCompressor {
    static func compress(input: URL, output: URL, quality: Int) async throws {
        let qualityFloat = Double(quality) / 100.0

        guard let imageSource = CGImageSourceCreateWithURL(input as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw CompressionError.cannotReadImage(input.lastPathComponent)
        }

        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CompressionError.cannotWriteImage(output.lastPathComponent)
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: qualityFloat
        ]

        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw CompressionError.cannotWriteImage(output.lastPathComponent)
        }
    }
}

enum CompressionError: LocalizedError {
    case cannotReadImage(String)
    case cannotCreateContext(String)
    case cannotWriteImage(String)
    case toolMissing(String)
    case avifNotSupported

    var errorDescription: String? {
        switch self {
        case .cannotReadImage(let name): "Cannot read image: \(name)"
        case .cannotCreateContext(let name): "Cannot create drawing context for: \(name)"
        case .cannotWriteImage(let name): "Cannot write image: \(name)"
        case .toolMissing(let name): "Required tool not found: \(name)"
        case .avifNotSupported: MissingToolsMessage.avifUnsupported
        }
    }
}
