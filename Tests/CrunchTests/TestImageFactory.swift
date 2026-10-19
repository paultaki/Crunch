import CrunchCore
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

    /// Pseudo-random-noise PNG written to a caller-chosen URL. Noise matters
    /// for any test that needs compression quality to actually change the
    /// output size: a flat color encodes to nearly the same bytes at q20 and
    /// q95, so a solid image can't distinguish "compressed" from "skipped".
    /// The generator is a fixed-seed LCG, so the bytes are identical on every
    /// run and every machine.
    static func writeNoisyPNG(to url: URL, width: Int, height: Int) throws {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        for i in stride(from: 0, to: pixels.count, by: 4) {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            pixels[i] = UInt8(truncatingIfNeeded: seed >> 33)
            pixels[i + 1] = UInt8(truncatingIfNeeded: seed >> 41)
            pixels[i + 2] = UInt8(truncatingIfNeeded: seed >> 49)
            pixels[i + 3] = 255
        }
        _ = try writePNG(
            pixels: pixels,
            width: width,
            height: height,
            alphaInfo: .noneSkipLast,
            destination: url
        )
    }

    private static func writePNG(
        pixels: [UInt8],
        width: Int,
        height: Int,
        alphaInfo: CGImageAlphaInfo,
        destination: URL? = nil
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

        let tempURL = destination ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("crunch-test-\(UUID().uuidString).png")

        guard let imageDestination = CGImageDestinationCreateWithURL(
            tempURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw TestImageError.cannotCreateDestination
        }

        CGImageDestinationAddImage(imageDestination, cgImage, nil)

        guard CGImageDestinationFinalize(imageDestination) else {
            throw TestImageError.cannotFinalize
        }

        return tempURL
    }
}

/// The metadata fixture used by `MetadataPreservationTests`.
///
/// Deliberately spans the four dictionaries a real photo populates, because
/// they travel through different machinery: `Orientation` is a top-level TIFF
/// tag (and the one with a *visible* consequence), `DateTimeOriginal` and
/// `UserComment` live in the Exif sub-IFD, `Make` in the TIFF IFD, and GPS in
/// its own IFD. A fix that only carried one of them would pass a narrower
/// fixture and still lose a user's capture date or location.
enum TestMetadata {
    /// 6 = "rotate 90° clockwise to display". Chosen over 3 (180°) because a
    /// 90° orientation also swaps the displayed aspect ratio, so a path that
    /// drops it is visible in the dimensions, not just the pixels.
    static let orientation = 6
    static let dateTimeOriginal = "2019:07:04 11:22:33"
    static let userComment = "crunch-metadata-fixture"
    static let make = "CrunchCam"
    static let model = "Fixture One"
    static let latitude = 37.7749
    static let longitude = 122.4194

    /// The property dictionary handed to `CGImageDestinationAddImage`.
    ///
    /// Orientation is written both at the top level and inside the TIFF
    /// dictionary on purpose: ImageIO will not emit the tag from the
    /// top-level key alone for every destination type, and a fixture that
    /// silently failed to carry orientation would make the orientation
    /// assertions vacuously pass.
    static var properties: [CFString: Any] {
        [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFOrientation: orientation,
                kCGImagePropertyTIFFMake: make,
                kCGImagePropertyTIFFModel: model
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: dateTimeOriginal,
                kCGImagePropertyExifUserComment: userComment
            ] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: latitude,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: longitude,
                kCGImagePropertyGPSLongitudeRef: "W"
            ] as [CFString: Any]
        ]
    }
}

/// What a compressed file was found to still be carrying. Every field is
/// optional so an assertion failure reads as "this tag is gone" rather than
/// blowing up on a force-unwrap.
struct ReadMetadata {
    var orientation: Int?
    var dateTimeOriginal: String?
    var userComment: String?
    var make: String?
    var latitude: Double?
    var pixelWidth: Int?
    var pixelHeight: Int?

    /// True when every tag from `TestMetadata` survived intact.
    var isComplete: Bool {
        orientation == TestMetadata.orientation
            && dateTimeOriginal == TestMetadata.dateTimeOriginal
            && userComment == TestMetadata.userComment
            && make == TestMetadata.make
            && latitude == TestMetadata.latitude
    }

}

extension TestImageFactory {
    /// Writes a noisy image carrying the full `TestMetadata` fixture in the
    /// requested format.
    ///
    /// Noise rather than flat colour for the same reason `writeNoisyPNG`
    /// exists: a solid image barely changes size under compression, and these
    /// tests want the compressor to have actually done work before they check
    /// what survived it.
    static func makeImageWithMetadata(
        format: ImageFormat,
        width: Int = 160,
        height: Int = 96
    ) throws -> URL {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        for i in stride(from: 0, to: pixels.count, by: 4) {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            pixels[i] = UInt8(truncatingIfNeeded: seed >> 33)
            pixels[i + 1] = UInt8(truncatingIfNeeded: seed >> 41)
            pixels[i + 2] = UInt8(truncatingIfNeeded: seed >> 49)
            pixels[i + 3] = 255
        }

        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw TestImageError.cannotCreateProvider
        }
        guard let cgImage = CGImage(
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
        ) else {
            throw TestImageError.cannotCreateImage
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crunch-meta-\(UUID().uuidString).\(format.fileExtension)")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.destinationTypeIdentifier as CFString,
            1,
            nil
        ) else {
            throw TestImageError.cannotCreateDestination
        }
        CGImageDestinationAddImage(destination, cgImage, TestMetadata.properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw TestImageError.cannotFinalize
        }
        return url
    }

    /// Reads back whatever metadata a file still carries.
    static func readMetadata(from url: URL) -> ReadMetadata {
        var result = ReadMetadata()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else { return result }

        result.orientation = properties[kCGImagePropertyOrientation] as? Int
        result.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
        result.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            result.dateTimeOriginal = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            result.userComment = exif[kCGImagePropertyExifUserComment] as? String
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            result.make = tiff[kCGImagePropertyTIFFMake] as? String
        }
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            result.latitude = gps[kCGImagePropertyGPSLatitude] as? Double
        }
        return result
    }
}

