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

        // Two reasons to hand cwebp a substitute PNG instead of the file we
        // were given: it cannot decode the format (AVIF, in practice), or the
        // metadata we have to apply is a reduced set that `-metadata all`
        // cannot express — it would copy the original's GPS straight back in.
        // Re-embedding the reduced set into the substitute makes "copy
        // everything from the input" copy exactly what we want.
        //
        // That substitute costs a full lossless PNG encode, so it is worth
        // being clear about when it happens: only when metadata is being
        // stripped AND the source is not already upright, since an upright
        // source reduces to no metadata at all and takes the fast path.
        // Measured on a 4032x3024 photo: 1.5s normally, 2.5s on that one
        // combination. Paid so that stripping a photo's history does not
        // also hand it back on its side.
        let cannotDecodeInput = !ImageNormalizer.cwebpDecodableExtensions
            .contains(input.pathExtension.lowercased())
        let metadataNeedsRewriting = metadata.map { !$0.isVerbatimCopyOfSource } ?? false
        let needsNormalization = cannotDecodeInput || metadataNeedsRewriting
        let cwebpInput: URL = try needsNormalization
            ? ImageNormalizer.encodeAsPNG(from: input, metadata: metadata)
            : input
        defer {
            if needsNormalization {
                try? FileManager.default.removeItem(at: cwebpInput)
            }
        }

        var arguments = ["-q", "\(quality)"]

        // cwebp strips metadata unless told otherwise — its documented
        // default, confirmed by running it. Omitting the flag is therefore
        // exactly what the user's "Strip metadata" setting asks for.
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
