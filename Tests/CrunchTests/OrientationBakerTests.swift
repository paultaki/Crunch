import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import CrunchCore

/// Checks all eight EXIF orientations against ImageIO's own interpretation of
/// them.
///
/// `OrientationBaker` exists because ImageIO's AVIF encoder discards the
/// orientation tag, so the rotation has to be drawn into the pixels instead.
/// That means hand-written affine transforms, and hand-written affine
/// transforms in a flipped coordinate space are very easy to get subtly
/// wrong: on the first attempt two of these eight were mirrored or rotated
/// the wrong way, and nothing but a corner-marker fixture would have noticed.
/// Dimensions alone cannot catch it — orientations 5 and 7 produce identically
/// sized output and differ only in where the pixels land.
///
/// Ground truth is `kCGImageSourceCreateThumbnailWithTransform`, i.e. ImageIO
/// applying the orientation itself, at full size. Comparing against the
/// platform rather than against hardcoded expectations means these tests
/// assert "we agree with how macOS draws this photo", which is the property
/// that actually matters.
@Suite("OrientationBaker")
struct OrientationBakerTests {
    @Test("baking matches ImageIO's own transform", arguments: 1...8)
    func bakeMatchesImageIO(orientation: Int) throws {
        let source = try writeMarkerJPEG(orientation: orientation)
        defer { try? FileManager.default.removeItem(at: source) }

        let imageSource = try #require(CGImageSourceCreateWithURL(source as CFURL, nil))

        // Guard against a vacuous pass: if the tag never made it into the
        // file, both sides would be the untransformed image and every
        // orientation would "agree".
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        )
        #expect(properties[kCGImagePropertyOrientation] as? Int == orientation)

        let stored = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let expected = try #require(CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(Self.width, Self.height)
            ] as CFDictionary
        ))
        let baked = try #require(OrientationBaker.bake(stored, orientation: orientation))

        #expect(baked.width == expected.width)
        #expect(baked.height == expected.height)
        #expect(cornerMarkers(of: baked) == cornerMarkers(of: expected))
    }

    @Test("an upright image is handed back untouched rather than redrawn")
    func uprightIsNotRedrawn() throws {
        let source = try writeMarkerJPEG(orientation: 1)
        defer { try? FileManager.default.removeItem(at: source) }

        let imageSource = try #require(CGImageSourceCreateWithURL(source as CFURL, nil))
        let stored = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))

        #expect(OrientationBaker.isUpright(1))
        // Identity, not a copy: orientation 1 is the overwhelmingly common
        // case and must not cost a full decode-and-redraw.
        #expect(OrientationBaker.bake(stored, orientation: 1) === stored)
    }

    // Transparency must survive the redraw. Rotating a photo is no reason to
    // flatten its alpha channel, and AVIF — the only format that gets baked —
    // supports alpha perfectly well.
    @Test("baking keeps an alpha channel instead of flattening it")
    func bakePreservesAlpha() throws {
        let width = 40, height = 24
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = 200
            pixels[index + 1] = 100
            pixels[index + 2] = 50
            pixels[index + 3] = 128
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let translucent = try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))

        let baked = try #require(OrientationBaker.bake(translucent, orientation: 6))
        #expect(baked.width == height)
        #expect(baked.height == width)
        #expect(baked.alphaInfo != .none)
        #expect(baked.alphaInfo != .noneSkipLast)
        #expect(baked.alphaInfo != .noneSkipFirst)
    }

    // MARK: - Fixture

    private static let width = 160
    private static let height = 96

    /// A JPEG whose stored pixels carry a different solid colour in three
    /// corners, tagged with `orientation`.
    ///
    /// Asymmetric in both axes and in colour, so every one of the eight
    /// transforms — four rotations and their mirrors — produces a distinct
    /// arrangement. A symmetric fixture would let a mirrored transform pass.
    private func writeMarkerJPEG(orientation: Int) throws -> URL {
        let width = Self.width
        let height = Self.height
        var pixels = [UInt8](repeating: 30, count: width * height * 4)

        func fill(originX: Int, originY: Int, red: UInt8, green: UInt8, blue: UInt8) {
            for y in 0..<(height / 4) {
                for x in 0..<(width / 4) {
                    let index = ((originY + y) * width + (originX + x)) * 4
                    pixels[index] = red
                    pixels[index + 1] = green
                    pixels[index + 2] = blue
                    pixels[index + 3] = 255
                }
            }
        }
        fill(originX: 0, originY: 0, red: 255, green: 0, blue: 0)
        fill(originX: width - width / 4, originY: 0, red: 0, green: 255, blue: 0)
        fill(originX: 0, originY: height - height / 4, red: 0, green: 0, blue: 255)

        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crunch-orient-\(UUID().uuidString).jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        // Both keys, because ImageIO will not reliably emit the tag from the
        // top-level key alone, and quality 1.0 so the corner colours survive
        // the JPEG round trip intact.
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFOrientation: orientation
            ] as [CFString: Any],
            kCGImageDestinationLossyCompressionQuality: 1.0
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// Which marker colour sits in each corner of the drawn image, as a
    /// four-character signature like `"B R . G"`.
    private func cornerMarkers(of image: CGImage) -> String {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let buffer = context.data else { return "unreadable" }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = buffer.bindMemory(to: UInt8.self, capacity: width * height * 4)

        func marker(atX x: Int, y: Int) -> String {
            let index = (y * width + x) * 4
            let red = bytes[index], green = bytes[index + 1], blue = bytes[index + 2]
            if red > 180 && green < 80 && blue < 80 { return "R" }
            if green > 180 && red < 80 && blue < 80 { return "G" }
            if blue > 180 && red < 80 && green < 80 { return "B" }
            return "."
        }
        // Inset by two pixels so JPEG ringing at the block edges cannot sway
        // the sample.
        return [
            marker(atX: 2, y: 2),
            marker(atX: width - 3, y: 2),
            marker(atX: 2, y: height - 3),
            marker(atX: width - 3, y: height - 3)
        ].joined(separator: " ")
    }
}
