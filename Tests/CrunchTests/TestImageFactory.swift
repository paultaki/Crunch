import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates throwaway PNGs for tests, entirely in-memory via raw pixel
/// buffers so no fixture files are needed. Every writer returns a fresh temp
/// URL the caller owns and must remove.
enum TestImageFactory {
    enum TestImageError: Error {
        case cannotCreateProvider
        case cannotCreateImage
        case cannotCreateDestination
        case cannotFinalize
    }

    /// Flat-color, fully-opaque PNG for tests that don't care about alpha
    /// handling.
    static func makeSolidPNG(width: Int, height: Int) throws -> URL {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 120
            pixels[i + 1] = 180
            pixels[i + 2] = 220
            pixels[i + 3] = 255
        }
        return try writePNG(pixels: pixels, width: width, height: height, alphaInfo: .noneSkipLast)
    }

    /// Straight-alpha (non-premultiplied) PNG where color channel values
    /// exceed the alpha value at every pixel — invalid under a premultiplied
    /// reading, so a resizer that mishandles straight alpha corrupts or
    /// rejects it. Pins the Task 1 straight-alpha fix in `ImageResizer`.
    static func makeStraightAlphaPNG(width: Int, height: Int) throws -> URL {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 200
            pixels[i + 1] = 100
            pixels[i + 2] = 50
            pixels[i + 3] = 128
        }
        return try writePNG(pixels: pixels, width: width, height: height, alphaInfo: .last)
    }

    private static func writePNG(
        pixels: [UInt8],
        width: Int,
        height: Int,
        alphaInfo: CGImageAlphaInfo
    ) throws -> URL {
        let bytesPerRow = width * 4
        let data = Data(pixels)

        guard let provider = CGDataProvider(data: data as CFData) else {
            throw TestImageError.cannotCreateProvider
        }

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw TestImageError.cannotCreateImage
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("crunch-test-\(UUID().uuidString).png")

        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw TestImageError.cannotCreateDestination
        }

        CGImageDestinationAddImage(destination, cgImage, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw TestImageError.cannotFinalize
        }

        return tempURL
    }
}
