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
        arguments: MetadataPreservationTests.encodableFormats
    )
    func renderedAppearanceSurvivesCompression(outputFormat: OutputFormat) async throws {
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
        arguments: MetadataPreservationTests.encodableFormats
    )
    func renderedAppearanceSurvivesResize(outputFormat: OutputFormat) async throws {
        let source = try TestImageFactory.makeMarkerImageWithMetadata(format: .jpeg)
        defer { try? FileManager.default.removeItem(at: source) }

        let before = TestImageFactory.renderedAppearance(of: source)
        let output = try await compress(source, outputFormat: outputFormat, resolutionPercent: 50)
        defer { try? FileManager.default.removeItem(at: output.url) }

        #expect(TestImageFactory.renderedAppearance(of: output.url) == before)
    }

    // And with metadata stripped on purpose, which must cost the photo its
    // history and not its orientation.
    @Test(
        "a sideways-stored photo renders the same way up even when stripped",
        arguments: MetadataPreservationTests.encodableFormats
    )
    func renderedAppearanceSurvivesStripping(outputFormat: OutputFormat) async throws {
        let source = try TestImageFactory.makeMarkerImageWithMetadata(format: .jpeg)
        defer { try? FileManager.default.removeItem(at: source) }

        let before = TestImageFactory.renderedAppearance(of: source)
        let output = try await compress(source, outputFormat: outputFormat, stripMetadata: true)
        defer { try? FileManager.default.removeItem(at: output.url) }

        #expect(TestImageFactory.renderedAppearance(of: output.url) == before)
        #expect(TestImageFactory.readMetadata(from: output.url).hasNoIdentifyingData)
    }

    // MARK: - Stripping on purpose

    // The other half of the feature. Removing GPS before publishing a photo
    // is a legitimate thing to want; the bug was doing it to everyone, always,
    // without asking. These tests pin that the toggle actually reaches every
    // encoder — each one disables metadata by a different mechanism, so a
    // single format passing proves nothing about the others.
    @Test("stripping removes everything from JPEG output")
    func jpegStripsMetadata() async throws {
        let source = try TestImageFactory.makeImageWithMetadata(format: .jpeg)
        defer { try? FileManager.default.removeItem(at: source) }

        let output = try await compress(source, outputFormat: .jpeg, stripMetadata: true)
        defer { try? FileManager.default.removeItem(at: output.url) }

        let metadata = TestImageFactory.readMetadata(from: output.url)
        #expect(metadata.hasNoIdentifyingData)
        // ...but still the right way up. Stripping is about identifying
        // information, not about handing back a sideways photo.
        #expect(metadata.orientation == TestMetadata.orientation)
    }

    // Worth its own test because pngquant does NOT strip completely on its
    // own: it drops the EXIF but leaves the XMP packet, which still carries
    // capture date and GPS. Stripping has to remove that too, or "Strip
    // metadata" would quietly leak a photo's location.
    @Test(
        "stripping removes everything from PNG output, XMP packet included",
        .enabled(if: ToolChecker.pngquantPath != nil)
    )
    func pngStripsMetadata() async throws {
        let source = try TestImageFactory.makeImageWithMetadata(format: .png)
        defer { try? FileManager.default.removeItem(at: source) }

        let output = try await compress(source, outputFormat: .png, stripMetadata: true)
        defer { try? FileManager.default.removeItem(at: output.url) }

        let metadata = TestImageFactory.readMetadata(from: output.url)
        #expect(metadata.hasNoIdentifyingData)
        #expect(metadata.orientation == TestMetadata.orientation)
        // Still a valid PNG of the right size after the chunks came out.
        let reloaded = try #require(ImageFile.load(from: output.url))
        #expect(reloaded.pixelWidth == 160)
    }

    @Test(
        "stripping removes everything from WebP output",
        .enabled(if: ToolChecker.cwebpPath != nil)
    )
    func webpStripsMetadata() async throws {
        let source = try TestImageFactory.makeImageWithMetadata(format: .png)
        defer { try? FileManager.default.removeItem(at: source) }

        let output = try await compress(source, outputFormat: .webp, stripMetadata: true)
        defer { try? FileManager.default.removeItem(at: output.url) }

        // The awkward one: cwebp copies metadata wholesale or not at all, so
        // keeping orientation while dropping GPS means re-embedding the
        // reduced set into a substitute input rather than passing a flag.
        let metadata = TestImageFactory.readMetadata(from: output.url)
        #expect(metadata.hasNoIdentifyingData)
        #expect(metadata.orientation == TestMetadata.orientation)
    }

    @Test(
        "stripping removes everything from AVIF output",
        .enabled(if: OutputFormat.avifEncodingSupported)
    )
    func avifStripsMetadata() async throws {
        let source = try TestImageFactory.makeImageWithMetadata(format: .avif)
        defer { try? FileManager.default.removeItem(at: source) }

        let output = try await compress(source, outputFormat: .avif, stripMetadata: true)
        defer { try? FileManager.default.removeItem(at: output.url) }

        #expect(TestImageFactory.readMetadata(from: output.url).hasNoIdentifyingData)
    }

    // Stripping must not also throw away the user's orientation *correction*
    // on AVIF. The tag cannot be written to AVIF at all, so if the pixels are
    // not rotated the photo is wrong on screen — which is a visual defect, not
    // a privacy choice. Stripping is about identifying information.
    @Test(
        "stripping an AVIF still leaves the photo the right way up",
        .enabled(if: OutputFormat.avifEncodingSupported)
    )
    func avifStripKeepsPhotoUpright() async throws {
        let source = try TestImageFactory.makeImageWithMetadata(format: .jpeg)
        defer { try? FileManager.default.removeItem(at: source) }

        let output = try await compress(source, outputFormat: .avif, stripMetadata: true)
        defer { try? FileManager.default.removeItem(at: output.url) }

        let metadata = TestImageFactory.readMetadata(from: output.url)
        #expect(metadata.hasNoIdentifyingData)
        #expect(metadata.pixelWidth == 96)
        #expect(metadata.pixelHeight == 160)
    }

    // MARK: - Helper

    /// The output formats this machine can actually produce, used as the
    /// `arguments:` of the parameterized tests above so an unavailable
    /// encoder yields no case at all.
    ///
    /// This replaced a guard inside the test bodies that called
    /// `#require(ToolChecker.pngquantPath != nil)` and friends. That looked
    /// like the `.enabled(if:)` conditions on the single-format tests but is
    /// not equivalent: `#require` RECORDS AN ISSUE and throws, it does not
    /// skip. Locally every encoder is installed so all four cases passed; on
    /// CI, where pngquant is absent and ImageIO cannot encode AVIF, the same
    /// guard turned two unavailable formats into six red tests. Filtering the
    /// arguments is the only way to express "do not run this case" for a
    /// parameterized test — Swift Testing has no runtime skip.
    ///
    /// JPEG is unconditional: ImageIO encodes it everywhere, no external tool.
    static let encodableFormats: [OutputFormat] = {
        var formats: [OutputFormat] = [.jpeg]
        if ToolChecker.pngquantPath != nil { formats.append(.png) }
        if ToolChecker.cwebpPath != nil { formats.append(.webp) }
        if OutputFormat.avifEncodingSupported { formats.append(.avif) }
        return formats
    }()

    private func compress(
        _ source: URL,
        outputFormat: OutputFormat,
        resolutionPercent: Int = 100,
        stripMetadata: Bool = false
    ) async throws -> CompressionPipeline.Output {
        let file = try #require(ImageFile.load(from: source))
        let settings = CompressionSettings(
            outputFormat: outputFormat,
            resolutionPercent: resolutionPercent,
            quality: 80,
            stripMetadata: stripMetadata
        )
        return try await CompressionPipeline.run(
            file: file,
            settings: settings,
            staging: StagingArea.transient()
        )
    }
}
