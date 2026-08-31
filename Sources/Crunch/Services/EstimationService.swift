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
final class EstimationService {
    struct Key: Hashable {
        let sampleID: UUID
        let outputFormat: OutputFormat
        let quality: Int
        let resolutionPercent: Int
    }

    /// Per-settings sample-compression ratios. Cardinality is bounded
    /// (sample files × formats × quality × resolution) so we don't bother
    /// with eviction — wiggling the slider is instant.
    private var ratioCache: [Key: Double] = [:]

    /// Returns an estimate of the total compressed byte size for `files`
    /// at `settings`, or `nil` if estimation fails (tool missing, decode
    /// failure, cancellation, etc.). Safe to call concurrently — new calls
    /// simply cancel in-flight ones via Swift structured concurrency.
    func estimate(
        files: [ImageFile],
        settings: CompressionSettings
    ) async -> Int64? {
        guard !files.isEmpty else { return nil }
        guard let sample = Self.pickSample(files) else { return nil }

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
            else { return nil }
            ratioCache[key] = measured
            ratio = measured
        }

        let totalOriginal = files.reduce(Int64(0)) { $0 + $1.originalSize }
        return Int64(Double(totalOriginal) * ratio)
    }

    /// Median-by-size file is the most "representative" of a mixed batch —
    /// the first and last are outliers by definition.
    private static func pickSample(_ files: [ImageFile]) -> ImageFile? {
        guard !files.isEmpty else { return nil }
        let sorted = files.sorted { $0.originalSize < $1.originalSize }
        return sorted[sorted.count / 2]
    }

    /// Runs the sample through the real compression pipeline and returns
    /// `compressed / original` as a `Double` ratio.
    private func compressSample(
        _ file: ImageFile,
        settings: CompressionSettings
    ) async -> Double? {
        let outputFormat = settings.outputFormat.resolve(for: file.format)
        let quality = settings.quality
        let resolutionPercent = settings.resolutionPercent

        // Bail early if the compressor this sample needs isn't installed.
        if ToolChecker.missingTools(for: [outputFormat]) != nil {
            return nil
        }

        let resize: (Int, Int)?
        if resolutionPercent < 100 {
            resize = file.resizedDimensions(percent: resolutionPercent)
        } else {
            resize = nil
        }

        let tempDir = FileManager.default.temporaryDirectory
        let tempOutput = tempDir
            .appendingPathComponent("crunch-estimate-\(UUID().uuidString).\(outputFormat.fileExtension)")

        // Single cleanup site for both the output temp and any resize temp.
        var resizedTemp: URL?
        defer {
            try? FileManager.default.removeItem(at: tempOutput)
            if let resizedTemp { try? FileManager.default.removeItem(at: resizedTemp) }
        }

        do {
            // WebP uses cwebp's built-in resize; every other format routes
            // through ImageResizer. Mirrors the logic in
            // CompressionViewModel.compressSingleFile so ratios stay honest.
            let needsManualResize = resize != nil && outputFormat != .webp
            let compressionInput: URL
            if needsManualResize, let resize {
                let resized = try await ImageResizer.resize(
                    input: file.url,
                    width: resize.0,
                    height: resize.1
                )
                resizedTemp = resized
                compressionInput = resized
            } else {
                compressionInput = file.url
            }

            switch outputFormat {
            case .png:
                try await PNGCompressor.compress(
                    input: compressionInput,
                    output: tempOutput,
                    quality: quality
                )
            case .jpeg:
                try await JPEGCompressor.compress(
                    input: compressionInput,
                    output: tempOutput,
                    quality: quality
                )
            case .webp:
                try await WebPCompressor.compress(
                    input: compressionInput,
                    output: tempOutput,
                    quality: quality,
                    resize: resize
                )
            }

            let compressedSize = (try? tempOutput.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .flatMap { Int64($0) } ?? 0

            guard file.originalSize > 0 else { return nil }
            return Double(compressedSize) / Double(file.originalSize)
        } catch {
            return nil
        }
    }

    /// Called when files are removed from the queue so stale per-file
    /// entries don't linger. Not required for correctness, just tidy.
    func invalidate() {
        ratioCache.removeAll(keepingCapacity: true)
    }
}
