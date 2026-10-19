import CoreGraphics
import CrunchCore
import Foundation
import ImageIO
import Testing

/// Pins the metadata data-loss bug found in the 2026-10-19 audit: every
/// compressor decoded the source to a bare `CGImage` and wrote it back with
/// nothing but a quality key, so capture date, camera, GPS and — most
/// visibly — EXIF orientation were silently discarded. A phone photo stored
/// as landscape pixels plus "rotate 90°" came out of Crunch rotated.
///
/// Each test drives the real `CompressionPipeline`, not a compressor in
/// isolation, because the pipeline is where the subtle half of the bug lives:
/// under 100% resolution it hands the compressor a freshly-written temp file
/// that never carried the original's metadata, so a fix that reads metadata
/// from the compressor's *input* passes the simple cases and still loses
/// everything the moment the user drags the resolution slider.
@Suite("Metadata preservation")
struct MetadataPreservationTests {
    // MARK: - Per-format round trips

    @Test("JPEG output keeps orientation, capture date, camera and GPS")
    func jpegPreservesMetadata() async throws {
        let source = try TestImageFactory.makeImageWithMetadata(format: .jpeg)
        defer { try? FileManager.default.removeItem(at: source) }

        // Guard against a vacuous pass: if the fixture never carried the
        // metadata, every assertion below would be meaningless.
        #expect(TestImageFactory.readMetadata(from: source).isComplete)

        let output = try await compress(source, outputFormat: .jpeg)
        defer { try? FileManager.default.removeItem(at: output.url) }

        let metadata = TestImageFactory.readMetadata(from: output.url)
        #expect(metadata.orientation == TestMetadata.orientation)
        #expect(metadata.dateTimeOriginal == TestMetadata.dateTimeOriginal)
        #expect(metadata.userComment == TestMetadata.userComment)
        #expect(metadata.make == TestMetadata.make)
        #expect(metadata.latitude == TestMetadata.latitude)
    }

    // pngquant is the awkward one: on macOS it strips metadata by default
    // (`--strip ... (default on Mac)`) and offers no flag to turn that off, so
    // preserving anything here means putting the EXIF back after it runs.
    @Test(
        "PNG output keeps orientation and the rest, despite pngquant stripping it",
        .enabled(if: ToolChecker.pngquantPath != nil)
    )
    func pngPreservesMetadata() async throws {
        let source = try TestImageFactory.makeImageWithMetadata(format: .png)
        defer { try? FileManager.default.removeItem(at: source) }
        #expect(TestImageFactory.readMetadata(from: source).isComplete)

        let output = try await compress(source, outputFormat: .png)
        defer { try? FileManager.default.removeItem(at: output.url) }

        let metadata = TestImageFactory.readMetadata(from: output.url)
        #expect(metadata.orientation == TestMetadata.orientation)
        #expect(metadata.dateTimeOriginal == TestMetadata.dateTimeOriginal)
        #expect(metadata.userComment == TestMetadata.userComment)
        #expect(metadata.make == TestMetadata.make)
        #expect(metadata.latitude == TestMetadata.latitude)

        // The rewrite must not disturb the pixels pngquant produced — a PNG
        // whose chunks we spliced still has to decode, at the right size.
        let reloaded = try #require(ImageFile.load(from: output.url))
        #expect(reloaded.pixelWidth == 160)
        #expect(reloaded.pixelHeight == 96)
    }

    @Test(
        "WebP output keeps orientation and the rest",
        .enabled(if: ToolChecker.cwebpPath != nil)
    )
    func webpPreservesMetadata() async throws {
        // Source is a PNG because ImageIO cannot encode WebP; cwebp reads
        // EXIF out of a PNG's eXIf chunk happily.
        let source = try TestImageFactory.makeImageWithMetadata(format: .png)
        defer { try? FileManager.default.removeItem(at: source) }
        #expect(TestImageFactory.readMetadata(from: source).isComplete)

        let output = try await compress(source, outputFormat: .webp)
        defer { try? FileManager.default.removeItem(at: output.url) }

        let metadata = TestImageFactory.readMetadata(from: output.url)
        #expect(metadata.orientation == TestMetadata.orientation)
        #expect(metadata.dateTimeOriginal == TestMetadata.dateTimeOriginal)
        #expect(metadata.userComment == TestMetadata.userComment)
        #expect(metadata.make == TestMetadata.make)
        #expect(metadata.latitude == TestMetadata.latitude)
    }

