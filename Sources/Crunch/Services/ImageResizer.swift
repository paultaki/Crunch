import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageResizer {
    static func resize(input: URL, width: Int, height: Int) async throws -> URL {
        guard let imageSource = CGImageSourceCreateWithURL(input as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw CompressionError.cannotReadImage(input.lastPathComponent)
        }

        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: cgImage.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: cgImage.alphaInfo.rawValue
        ) else {
            throw CompressionError.cannotReadImage(input.lastPathComponent)
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let resizedImage = context.makeImage() else {
            throw CompressionError.cannotReadImage(input.lastPathComponent)
        }

        // Write to temp file in same format as input
        let ext = input.pathExtension.lowercased()
        let utType: CFString
        switch ext {
        case "png": utType = UTType.png.identifier as CFString
        case "jpg", "jpeg": utType = UTType.jpeg.identifier as CFString
        case "webp": utType = UTType.webP.identifier as CFString
        default: utType = UTType.png.identifier as CFString
        }

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(ext)")

        guard let destination = CGImageDestinationCreateWithURL(
            tempFile as CFURL,
            utType,
            1,
            nil
        ) else {
            throw CompressionError.cannotWriteImage("temp resize file")
        }

        CGImageDestinationAddImage(destination, resizedImage, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw CompressionError.cannotWriteImage("temp resize file")
        }

        return tempFile
    }
}
