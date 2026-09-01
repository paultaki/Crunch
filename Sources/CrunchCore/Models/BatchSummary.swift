import Foundation

/// The arithmetic behind the results screen's summary: how much a finished
/// batch actually saved, and how many files each outcome accounts for.
///
/// It lives in CrunchCore rather than in the view model because the bug it
/// exists to prevent shipped for exactly that reason. The totals used to be
/// computed with `compactMap(\.compressedSize)`, which *drops* failures
/// instead of excluding them: a batch where all 11 files failed summed to 0
/// compressed bytes against 11 files' worth of originals and rendered as
/// "SAVED 29.7 MB / 100% REDUCTION". Math that decides what the user is told
/// about their files belongs where tests can reach it — same reasoning as
/// `OutputDestinationPlanner`.
public struct BatchSummary: Equatable, Sendable {
    /// Original bytes of the succeeded results only. Both sides of the ratio
    /// are drawn from the same filtered set; pairing a whole-batch original
    /// against a successes-only compressed total is precisely what produced
    /// the phantom savings above.
    public let originalSize: Int64
    public let compressedSize: Int64
    public let savedBytes: Int64
    /// Percent saved across the succeeded results, 0 when nothing succeeded.
    public let reduction: Double
    /// Files that ended up on disk as intended — including never-worse skips,
    /// which are honest successes that happened to save nothing.
    public let succeededCount: Int
    public let failedCount: Int
    /// Subset of `succeededCount` left untouched by the never-worse guard.
    public let skippedCount: Int

    public var totalCount: Int { succeededCount + failedCount }

    /// False when the batch produced nothing, so the UI can drop the
    /// celebratory green framing instead of reporting a 0% win.
    public var hasSuccesses: Bool { succeededCount > 0 }

    public init(results: [CompressionResult]) {
        // Paired up front so the two sides of the ratio cannot drift apart:
        // a result contributes both of its numbers or neither.
        let sizes = results.compactMap { result -> (original: Int64, compressed: Int64)? in
            guard let compressed = result.compressedSize else { return nil }
            return (result.originalSize, compressed)
        }

        let original = sizes.reduce(Int64(0)) { $0 + $1.original }
        let compressed = sizes.reduce(Int64(0)) { $0 + $1.compressed }

        originalSize = original
        compressedSize = compressed
        savedBytes = max(0, original - compressed)
        reduction = original > 0
            ? Double(original - compressed) / Double(original) * 100
            : 0
        succeededCount = sizes.count
        failedCount = results.count - sizes.count
        skippedCount = results.filter { $0.succeeded && $0.wasSkipped }.count
    }

    /// Results-header copy. Reports failures explicitly rather than counting
    /// every attempted file as "compressed"; the failure clause disappears
    /// when there is nothing to confess.
    public var headline: String {
        guard totalCount > 0 else { return "No files compressed" }
        guard failedCount > 0 else {
            return "\(succeededCount) file\(succeededCount == 1 ? "" : "s") compressed"
        }
        return "\(succeededCount) of \(totalCount) compressed, \(failedCount) failed"
    }
}