    // AVIF carries the Exif/TIFF/GPS payload but NOT orientation: ImageIO's
    // AVIF encoder forces the tag to 1 even when handed an explicit
    // `kCGImageDestinationOrientation` (measured 2026-10-19; HEIC, the same
    // container family, keeps it). The orientation half is covered by
    // `avifBakesOrientationIntoPixels` below.
    @Test(
        "AVIF output keeps capture date, camera and GPS",
        .enabled(if: OutputFormat.avifEncodingSupported)
    )
    func avifPreservesMetadata() async throws {
        let source = try TestImageFactory.makeImageWithMetadata(format: .avif)
        defer { try? FileManager.default.removeItem(at: source) }

        let output = try await compress(source, outputFormat: .avif)
        defer { try? FileManager.default.removeItem(at: output.url) }

        let metadata = TestImageFactory.readMetadata(from: output.url)
        #expect(metadata.dateTimeOriginal == TestMetadata.dateTimeOriginal)
        #expect(metadata.userComment == TestMetadata.userComment)
        #expect(metadata.make == TestMetadata.make)
        #expect(metadata.latitude == TestMetadata.latitude)
    }

    // The user-visible half of the bug, for the one format that cannot carry
    // the tag. Since ImageIO drops AVIF orientation, the rotation has to be
    // applied to the pixels instead — which shows up as the displayed
    // dimensions swapping, 160x96 landscape becoming 96x160 portrait.
    @Test(
        "AVIF bakes a 90° orientation into the pixels rather than losing it",
        .enabled(if: OutputFormat.avifEncodingSupported)
    )
    func avifBakesOrientationIntoPixels() async throws {
        let source = try TestImageFactory.makeImageWithMetadata(format: .jpeg)
        defer { try? FileManager.default.removeItem(at: source) }

        let output = try await compress(source, outputFormat: .avif)
        defer { try? FileManager.default.removeItem(at: output.url) }

        let metadata = TestImageFactory.readMetadata(from: output.url)
        #expect(metadata.pixelWidth == 96)
        #expect(metadata.pixelHeight == 160)
        // ...and the now-redundant tag must not also say "rotate me", or a
        // reader that honoured it would rotate a second time.
        #expect(metadata.orientation == nil || metadata.orientation == 1)
    }

    // MARK: - The resize path

    // The subtle half. Under 100% resolution the pipeline routes through
    // `ImageResizer`, which writes a plain intermediate PNG; the compressor's
    // input is that temp and carries none of the user's metadata. Metadata
    // therefore has to come from `file.url` — the original — and not from
    // whatever the pipeline happens to hand the compressor.
    @Test("JPEG keeps metadata when resized, where the compressor's input is a bare temp")
    func jpegPreservesMetadataWhenResized() async throws {
        let source = try TestImageFactory.makeImageWithMetadata(format: .jpeg)
        defer { try? FileManager.default.removeItem(at: source) }

        let output = try await compress(source, outputFormat: .jpeg, resolutionPercent: 50)
        defer { try? FileManager.default.removeItem(at: output.url) }

        let metadata = TestImageFactory.readMetadata(from: output.url)
        #expect(metadata.orientation == TestMetadata.orientation)
        #expect(metadata.dateTimeOriginal == TestMetadata.dateTimeOriginal)
        #expect(metadata.make == TestMetadata.make)
        #expect(metadata.latitude == TestMetadata.latitude)
        #expect(metadata.pixelWidth == 80)
        #expect(metadata.pixelHeight == 48)
    }

    @Test(
        "PNG keeps metadata when resized",
        .enabled(if: ToolChecker.pngquantPath != nil)
    )
    func pngPreservesMetadataWhenResized() async throws {
        let source = try TestImageFactory.makeImageWithMetadata(format: .png)
        defer { try? FileManager.default.removeItem(at: source) }

        let output = try await compress(source, outputFormat: .png, resolutionPercent: 50)
        defer { try? FileManager.default.removeItem(at: output.url) }

        let metadata = TestImageFactory.readMetadata(from: output.url)
        #expect(metadata.orientation == TestMetadata.orientation)
        #expect(metadata.userComment == TestMetadata.userComment)
        #expect(metadata.latitude == TestMetadata.latitude)
        #expect(metadata.pixelWidth == 80)
    }

    @Test(
        "WebP keeps metadata when resized, where cwebp does the resizing itself",
        .enabled(if: ToolChecker.cwebpPath != nil)
    )
    func webpPreservesMetadataWhenResized() async throws {
        let source = try TestImageFactory.makeImageWithMetadata(format: .png)
        defer { try? FileManager.default.removeItem(at: source) }

        let output = try await compress(source, outputFormat: .webp, resolutionPercent: 50)
        defer { try? FileManager.default.removeItem(at: output.url) }

        let metadata = TestImageFactory.readMetadata(from: output.url)
        #expect(metadata.orientation == TestMetadata.orientation)
        #expect(metadata.userComment == TestMetadata.userComment)
        #expect(metadata.latitude == TestMetadata.latitude)
        #expect(metadata.pixelWidth == 80)
    }

