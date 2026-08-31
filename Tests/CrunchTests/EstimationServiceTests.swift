import CrunchCore
import Foundation
import Testing

/// Covers the before/after preview's temp-file lifecycle: `EstimationService`
/// now keeps the sample's compressed temp alive (instead of deleting it
/// immediately) so `ComparePreviewView` has something to load. These tests
/// use JPEG output, which compresses via native ImageIO with no external
/// tool dependency, so they're deterministic in any environment (mirrors
/// `CompressionPipelineTests.jpegPathEndToEnd`).
@Suite("EstimationService")
@MainActor
struct EstimationServiceTests {
    @Test("a successful estimate keeps the compressed sample temp and exposes previewPair")
    func successfulEstimateExposesPreviewPair() async throws {
        let sourceURL = try TestImageFactory.makeSolidPNG(width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let file = try #require(ImageFile.load(from: sourceURL))

        let service = EstimationService()
        let settings = CompressionSettings(outputFormat: .jpeg, resolutionPercent: 100, quality: 80)

        let outcome = await service.estimate(files: [file], settings: settings)

        guard case .value = outcome else {
            Issue.record("expected .value outcome, got \(outcome)")
            return
        }

        let pair = try #require(service.previewPair)
        #expect(pair.original == sourceURL)
        #expect(FileManager.default.fileExists(atPath: pair.compressed.path))

        // Cleanup: invalidate() is the only owner of this temp.
        service.invalidate()
    }

    @Test("invalidate() deletes the kept temp and clears previewPair")
    func invalidateDeletesKeptTempAndClearsPreviewPair() async throws {
        let sourceURL = try TestImageFactory.makeSolidPNG(width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let file = try #require(ImageFile.load(from: sourceURL))

        let service = EstimationService()
        let settings = CompressionSettings(outputFormat: .jpeg, resolutionPercent: 100, quality: 80)
        _ = await service.estimate(files: [file], settings: settings)

        let compressedURL = try #require(service.previewPair).compressed
        #expect(FileManager.default.fileExists(atPath: compressedURL.path))

        service.invalidate()

        #expect(service.previewPair == nil)
        #expect(!FileManager.default.fileExists(atPath: compressedURL.path))
    }

    @Test("a new sample compression deletes the previously kept temp")
    func newCompressionDeletesPreviouslyKeptTemp() async throws {
        let sourceURL = try TestImageFactory.makeSolidPNG(width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let file = try #require(ImageFile.load(from: sourceURL))

        let service = EstimationService()
        let settingsA = CompressionSettings(outputFormat: .jpeg, resolutionPercent: 100, quality: 40)
        let settingsB = CompressionSettings(outputFormat: .jpeg, resolutionPercent: 100, quality: 90)

        _ = await service.estimate(files: [file], settings: settingsA)
        let firstCompressedURL = try #require(service.previewPair).compressed
        #expect(FileManager.default.fileExists(atPath: firstCompressedURL.path))

        _ = await service.estimate(files: [file], settings: settingsB)
        let secondCompressedURL = try #require(service.previewPair).compressed

        #expect(secondCompressedURL != firstCompressedURL)
        #expect(!FileManager.default.fileExists(atPath: firstCompressedURL.path))
        #expect(FileManager.default.fileExists(atPath: secondCompressedURL.path))

        service.invalidate()
    }

    @Test("a ratio cache hit for an evicted key hides the preview instead of recompressing")
    func cacheHitForEvictedKeyHidesPreview() async throws {
        let sourceURL = try TestImageFactory.makeSolidPNG(width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let file = try #require(ImageFile.load(from: sourceURL))

        let service = EstimationService()
        let settingsA = CompressionSettings(outputFormat: .jpeg, resolutionPercent: 100, quality: 40)
        let settingsB = CompressionSettings(outputFormat: .jpeg, resolutionPercent: 100, quality: 90)

        // A: fresh compression, kept temp matches A's key.
        _ = await service.estimate(files: [file], settings: settingsA)
        #expect(service.previewPair != nil)

        // B: fresh compression, kept temp now matches B's key — A's temp is
        // gone.
        _ = await service.estimate(files: [file], settings: settingsB)
        #expect(service.previewPair != nil)

        // Back to A: the ratio is still cached (no recompression), but the
        // kept temp on disk is B's, not A's — per the documented simplest
        // correct behavior, previewPair goes nil rather than recompressing.
        let outcomeA2 = await service.estimate(files: [file], settings: settingsA)
        guard case .value = outcomeA2 else {
            Issue.record("expected .value outcome (cache hit), got \(outcomeA2)")
            return
        }
        #expect(service.previewPair == nil)

        service.invalidate()
    }
}
