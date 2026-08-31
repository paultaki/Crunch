import CrunchCore
import Foundation
import ImageIO
import Testing

@Suite("CompressionPipeline")
struct CompressionPipelineTests {
    @Test("JPEG output path compresses end-to-end via native ImageIO")
    func jpegPathEndToEnd() async throws {
        let sourceURL = try TestImageFactory.makeSolidPNG(width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let file = try #require(ImageFile.load(from: sourceURL))
        let settings = CompressionSettings(outputFormat: .jpeg, resolutionPercent: 100, quality: 80)

        let output = try await CompressionPipeline.run(file: file, settings: settings)
        defer { try? FileManager.default.removeItem(at: output.url) }

        #expect(output.bytes > 0)
        #expect(FileManager.default.fileExists(atPath: output.url.path))
        #expect(output.url.pathExtension == "jpg")

        // Confirm the bytes on disk actually decode as an image (i.e. the
        // JPEG encode round-trips), not just that a file exists.
        let source = try #require(CGImageSourceCreateWithURL(output.url as CFURL, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
    }

    // pngquant may not be installed in every environment (CI in particular);
    // skip rather than fail when it isn't.
    @Test(
        "PNG output path compresses via pngquant",
        .enabled(if: ToolChecker.pngquantPath != nil)
    )
    func pngPathWhenToolAvailable() async throws {
        let sourceURL = try TestImageFactory.makeSolidPNG(width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let file = try #require(ImageFile.load(from: sourceURL))
        let settings = CompressionSettings(outputFormat: .png, resolutionPercent: 100, quality: 80)

        let output = try await CompressionPipeline.run(file: file, settings: settings)
        defer { try? FileManager.default.removeItem(at: output.url) }

        #expect(output.bytes > 0)
        #expect(FileManager.default.fileExists(atPath: output.url.path))
    }

    // cwebp may not be installed in every environment; skip rather than fail
    // when it isn't.
    @Test(
        "WebP output path compresses via cwebp",
        .enabled(if: ToolChecker.cwebpPath != nil)
    )
    func webpPathWhenToolAvailable() async throws {
        let sourceURL = try TestImageFactory.makeSolidPNG(width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let file = try #require(ImageFile.load(from: sourceURL))
        let settings = CompressionSettings(outputFormat: .webp, resolutionPercent: 100, quality: 80)

        let output = try await CompressionPipeline.run(file: file, settings: settings)
        defer { try? FileManager.default.removeItem(at: output.url) }

        #expect(output.bytes > 0)
        #expect(FileManager.default.fileExists(atPath: output.url.path))
    }
}
