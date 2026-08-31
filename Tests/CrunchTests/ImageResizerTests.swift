import CrunchCore
import Foundation
import ImageIO
import Testing

@Suite("ImageResizer")
struct ImageResizerTests {
    @Test("resizes a straight-alpha PNG without throwing, with correct output dimensions")
    func resizesStraightAlphaPNGSuccessfully() async throws {
        let sourceURL = try TestImageFactory.makeStraightAlphaPNG(width: 40, height: 20)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let targetWidth = 20
        let targetHeight = 10

        let resizedURL = try await ImageResizer.resize(
            input: sourceURL,
            width: targetWidth,
            height: targetHeight,
            outputFormat: .png
        )
        defer { try? FileManager.default.removeItem(at: resizedURL) }

        let source = try #require(CGImageSourceCreateWithURL(resizedURL as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)

        #expect(width == targetWidth)
        #expect(height == targetHeight)
    }
}
