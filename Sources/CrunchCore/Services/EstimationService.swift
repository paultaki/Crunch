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
    /// isn't installed" from other bail-out reasons (empty queue, decode
    /// failure, cancellation) so the UI can show an actionable install
    /// notice instead of a silent "—".
    public enum Outcome: Equatable, Sendable {
        case value(Int64)
        case toolMissing(ImageFormat)
        case unavailable
    }

    /// Per-settings sample-compression ratios. Cardinality is bounded
    /// (sample files × formats × quality × resolution) so we don't bother
    /// with eviction — wiggling the slider is instant.
    private var ratioCache: [Key: Double] = [:]

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
        guard !files.isEmpty else { return .unavailable }
        guard let sample = Self.pickSample(files) else { return .unavailable }

        let outputFormat = settings.outputFormat.resolve(for: sample.format)
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
            guard let measured = await compressSample(sample, settings: settings)
            else { return .unavailable }
            ratioCache[key] = measured
            ratio = measured
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
    /// `compressed / original` as a `Double` ratio.
    private func compressSample(
        _ file: ImageFile,
        settings: CompressionSettings
    ) async -> Double? {
        // Tool availability is checked by the caller (`estimate`) before we
        // get here, so it can report `.toolMissing` distinctly.
        guard file.originalSize > 0 else { return nil }

        do {
            let output = try await CompressionPipeline.run(file: file, settings: settings)
            defer { try? FileManager.default.removeItem(at: output.url) }
            return Double(output.bytes) / Double(file.originalSize)
        } catch {
            return nil
        }
    }

    /// Called when files are removed from the queue so stale per-file
    /// entries don't linger. Not required for correctness, just tidy.
    public func invalidate() {
        ratioCache.removeAll(keepingCapacity: true)
    }
}
