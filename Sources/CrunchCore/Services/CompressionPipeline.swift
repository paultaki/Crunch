import Foundation

/// The single resize → compress orchestration shared by the real compression
/// run (`CompressionViewModel`) and the sample-based size estimator
/// (`EstimationService`), so both stay behavior-identical by construction —
/// a fix to resize or format handling here fixes both call sites at once.
public enum CompressionPipeline {
    public struct Output: Sendable {
        /// Temp file holding the compressed result. Caller owns moving or
        /// deleting it — the pipeline never touches it once returned.
        public let url: URL
        public let bytes: Int64
    }

    /// Compresses `file` per `settings` into a temp file inside
    /// `stagingDirectory` and returns it.
    ///
    /// `stagingDirectory` is not a convenience knob: `replaceItemAt` and
    /// `moveItem` are only guaranteed to be atomic within a single volume,
    /// so a caller that delivers the output onto a user file MUST stage it
    /// in that file's own directory. Staging in
    /// `FileManager.default.temporaryDirectory` (the boot volume) made every
    /// delivery onto an external drive or network share fail with POSIX 18,
    /// "Cross-device link". Callers that only measure the output and throw it
    /// away (`EstimationService`) pass the system temp directory instead, so
    /// they don't litter the user's folder.
    ///
    /// The pipeline never reads or writes `file.url` itself beyond decoding
    /// it — callers are responsible for moving the returned temp into place
    /// or deleting it. All intermediate temps (e.g. a resize pass) are
    /// cleaned up here via `defer`, on both success and throw; the returned
    /// `Output` temp is cleaned up on throw too (there's no way for the
    /// caller to reach it), but left in place on success for the caller to
    /// own.
    public static func run(
        file: ImageFile,
        settings: CompressionSettings,
        stagingDirectory: URL
    ) async throws -> Output {
        let outputFormat = settings.outputFormat.resolve(for: file.format)
        let quality = settings.quality
        let resolutionPercent = settings.resolutionPercent

        let resize: (Int, Int)?
        if resolutionPercent < 100 {
            resize = file.resizedDimensions(percent: resolutionPercent)
        } else {
            resize = nil
        }

        // Dot-prefixed on purpose. For a real compression run this file
        // briefly exists in the user's own folder, and a visible stray
        // `crunch-<uuid>.jpg` sitting next to their photos is alarming (and
        // would show up in a screen recording).
        let tempOutput = stagingDirectory
            .appendingPathComponent(".crunch-\(UUID().uuidString).\(outputFormat.fileExtension)")

        // Prove up front that we can write there, and fail with a message
        // naming the folder if we can't (read-only folder, permissions).
        // There is deliberately NO fallback to staging elsewhere and copying
        // across the volume boundary: the temp-then-atomic-replace design is
        // the whole reason a crash can never leave a half-written original,
        // and that guarantee is not worth trading for a file that compresses.
        //
        // The probe file is removed again rather than left as a placeholder,
        // so a compressor that exits cleanly without writing anything still
        // fails the size check below instead of producing a 0-byte "output"
        // that would sail past the caller's never-worse guard.
        guard FileManager.default.createFile(atPath: tempOutput.path, contents: nil) else {
            throw CompressionError.cannotStageOutput(stagingDirectory.lastPathComponent)
        }
        try? FileManager.default.removeItem(at: tempOutput)

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
        case .avif:
            try await AVIFCompressor.compress(
                input: compressionInput,
                output: tempOutput,
                quality: quality
            )
        }

        // A missing size must fail, never default to 0. Zero bytes reads as a
        // 100%-saved success to every caller, which would defeat the
        // never-worse guard (`0 >= originalSize` is false) and let a bogus
        // temp replace the user's file.
        guard let fileSize = try tempOutput.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw CompressionError.cannotWriteImage(tempOutput.lastPathComponent)
        }
        let bytes = Int64(fileSize)

        succeeded = true
        return Output(url: tempOutput, bytes: bytes)
    }
}
