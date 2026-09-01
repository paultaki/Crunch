import CrunchCore
import Foundation
import Testing

/// Pins the results-summary arithmetic that used to live (untested) in the
/// view model and reported "SAVED 29.7 MB / 100% REDUCTION" for a batch in
/// which every single file failed.
@Suite("BatchSummary")
struct BatchSummaryTests {
    private func succeeded(_ original: Int64, _ compressed: Int64) -> CompressionResult {
        CompressionResult(
            filename: "ok-\(original).jpg",
            originalSize: original,
            compressedSize: compressed,
            error: nil,
            outputURL: URL(fileURLWithPath: "/tmp/ok-\(original).jpg")
        )
    }

    private func failed(_ original: Int64) -> CompressionResult {
        CompressionResult(
            filename: "bad-\(original).jpg",
            originalSize: original,
            compressedSize: nil,
            error: "Cross-device link"
        )
    }

    private func skipped(_ original: Int64) -> CompressionResult {
        CompressionResult(
            filename: "skip-\(original).jpg",
            originalSize: original,
            compressedSize: original,
            error: nil,
            wasSkipped: true,
            outputURL: URL(fileURLWithPath: "/tmp/skip-\(original).jpg")
        )
    }

    @Test("a batch where everything failed saves nothing and is not a success")
    func allFailed() {
        let summary = BatchSummary(results: [failed(1_000), failed(2_000), failed(3_000)])

        #expect(summary.savedBytes == 0)
        #expect(summary.reduction == 0)
        #expect(summary.originalSize == 0)
        #expect(summary.compressedSize == 0)
        #expect(summary.succeededCount == 0)
        #expect(summary.failedCount == 3)
        #expect(summary.skippedCount == 0)
        #expect(summary.totalCount == 3)
        #expect(!summary.hasSuccesses)
        #expect(summary.headline == "0 of 3 compressed, 3 failed")
    }

    @Test("a mixed batch counts only the successes on both sides of the ratio")
    func mixedBatch() {
        // Successes: 1000 → 400 and 1000 → 600, i.e. 2000 → 1000, 50% saved.
        // The two failures carry 10_000 original bytes each; counting those
        // originals against a successes-only compressed total is the exact
        // bug this pins.
        let summary = BatchSummary(results: [
            succeeded(1_000, 400),
            succeeded(1_000, 600),
            skipped(500),
            failed(10_000),
            failed(10_000)
        ])

        #expect(summary.originalSize == 2_500)
        #expect(summary.compressedSize == 1_500)
        #expect(summary.savedBytes == 1_000)
        #expect(summary.reduction == 40)
        #expect(summary.succeededCount == 3)
        #expect(summary.failedCount == 2)
        #expect(summary.skippedCount == 1)
        #expect(summary.hasSuccesses)
        #expect(summary.headline == "3 of 5 compressed, 2 failed")
    }

    @Test("skipped files are successes worth 0% saved, not failures")
    func allSkipped() {
        let summary = BatchSummary(results: [skipped(1_000), skipped(2_000)])

        #expect(summary.originalSize == 3_000)
        #expect(summary.compressedSize == 3_000)
        #expect(summary.savedBytes == 0)
        #expect(summary.reduction == 0)
        #expect(summary.succeededCount == 2)
        #expect(summary.skippedCount == 2)
        #expect(summary.failedCount == 0)
        #expect(summary.hasSuccesses)
        #expect(summary.headline == "2 files compressed")
    }

    @Test("an all-success batch drops the failure clause from the headline")
    func allSucceeded() {
        let summary = BatchSummary(results: [succeeded(1_000, 250)])

        #expect(summary.savedBytes == 750)
        #expect(summary.reduction == 75)
        #expect(summary.failedCount == 0)
        #expect(summary.headline == "1 file compressed")
    }

    @Test("an empty batch is all zeros and divides by nothing")
    func emptyBatch() {
        let summary = BatchSummary(results: [])

        #expect(summary.originalSize == 0)
        #expect(summary.compressedSize == 0)
        #expect(summary.savedBytes == 0)
        #expect(summary.reduction == 0)
        #expect(summary.succeededCount == 0)
        #expect(summary.failedCount == 0)
        #expect(summary.totalCount == 0)
        #expect(!summary.hasSuccesses)
        #expect(summary.headline == "No files compressed")
    }

    @Test("a conversion that grew the file reports a negative reduction, never a fake win")
    func growthIsReportedHonestly() {
        let summary = BatchSummary(results: [succeeded(1_000, 1_500)])

        #expect(summary.reduction == -50)
        // `savedBytes` floors at zero — "saved −500 bytes" is not a phrase.
        #expect(summary.savedBytes == 0)
        #expect(summary.hasSuccesses)
    }
}
