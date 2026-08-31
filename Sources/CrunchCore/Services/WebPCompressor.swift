import Foundation

enum WebPCompressor {
    /// Runs cwebp on the input file, writing a WebP to `output`.
    ///
    /// cwebp decodes only a short list of formats (PNG, JPEG, TIFF, WebP).
    /// Anything else — AVIF in practice — is re-encoded to a temporary
    /// lossless PNG first, same as `PNGCompressor` does for pngquant, and the
    /// temp is cleaned up before returning. Normalization preserves pixel
    /// dimensions, so `-resize` still applies correctly to the substitute.
    static func compress(
        input: URL,
        output: URL,
        quality: Int,
        resize: (Int, Int)? = nil
    ) async throws {
        guard let cwebp = ToolChecker.cwebpPath else {
            throw CompressionError.toolMissing("cwebp")
        }

        let needsNormalization = !ImageNormalizer.cwebpDecodableExtensions
            .contains(input.pathExtension.lowercased())
        let cwebpInput: URL = try needsNormalization
            ? ImageNormalizer.encodeAsPNG(from: input)
            : input
        defer {
            if needsNormalization {
                try? FileManager.default.removeItem(at: cwebpInput)
            }
        }

        var arguments = ["-q", "\(quality)"]

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
