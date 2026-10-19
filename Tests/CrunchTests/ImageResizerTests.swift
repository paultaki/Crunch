import CoreGraphics
import CrunchCore
import Foundation
import ImageIO
import Testing

@Suite("ImageResizer")
struct ImageResizerTests {
    // There is deliberately no "writes nothing to disk" test. It was written,
    // and it was flaky: it snapshotted `FileManager.default.temporaryDirectory`
    // around the call, which other suites write to concurrently, so it passed
    // alone and failed in the full run. Scoping it properly would mean giving
    // `resize` an injectable temp directory — a seam in production code for a
    // fact the signature already states, since a `CGImage` return has nowhere
    // to put a file.

    @Test("resizes a straight-alpha PNG without throwing, with correct output dimensions")
    func resizesStraightAlphaPNGSuccessfully() throws {
        let sourceURL = try TestImageFactory.makeStraightAlphaPNG(width: 40, height: 20)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let targetWidth = 20
        let targetHeight = 10

        let resized = try ImageResizer.resize(
            input: sourceURL,
            width: targetWidth,
            height: targetHeight
        )

        // Asserted on the returned image rather than on a written file: the
        // resize no longer produces one, which is the point of it.
        #expect(resized.width == targetWidth)
        #expect(resized.height == targetHeight)
    }

    /// `CompressionError` is internal to CrunchCore, so this pins the
    /// behaviour that matters from outside: an undecodable input throws
    /// rather than returning a bogus image for the encoder to write.
    @Test("throws instead of returning an image when the input cannot be decoded")
    func throwsOnUndecodableInput() throws {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("crunch-test-\(UUID().uuidString).png")
        try Data("not a png".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        #expect(throws: (any Error).self) {
            _ = try ImageResizer.resize(input: bogus, width: 10, height: 10)
        }
    }
}
