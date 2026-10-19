import Foundation

enum PNGCompressor {
    /// Runs pngquant on the input file, writing a quantized PNG to `output`.
    ///
    /// pngquant only accepts PNG input (it relies on libpng to decode). When
    /// the caller hands us a JPEG, WebP, or anything else, we transparently
    /// re-encode the source to a temporary PNG first via `ImageNormalizer`
    /// and feed that to pngquant. The temp file is cleaned up before
    /// returning.
    ///
    /// `metadata` is the user's ORIGINAL metadata, written back onto the
    /// finished file by `PNGMetadataWriter` rather than passed to pngquant,
    /// which strips metadata by default on macOS and offers no way to stop
    /// it. That post-pass is also what makes stripping honest here: pngquant
    /// alone drops the EXIF but leaves the XMP packet, capture date and GPS
    /// included.
    static func compress(
        input: URL,
        output: URL,
        quality: Int,
        metadata: ImageMetadata?
    ) async throws {
        guard let pngquant = ToolChecker.pngquantPath else {
            throw CompressionError.toolMissing("pngquant")
        }

        let needsNormalization = input.pathExtension.lowercased() != "png"
        // No metadata needed in the substitute: unlike cwebp, pngquant never
        // carries it through anyway, so it is applied to the output below.
        let pngInput: URL = try needsNormalization
            ? ImageNormalizer.encodeAsPNG(from: input, metadata: nil)
            : input
        defer {
            if needsNormalization {
                try? FileManager.default.removeItem(at: pngInput)
            }
        }

        let minQuality = max(0, quality - 5)
        let qualityRange = "\(minQuality)-\(quality)"

        let result = try await ShellRunner.run(
            pngquant,
            arguments: [
                "--quality", qualityRange,
                "--force",
                "--output", output.path,
                pngInput.path
            ]
        )

        // pngquant exits 99 when it can't reach the requested quality.
        // Retry with the full range so the user still gets output.
        if result.exitCode == 99 {
            let retry = try await ShellRunner.run(
                pngquant,
                arguments: [
                    "--quality", "0-100",
                    "--force",
                    "--output", output.path,
                    pngInput.path
                ]
            )
            guard retry.exitCode == 0 else {
                throw ShellError.executionFailed(
                    command: "pngquant",
                    exitCode: retry.exitCode,
                    stderr: retry.stderr
                )
            }
            try PNGMetadataWriter.apply(metadata, to: output)
            return
        }

        guard result.exitCode == 0 else {
            throw ShellError.executionFailed(
                command: "pngquant",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }

        try PNGMetadataWriter.apply(metadata, to: output)
    }
}