private extension ImageFormat {
    /// The UTI to hand `CGImageDestinationCreateWithURL` when building a
    /// fixture in this format. WebP is absent because ImageIO cannot encode
    /// it — the WebP tests start from a PNG source instead.
    var destinationTypeIdentifier: String {
        switch self {
        case .png: UTType.png.identifier
        case .jpeg: UTType.jpeg.identifier
        case .avif: "public.avif"
        case .webp: preconditionFailure("ImageIO cannot encode WebP; build WebP fixtures with cwebp")
        }
    }
}

/// Fixtures and helpers for "does this photo still look the same?" checks, as
/// distinct from "is the tag still there?".
///
/// A tag assertion cannot catch the cases that matter most: AVIF cannot carry
/// an orientation tag at all, and an output whose tag survived but whose
/// pixels were rotated anyway would pass every metadata test while looking
/// wrong on screen. These helpers compare what a viewer actually draws.
extension TestImageFactory {
    /// A noisy image with a distinctly coloured block in three of its four
    /// corners, carrying the full `TestMetadata` fixture.
    ///
    /// Asymmetric in both axes and in colour so that all eight orientations —
    /// four rotations and their mirrors — produce a different arrangement. A
    /// symmetric fixture would let a mirrored or 180°-off result pass.
    static func makeMarkerImageWithMetadata(
        format: ImageFormat,
        orientation: Int = TestMetadata.orientation,
        width: Int = 160,
        height: Int = 96
    ) throws -> URL {
        let image = try makeMarkerImage(width: width, height: height)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crunch-marker-\(UUID().uuidString).\(format.fileExtension)")

        var properties = TestMetadata.properties
        properties[kCGImagePropertyOrientation] = orientation
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = orientation
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        // Lossless-ish, so the corner colours survive into the fixture and
        // any later blurring is the pipeline's doing, not the fixture's.
        properties[kCGImageDestinationLossyCompressionQuality] = 1.0

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, format.markerTypeIdentifier as CFString, 1, nil
        ) else { throw TestImageError.cannotCreateDestination }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw TestImageError.cannotFinalize
        }
        return url
    }

    static func makeMarkerImage(width: Int, height: Int) throws -> CGImage {
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
        fill(originX: 0, originY: 0, red: 235, green: 20, blue: 20)
        fill(originX: width - width / 4, originY: 0, red: 20, green: 235, blue: 20)
        fill(originX: 0, originY: height - height / 4, red: 20, green: 20, blue: 235)

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            throw TestImageError.cannotCreateProvider
        }
        guard let image = CGImage(
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
        ) else { throw TestImageError.cannotCreateImage }
        return image
    }

    /// How a viewer draws `url`: the image with its EXIF orientation applied,
    /// described as its aspect orientation plus the colour in each corner.
    ///
    /// Uses `kCGImageSourceCreateThumbnailWithTransform`, which is ImageIO
    /// honouring the orientation exactly as Preview and Quick Look do, so the
    /// comparison is against the platform's own rendering rather than against
    /// our idea of it.
    static func renderedAppearance(of url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let rendered = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(width, height)
              ] as CFDictionary)
        else { return "unreadable" }
        return "\(shape(of: rendered)) \(cornerMarkers(of: rendered))"
    }

    private static func shape(of image: CGImage) -> String {
        if image.width > image.height { return "landscape" }
        if image.width < image.height { return "portrait" }
        return "square"
    }

    /// The dominant marker colour in each corner, clockwise from top-left.
    ///
    /// Classifies by which channel dominates rather than by fixed
    /// thresholds, because every output here has been through a lossy
    /// encoder at quality 80 and the corner blocks come back softened.
    private static func cornerMarkers(of image: CGImage) -> String {
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
            let red = Int(bytes[index])
            let green = Int(bytes[index + 1])
            let blue = Int(bytes[index + 2])
            let peak = max(red, green, blue)
            let rest = (red + green + blue - peak) / 2
            // The unmarked background is near-grey (30,30,30), so a corner
            // only counts as a marker when one channel clearly leads.
            guard peak > 90, peak - rest > 60 else { return "." }
            if peak == red { return "R" }
            if peak == green { return "G" }
            return "B"
        }
        // Inset enough to clear the encoder's ringing at each block edge.
        let inset = max(3, min(width, height) / 16)
        return [
            marker(atX: inset, y: inset),
            marker(atX: width - 1 - inset, y: inset),
            marker(atX: inset, y: height - 1 - inset),
            marker(atX: width - 1 - inset, y: height - 1 - inset)
        ].joined(separator: " ")
    }
}

private extension ImageFormat {
    /// Like `destinationTypeIdentifier`, but WebP falls back to PNG: ImageIO
    /// cannot encode WebP, and a PNG source reaches the WebP output path
    /// through the pipeline just the same.
    var markerTypeIdentifier: String {
        switch self {
        case .png, .webp: UTType.png.identifier
        case .jpeg: UTType.jpeg.identifier
        case .avif: "public.avif"
        }
    }
}
