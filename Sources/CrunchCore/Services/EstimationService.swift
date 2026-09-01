import Foundation

/// Predicts the total compressed output size for a batch by actually running
/// a representative sample file through the *same* compression pipeline used
/// for the real "Compress" button, then extrapolating the resulting ratio to
/// the rest of the queue.
///
/// Reusing the production compressors (`PNGCompressor`, `JPEGCompressor`,
/// `WebPCompressor`) is deliberate — it guarantees the estimate tracks any
/// fixes to the real pipeline without drift.
@MainActor
public final class EstimationService {
    struct Key: Hashable {
        let sampleID: UUID
        let outputFormat: OutputFormat
        let quality: Int
        let resolutionPercent: Int
    }

    /// Result of an estimate attempt. Distinguishes "the required compressor
    /// isn't installed" and "this format can't be encoded on this Mac at
    /// all" from other bail-out reasons (empty queue, decode failure,
    /// cancellation) so the UI can show an actionable notice instead of a
    /// silent "—".
    public enum Outcome: Equatable, Sendable {
        case value(Int64)
        case toolMissing(ImageFormat)
        case formatUnsupported(ImageFormat)
        case unavailable
    }

    /// Per-settings sample-compression ratios. Cardinality is bounded
    /// (sample files × formats × quality × resolution) so we don't bother
    /// with eviction — wiggling the slider is instant.
    private var ratioCache: [Key: Double] = [:]

    /// The compressed sample temp file kept alive for the before/after
    /// preview, paired with the settings `Key` it was produced under.
    /// Replaced — deleting the previous compressed temp — every time a NEW
    /// sample compression actually runs (a `ratioCache` *miss*). A cache
    /// *hit* reuses the cached ratio without recompressing, so it leaves
    /// this untouched; see `previewPair` below for what that means for the
    /// preview button when settings are dialed back to an older value.
    private var keptSample: (key: Key, compressedURL: URL)?

    /// Original/compressed URL pair for the sample behind the most recent
    /// `estimate()` call's result, or `nil` if no matching compressed temp
    /// is currently on disk — e.g. estimation is still running, the sample
    /// is unavailable, or (rare) the caller re-requested settings whose
    /// ratio was cache-hit from an earlier run whose temp has since been
    /// evicted by a newer sample compression.
    ///
    /// That last case is deliberately NOT backfilled by recompressing: the
    /// ratio cache exists precisely so revisiting old settings is free, and
    /// spending a full sample compression just to keep the Preview button
    /// visible would defeat that. Simplest correct behavior: the button
    /// hides for that one settings value until it's the most recent
    /// compression again (e.g. the user nudges the slider back).
    public private(set) var previewPair: (original: URL, compressed: URL)?

    public init() {}

    /// Returns an estimate of the total compressed byte size for `files`
    /// at `settings`, or an `.unavailable`/`.toolMissing` outcome if
    /// estimation can't run (decode failure, cancellation, missing
    /// compressor, etc.). Safe to call concurrently — new calls simply
    /// cancel in-flight ones via Swift structured concurrency.
    public func estimate(
        files: [ImageFile],
        settings: CompressionSettings
    ) async -> Outcome {
        // Cleared up front and only re-set on a successful `.value` result
        // below — every early-return path (empty queue, no sample, missing
        // tool, unsupported format, decode failure) means "no preview to
        // show right now".
        previewPair = nil

        guard !files.isEmpty else { return .unavailable }
        guard let sample = Self.pickSample(files) else { return .unavailable }

        let outputFormat = settings.outputFormat.resolve(for: sample.format)

        // Checked before the tool-missing branch (and before ever calling
        // into the pipeline) for the same reason `.toolMissing` is: so the
        // UI gets a distinct, actionable outcome instead of the sample
        // compression throwing and collapsing into a bare `.unavailable`
        // "—". Mirrors AVIFCompressor's own guard, which exists for the
        // real compress-run path.
        if outputFormat == .avif, !OutputFormat.avifEncodingSupported {
            return .formatUnsupported(.avif)
        }
        if ToolChecker.missingTools(for: [outputFormat]) != nil {
            return .toolMissing(outputFormat)
        }

        let key = Key(
            sampleID: sample.id,
            outputFormat: settings.outputFormat,
            quality: settings.quality,
            resolutionPercent: settings.resolutionPercent
        )

        let ratio: Double
        if let cached = ratioCache[key] {
            ratio = cached
        } else {
            guard let measured = await compressSample(sample, settings: settings, key: key)
            else { return .unavailable }
            ratioCache[key] = measured
            ratio = measured
        }

        if let keptSample, keptSample.key == key {
            previewPair = (original: sample.url, compressed: keptSample.compressedURL)
        }

        let totalOriginal = files.reduce(Int64(0)) { $0 + $1.originalSize }
        return .value(Int64(Double(totalOriginal) * ratio))
    }

    /// Median-by-size file is the most "representative" of a mixed batch —
    /// the first and last are outliers by definition.
    private static func pickSample(_ files: [ImageFile]) -> ImageFile? {
        guard !files.isEmpty else { return nil }
        let sorted = files.sorted { $0.originalSize < $1.originalSize }
        return sorted[sorted.count / 2]
    }

    /// Runs the sample through the real compression pipeline (shared with
    /// `CompressionViewModel` via `CompressionPipeline`) and returns
    /// `compressed / original` as a `Double` ratio. Unlike the old
    /// delete-immediately behavior, the compressed temp is kept alive
    /// (`keptSample`) for the before/after preview — the previous kept temp
    /// (if any, under a different key) is deleted first so at most one
    /// lingers on disk at a time.
    private func compressSample(
        _ file: ImageFile,
        settings: CompressionSettings,
        key: Key
    ) async -> Double? {
        // Tool availability is checked by the caller (`estimate`) before we
        // get here, so it can report `.toolMissing` distinctly.
        guard file.originalSize > 0 else { return nil }

        do {
            // Transient, not same-volume: this output is only ever measured
            // and (eventually) deleted, never moved onto a user file, so it
            // needs no atomicity guarantee — and staging it next to the
            // user's photos would drop a file in their folder on every
            // quality-slider wiggle.
            let output = try await CompressionPipeline.run(
                file: file,
                settings: settings,
                staging: StagingArea.transient()
            )
            if let previous = keptSample {
                try? FileManager.default.removeItem(at: previous.compressedURL)
            }
            keptSample = (key: key, compressedURL: output.url)
            return Double(output.bytes) / Double(file.originalSize)
        } catch {
            return nil
        }
    }

    /// Called when files are removed from the queue, settings invalidate
    /// the cache, or the batch is cleared/reset, so stale per-file entries
    /// don't linger — also deletes the kept preview temp, since it no
    /// longer corresponds to anything the UI can show.
    ///
    /// App-exit cleanup: the kept temp lives under
    /// `FileManager.temporaryDirectory`, which macOS periodically reaps on
    /// its own, so there's no `atexit`/deinit handler here for the case
    /// where the app quits with a kept temp still on disk.
    public func invalidate() {
        ratioCache.removeAll(keepingCapacity: true)
        if let keptSample {
            try? FileManager.default.removeItem(at: keptSample.compressedURL)
        }
        keptSample = nil
        previewPair = nil
    }
}