    // The format-conversion path that normalizes through a temp PNG, because
    // cwebp cannot decode AVIF. cwebp can only read metadata from the file it
    // is given, so the normalized temp has to carry the original's metadata
    // forward or there is nothing for `-metadata all` to copy.
    @Test(
        "AVIF converted to WebP keeps metadata across the normalize hop",
        .enabled(if: OutputFormat.avifEncodingSupported && ToolChecker.cwebpPath != nil)
    )
    func avifToWebPPreservesMetadata() async throws {
        let source = try TestImageFactory.makeImageWithMetadata(format: .avif)
        defer { try? FileManager.default.removeItem(at: source) }

        let output = try await compress(source, outputFormat: .webp)
        defer { try? FileManager.default.removeItem(at: output.url) }

        let metadata = TestImageFactory.readMetadata(from: output.url)
        #expect(metadata.dateTimeOriginal == TestMetadata.dateTimeOriginal)
        #expect(metadata.userComment == TestMetadata.userComment)
        #expect(metadata.make == TestMetadata.make)
        #expect(metadata.latitude == TestMetadata.latitude)
    }

    // MARK: - The photo still looks the same

    // The requirement the whole fix exists to satisfy, stated in the terms a
    // user would: compress a photo that is stored sideways with a "rotate me"
    // tag, and it must still come out looking the way it went in.
    //
    // Deliberately asserted on the RENDERED image rather than on the tag,
    // because the two can disagree in both directions. AVIF carries no
    // orientation tag at all and has to rotate its pixels instead, so a
    // tag-based assertion cannot express the requirement for it; conversely an
    // output that kept the tag *and* rotated its pixels would satisfy every
    // metadata test above while looking wrong on screen.
    @Test(
        "a sideways-stored photo renders the same way up after compression",
        arguments: [OutputFormat.jpeg, .png, .webp, .avif]
    )
    func renderedAppearanceSurvivesCompression(outputFormat: OutputFormat) async throws {
        try requireTooling(for: outputFormat)

        // JPEG source for every case: it is what a phone actually hands over,
        // and the only fixture format that reliably carries orientation in.
        let source = try TestImageFactory.makeMarkerImageWithMetadata(format: .jpeg)
        defer { try? FileManager.default.removeItem(at: source) }

        let before = TestImageFactory.renderedAppearance(of: source)
        // Orientation 6 turns a 160x96 landscape buffer into a portrait photo;
        // if the fixture does not actually read as portrait then the tag never
        // took and this test would be asserting nothing.
        #expect(before.hasPrefix("portrait"))

        let output = try await compress(source, outputFormat: outputFormat)
        defer { try? FileManager.default.removeItem(at: output.url) }

        #expect(TestImageFactory.renderedAppearance(of: output.url) == before)
    }

    // Same requirement, with the resolution slider moved — the path where the
    // compressor's input is an intermediate carrying no metadata at all.
    @Test(
        "a sideways-stored photo renders the same way up after being resized too",
        arguments: [OutputFormat.jpeg, .png, .webp, .avif]
    )
    func renderedAppearanceSurvivesResize(outputFormat: OutputFormat) async throws {
        try requireTooling(for: outputFormat)

        let source = try TestImageFactory.makeMarkerImageWithMetadata(format: .jpeg)
        defer { try? FileManager.default.removeItem(at: source) }

        let before = TestImageFactory.renderedAppearance(of: source)
        let output = try await compress(source, outputFormat: outputFormat, resolutionPercent: 50)
        defer { try? FileManager.default.removeItem(at: output.url) }

        #expect(TestImageFactory.renderedAppearance(of: output.url) == before)
    }

    // MARK: - Helper

    /// Skips a parameterized case when this machine lacks the encoder it
    /// needs, matching the `.enabled(if:)` conditions used on the
    /// single-format tests above. `arguments:` cannot carry a per-case
    /// condition, so the check moves inside.
    private func requireTooling(for outputFormat: OutputFormat) throws {
        switch outputFormat {
        case .png:
            try #require(ToolChecker.pngquantPath != nil, "pngquant not installed")
        case .webp:
            try #require(ToolChecker.cwebpPath != nil, "cwebp not installed")
        case .avif:
            try #require(OutputFormat.avifEncodingSupported, "no AVIF encoder")
        case .same, .jpeg:
            break
        }
    }

    private func compress(
        _ source: URL,
        outputFormat: OutputFormat,
        resolutionPercent: Int = 100
    ) async throws -> CompressionPipeline.Output {
        let file = try #require(ImageFile.load(from: source))
        let settings = CompressionSettings(
            outputFormat: outputFormat,
            resolutionPercent: resolutionPercent,
            quality: 80
        )
        return try await CompressionPipeline.run(
            file: file,
            settings: settings,
            staging: StagingArea.transient()
        )
    }
}
