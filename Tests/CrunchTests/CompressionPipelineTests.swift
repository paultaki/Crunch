import CrunchCore
import Foundation
import ImageIO
import Testing

@Suite("CompressionPipeline")
struct CompressionPipelineTests {
    // The cross-volume fix in one deterministic, CI-safe assertion: the
    // output temp must be created in the directory it was handed, because
    // that is what makes the caller's `replaceItemAt` a same-volume (and
    // therefore atomic, and therefore possible) operation. CI has only one
    // volume, so "same directory as asked" is the invariant that stands in
    // for "same volume as the user's file".
    @Test("output temp is staged in the directory the caller handed in, dot-prefixed")
    func outputIsStagedInGivenDirectory() async throws {
        let sourceURL = try TestImageFactory.makeSolidPNG(width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("crunch-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let file = try #require(ImageFile.load(from: sourceURL))
        let settings = CompressionSettings(outputFormat: .jpeg, resolutionPercent: 100, quality: 80)

        let output = try await CompressionPipeline.run(
            file: file,
            settings: settings,
            stagingDirectory: staging
        )
        defer { try? FileManager.default.removeItem(at: output.url) }

        #expect(
            output.url.deletingLastPathComponent().standardizedFileURL
                == staging.standardizedFileURL
        )
        // Hidden while it sits in what may be the user's own folder.
        #expect(output.url.lastPathComponent.hasPrefix(".crunch-"))
        #expect(FileManager.default.fileExists(atPath: output.url.path))
    }

    // No silent fallback: an unwritable destination folder has to surface as
    // a clear per-file error naming the folder, not as an obscure encoder
    // failure and not as a cross-volume copy that would give up atomicity.
    @Test("an unwritable staging directory throws an error naming the folder")
    func unwritableStagingDirectoryThrows() async throws {
        let sourceURL = try TestImageFactory.makeSolidPNG(width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let folderName = "crunch-readonly-\(UUID().uuidString)"
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent(folderName)
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o500]
        )
        defer {
            // Restore write permission first or the directory can't be removed.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: staging.path
            )
            try? FileManager.default.removeItem(at: staging)
        }

        // Running as root ignores the mode bits entirely, which would make
        // this test assert nothing. Skip honestly instead of passing falsely.
        try #require(
            !FileManager.default.isWritableFile(atPath: staging.path),
            "staging directory is still writable (running as root?)"
        )

        let file = try #require(ImageFile.load(from: sourceURL))
        let settings = CompressionSettings(outputFormat: .jpeg, resolutionPercent: 100, quality: 80)

        await #expect {
            _ = try await CompressionPipeline.run(
                file: file,
                settings: settings,
                stagingDirectory: staging
            )
        } throws: { error in
            error.localizedDescription.contains(folderName)
        }

        // Nothing was left behind in the folder we couldn't write to.
        let leftovers = try? FileManager.default.contentsOfDirectory(atPath: staging.path)
        #expect(leftovers?.isEmpty ?? true)
    }

    @Test("JPEG output path compresses end-to-end via native ImageIO")
    func jpegPathEndToEnd() async throws {
        let sourceURL = try TestImageFactory.makeSolidPNG(width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let file = try #require(ImageFile.load(from: sourceURL))
        let settings = CompressionSettings(outputFormat: .jpeg, resolutionPercent: 100, quality: 80)

        let output = try await CompressionPipeline.run(
            file: file,
            settings: settings,
            stagingDirectory: FileManager.default.temporaryDirectory
        )
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

        let output = try await CompressionPipeline.run(
            file: file,
            settings: settings,
            stagingDirectory: FileManager.default.temporaryDirectory
        )
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

        let output = try await CompressionPipeline.run(
            file: file,
            settings: settings,
            stagingDirectory: FileManager.default.temporaryDirectory
        )
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

        let output = try await CompressionPipeline.run(
            file: file,
            settings: settings,
            stagingDirectory: FileManager.default.temporaryDirectory
        )
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
            settings: CompressionSettings(outputFormat: .avif, resolutionPercent: 100, quality: 80),
            stagingDirectory: FileManager.default.temporaryDirectory
        )
        defer { try? FileManager.default.removeItem(at: avif.url) }

        let avifFile = try #require(ImageFile.load(from: avif.url))
        #expect(avifFile.format == .avif)

        let webp = try await CompressionPipeline.run(
            file: avifFile,
            settings: CompressionSettings(outputFormat: .webp, resolutionPercent: 100, quality: 80),
            stagingDirectory: FileManager.default.temporaryDirectory
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

        let output = try await CompressionPipeline.run(
            file: file,
            settings: settings,
            stagingDirectory: FileManager.default.temporaryDirectory
        )
        defer { try? FileManager.default.removeItem(at: output.url) }

        #expect(output.bytes > 0)
        #expect(FileManager.default.fileExists(atPath: output.url.path))
    }
}
