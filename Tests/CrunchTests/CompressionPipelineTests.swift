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

    // AVIF encode support varies by OS/hardware even within the macOS 15
    // deployment target (see OutputFormat.avifEncodingSupported); skip
    // rather than fail when this machine's ImageIO doesn't have it, same as
    // the pngquant/cwebp tests below.
    @Test(
        "AVIF output path compresses end-to-end via native ImageIO",
        .enabled(if: OutputFormat.avifEncodingSupported)
    )
    func avifPathEndToEnd() async throws {
        let sourceURL = try TestImageFactory.makeSolidPNG(width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let file = try #require(ImageFile.load(from: sourceURL))
        let settings = CompressionSettings(outputFormat: .avif, resolutionPercent: 100, quality: 80)

        let output = try await CompressionPipeline.run(file: file, settings: settings)
        defer { try? FileManager.default.removeItem(at: output.url) }

        #expect(output.bytes > 0)
        #expect(FileManager.default.fileExists(atPath: output.url.path))
        #expect(output.url.pathExtension == "avif")

        // Confirm the bytes on disk actually decode as an image (i.e. the
        // AVIF encode round-trips), not just that a file exists.
        let source = try #require(CGImageSourceCreateWithURL(output.url as CFURL, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
    }

    @Test(
        "AVIF output is readable back as an ImageFile — decode support, not just encode",
        .enabled(if: OutputFormat.avifEncodingSupported)
    )
    func avifOutputIsReadableAsImageFile() async throws {
        let sourceURL = try TestImageFactory.makeSolidPNG(width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let file = try #require(ImageFile.load(from: sourceURL))
        let settings = CompressionSettings(outputFormat: .avif, resolutionPercent: 100, quality: 80)

        let output = try await CompressionPipeline.run(file: file, settings: settings)
        defer { try? FileManager.default.removeItem(at: output.url) }

        let reloaded = try #require(ImageFile.load(from: output.url))
        #expect(reloaded.format == .avif)
        #expect(reloaded.pixelWidth == 64)
        #expect(reloaded.pixelHeight == 64)
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

    // AVIF is the one source format cwebp cannot decode, so this pins the
    // normalize-to-PNG hop in WebPCompressor. Needs both an AVIF encoder (to
    // build the fixture) and cwebp.
    @Test(
        "AVIF source converts to WebP by normalizing through PNG first",
        .enabled(if: OutputFormat.avifEncodingSupported && ToolChecker.cwebpPath != nil)
    )
    func avifSourceConvertsToWebP() async throws {
        let pngURL = try TestImageFactory.makeSolidPNG(width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: pngURL) }

        let pngFile = try #require(ImageFile.load(from: pngURL))
        let avif = try await CompressionPipeline.run(
            file: pngFile,
            settings: CompressionSettings(outputFormat: .avif, resolutionPercent: 100, quality: 80)
        )
        defer { try? FileManager.default.removeItem(at: avif.url) }

        let avifFile = try #require(ImageFile.load(from: avif.url))
        #expect(avifFile.format == .avif)

        let webp = try await CompressionPipeline.run(
            file: avifFile,
            settings: CompressionSettings(outputFormat: .webp, resolutionPercent: 100, quality: 80)
        )
        defer { try? FileManager.default.removeItem(at: webp.url) }

        #expect(webp.bytes > 0)
        let reloaded = try #require(ImageFile.load(from: webp.url))
        #expect(reloaded.format == .webp)
        #expect(reloaded.pixelWidth == 64)
        #expect(reloaded.pixelHeight == 64)
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
