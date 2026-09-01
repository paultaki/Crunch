import CrunchCore
import Foundation
import Testing

/// `CompressionJob` is the step that actually touches the user's data, and
/// until now nothing tested it directly. These cover the cleanup contract on
/// all three exits — success, never-worse skip, throw — because the staging
/// file is a real image and a leak means a stray file in the user's album.
///
/// JPEG throughout so the tests are deterministic anywhere: it encodes via
/// native ImageIO with no pngquant/cwebp dependency.
///
/// Note what these do NOT pin. They inspect the folder after `run` has
/// returned and cleaned up, so they stay green whether staging went to the
/// right place or the wrong one. The staging *choice* is pinned two other
/// ways instead: `StagingAreaTests` proves a reservation for a destination is
/// same-volume and outside the destination's folder, and
/// `CompressionPipeline.run` takes a `StagingArea.Reservation` rather than a
/// `URL`, so handing it a bare directory doesn't compile.
///
/// `.serialized` because the residue check below scans the volume's shared
/// replacement directories for our staging prefix. Run in parallel, these
/// tests see each other's in-flight staging files and report a leak that
/// isn't one. No other suite creates them, so serializing this one is enough.
@Suite("CompressionJob", .serialized)
@MainActor
struct CompressionJobTests {
    /// Writes a JPEG of a known quality into `directory` and returns it.
    /// Built through the real pipeline so the fixture and the code under test
    /// agree on what a JPEG of that quality looks like.
    private func makeJPEG(in directory: URL, named name: String, quality: Int) async throws -> URL {
        let pngURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("crunch-fixture-\(UUID().uuidString).png")
        try TestImageFactory.writeNoisyPNG(to: pngURL, width: 256, height: 256)
        defer { try? FileManager.default.removeItem(at: pngURL) }

        let source = try #require(ImageFile.load(from: pngURL))
        let output = try await CompressionPipeline.run(
            file: source,
            settings: CompressionSettings(
                outputFormat: .jpeg,
                resolutionPercent: 100,
                quality: quality
            ),
            staging: StagingArea.transient()
        )

        let jpegURL = directory.appendingPathComponent(name)
        try FileManager.default.moveItem(at: output.url, to: jpegURL)
        return jpegURL
    }

    private func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crunch-job-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func contents(of directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    /// Any staging file left anywhere it could plausibly land: the user's own
    /// folder (the fallback rung) and the volume's replacement directories
    /// (the normal rung). Scanning for our `.crunch-` prefix rather than
    /// counting `NSIRD_*` directories keeps this immune to other processes
    /// creating replacement directories while the suite runs.
    private func strayStagingFiles(userFolder: URL) -> [String] {
        let fm = FileManager.default
        var stray = contents(of: userFolder).filter { $0.hasPrefix(".crunch-") }

        let replacementRoot = fm.temporaryDirectory.appendingPathComponent("TemporaryItems")
        for entry in contents(of: replacementRoot) {
            let nested = replacementRoot.appendingPathComponent(entry)
            stray += contents(of: nested)
                .filter { $0.hasPrefix(".crunch-") }
                .map { "\(entry)/\($0)" }
        }
        return stray
    }

    private func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1)
    }

    @Test("a successful in-place compression shrinks the file and leaves no staging file behind")
    func successLeavesNoResidue() async throws {
        let folder = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = try await makeJPEG(in: folder, named: "photo.jpg", quality: 95)
        let before = size(of: source)
        let file = try #require(ImageFile.load(from: source))

        let result = await CompressionJob.run(
            file: file,
            settings: CompressionSettings(outputFormat: .same, resolutionPercent: 100, quality: 30),
            destination: source
        )

        #expect(result.error == nil)
        #expect(!result.wasSkipped)
        #expect(size(of: source) < before)
        #expect(size(of: source) > 0)
        #expect(contents(of: folder) == ["photo.jpg"])
        #expect(strayStagingFiles(userFolder: folder).isEmpty)
    }

    @Test("a never-worse skip leaves the original untouched and no staging file behind")
    func skipLeavesNoResidue() async throws {
        let folder = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        // Already heavily compressed, so re-encoding at q95 can only grow it.
        let source = try await makeJPEG(in: folder, named: "photo.jpg", quality: 20)
        let before = size(of: source)
        let file = try #require(ImageFile.load(from: source))

        let result = await CompressionJob.run(
            file: file,
            settings: CompressionSettings(outputFormat: .same, resolutionPercent: 100, quality: 95),
            destination: source
        )

        #expect(result.wasSkipped)
        #expect(result.error == nil)
        #expect(size(of: source) == before)
        #expect(contents(of: folder) == ["photo.jpg"])
        #expect(strayStagingFiles(userFolder: folder).isEmpty)
    }

    @Test("a failed compression leaves the folder exactly as it found it")
    func failureLeavesNoResidue() async throws {
        let folder = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("photo.png")
        try TestImageFactory.writeNoisyPNG(to: source, width: 64, height: 64)
        let file = try #require(ImageFile.load(from: source))

        // Corrupt it after loading so the decode fails inside the pipeline,
        // which is the throw path we need to exercise.
        try Data(repeating: 0, count: 128).write(to: source)

        let result = await CompressionJob.run(
            file: file,
            settings: CompressionSettings(outputFormat: .jpeg, resolutionPercent: 100, quality: 80),
            destination: folder.appendingPathComponent("photo.jpg")
        )

        #expect(result.error != nil)
        #expect(result.compressedSize == nil)
        #expect(contents(of: folder) == ["photo.png"])
        #expect(strayStagingFiles(userFolder: folder).isEmpty)
    }
}
