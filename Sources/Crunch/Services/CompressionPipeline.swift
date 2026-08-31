import Foundation

/// The single resize → compress orchestration shared by the real compression
/// run (`CompressionViewModel`) and the sample-based size estimator
/// (`EstimationService`), so both stay behavior-identical by construction —
/// a fix to resize or format handling here fixes both call sites at once.
enum CompressionPipeline {
    struct Output: Sendable {
        /// Temp file holding the compressed result. Caller owns moving or
        /// deleting it — the pipeline never touches it once returned.
        let url: URL
        let bytes: Int64
    }

    /// Compresses `file` per `settings` into a temp file and returns it.
    ///
    /// The pipeline never reads or writes `file.url` itself beyond decoding
    /// it — callers are responsible for moving the returned temp into place
    /// or deleting it. All intermediate temps (e.g. a resize pass) are
    /// cleaned up here via `defer`, on both success and throw; the returned
    /// `Output` temp is cleaned up on throw too (there's no way for the
    /// caller to reach it), but left in place on success for the caller to
    /// own.
    static func run(file: ImageFile, settings: CompressionSettings) async throws -> Output {
        let outputFormat = settings.outputFormat.resolve(for: file.format)
        let quality = settings.quality
        let resolutionPercent = settings.resolutionPercent

        let resize: (Int, Int)?
        if resolutionPercent < 100 {
            resize = file.resizedDimensions(percent: resolutionPercent)
        } else {
            resize = nil
        }

        let tempOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("crunch-\(UUID().uuidString).\(outputFormat.fileExtension)")

        var resizedTemp: URL?
        var succeeded = false
        defer {
            if let resizedTemp {
                try? FileManager.default.removeItem(at: resizedTemp)
            }
            if !succeeded {
                try? FileManager.default.removeItem(at: tempOutput)
            }
        }

        // cwebp resizes natively; every other output format resizes via
        // ImageResizer first, which always emits a lossless PNG regardless
        // of source format (see ImageResizer.resize doc comment for why).
        let needsManualResize = resize != nil && outputFormat != .webp
        let compressionInput: URL
        if needsManualResize, let resize {
            let resized = try await ImageResizer.resize(
                input: file.url,
                width: resize.0,
                height: resize.1,
                outputFormat: outputFormat
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

        let bytes = (try? tempOutput.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .flatMap { Int64($0) } ?? 0

        succeeded = true
        return Output(url: tempOutput, bytes: bytes)
    }
}
