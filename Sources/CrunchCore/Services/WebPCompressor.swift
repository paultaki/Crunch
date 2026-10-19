import Foundation

enum WebPCompressor {
    /// Runs cwebp on the input file, writing a WebP to `output`.
    ///
    /// cwebp decodes only a short list of formats (PNG, JPEG, TIFF, WebP).
    /// Anything else — AVIF in practice — is re-encoded to a temporary
    /// lossless PNG first, same as `PNGCompressor` does for pngquant, and the
    /// temp is cleaned up before returning. Normalization preserves pixel
    /// dimensions, so `-resize` still applies correctly to the substitute.
    ///
    /// `metadata` is the user's ORIGINAL metadata, and cwebp is the awkward
    /// case: unlike the ImageIO encoders it cannot be handed a property
    /// dictionary, it can only copy metadata out of the file it is given. So
    /// the metadata has to reach it *through its input*, which is why the
    /// normalization hop above re-embeds it into the substitute PNG rather
    /// than writing a bare one. Without that, converting an AVIF to WebP
    /// would hand cwebp a metadata-free temp and `-metadata all` would
    /// faithfully copy nothing.
    ///
    /// Known limitation: with `-resize`, cwebp leaves the EXIF pixel
    /// dimensions describing the pre-resize size. ImageIO cannot encode WebP,
    /// so there is no way to correct it without a third tool, and every
    /// decoder treats the container dimensions as authoritative anyway.
    static func compress(
        input: URL,
        output: URL,
        quality: Int,
        resize: (Int, Int)? = nil,
        metadata: ImageMetadata?
    ) async throws {
        guard let cwebp = ToolChecker.cwebpPath else {
            throw CompressionError.toolMissing("cwebp")
        }

        let needsNormalization = !ImageNormalizer.cwebpDecodableExtensions
            .contains(input.pathExtension.lowercased())
        let cwebpInput: URL = try needsNormalization
            ? ImageNormalizer.encodeAsPNG(from: input, metadata: metadata)
            : input
        defer {
            if needsNormalization {
                try? FileManager.default.removeItem(at: cwebpInput)
            }
        }

        var arguments = ["-q", "\(quality)"]

        // cwebp strips metadata unless told otherwise. That is its
        // documented default, and running it confirms the default is real:
        // without this flag every tag is gone from the output; with it they
        // all survive, orientation included.
        if metadata != nil {
            arguments += ["-metadata", "all"]
        }

        // cwebp has built-in resize support
        if let resize {
            arguments += ["-resize", "\(resize.0)", "\(resize.1)"]
        }

        arguments += ["-o", output.path, cwebpInput.path]

        let result = try await ShellRunner.run(
            cwebp,
            arguments: arguments
        )

        guard result.exitCode == 0 else {
            throw ShellError.executionFailed(
                command: "cwebp",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }
}
