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
    /// so a caller that delivers the output onto a user file MUST hand in a
    /// directory on that file's volume — see `StagingArea`, which picks one.
    /// Staging in `FileManager.default.temporaryDirectory` (the boot volume)
    /// made every delivery onto an external drive or network share fail with
    /// POSIX 18, "Cross-device link". Callers that only measure the output
    /// and throw it away (`EstimationService`) pass the system temp
    /// directory, which needs no such guarantee.
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

        // Dot-prefixed on purpose. `StagingArea` normally hands us a private
        // directory nobody looks at, but its fallback rung is the user's own
        // folder, and a visible stray `crunch-<uuid>.jpg` sitting next to
        // their photos is alarming (and would show up in a screen recording).
        // Uniform across both rungs because one naming rule is simpler than
        // two.
        let tempOutput = stagingDirectory
            .appendingPathComponent(".crunch-\(UUID().uuidString).\(outputFormat.fileExtension)")

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

        let bytes = try outputSize(of: tempOutput, sourceName: file.filename)

        succeeded = true
        return Output(url: tempOutput, bytes: bytes)
    }

    /// Byte size of a finished compression output, rejecting both of the ways
    /// a compressor can look like it succeeded while producing nothing
    /// usable: no file at all, and an empty file.
    ///
    /// Zero is the dangerous one, and it is not hypothetical — `.fileSize` on
    /// an empty file returns `Optional(0)`, not `nil`, so a plain `guard let`
    /// unwraps it happily. Downstream, 0 bytes reads as a 100%-saved success
    /// to everything: `CompressionJob`'s never-worse guard compares
    /// `0 >= originalSize`, which is false for any real photo, so the empty
    /// file would be delivered onto the user's original and `BatchSummary`
    /// would report it as a total win.
    ///
    /// `sourceName` is the user's filename rather than the internal staging
    /// name, because that is what an error message has to be about.
    ///
    /// Public so this guard can be tested directly. Reaching it through the
    /// pipeline would mean adding a fake-compressor injection seam to
    /// production code for no other reason, which costs more than it buys.
    public static func outputSize(of url: URL, sourceName: String) throws -> Int64 {
        // `try?` on purpose: a missing file and an empty file are the same
        // failure to the user, and both deserve the message naming their
        // file rather than a raw Cocoa "couldn't be opened" for one and a
        // clear message for the other.
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard let fileSize, fileSize > 0 else {
            throw CompressionError.cannotWriteImage(sourceName)
        }
        return Int64(fileSize)
    }
}
