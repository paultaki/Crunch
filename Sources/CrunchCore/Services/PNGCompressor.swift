import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PNGCompressor {
    /// Runs pngquant on the input file, writing a quantized PNG to `output`.
    ///
    /// pngquant only accepts PNG input (it relies on libpng to decode). When
    /// the caller hands us a JPEG, WebP, or anything else, we transparently
    /// re-encode the source to a temporary PNG first via `ImageIO` and feed
    /// that to pngquant. The temp file is cleaned up before returning.
    static func compress(input: URL, output: URL, quality: Int) async throws {
        guard let pngquant = ToolChecker.pngquantPath else {
            throw CompressionError.toolMissing("pngquant")
        }

        let needsNormalization = input.pathExtension.lowercased() != "png"
        let pngInput: URL = try needsNormalization ? Self.encodeAsPNG(from: input) : input
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
            return
        }

        guard result.exitCode == 0 else {
            throw ShellError.executionFailed(
                command: "pngquant",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    // MARK: - Format normalization

    /// Decodes any image `ImageIO` understands and re-encodes it as a
    /// lossless PNG to a unique file in the system temp directory.
    private static func encodeAsPNG(from source: URL) throws -> URL {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw CompressionError.cannotReadImage(source.lastPathComponent)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")

        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CompressionError.cannotWriteImage(tempURL.lastPathComponent)
        }

        CGImageDestinationAddImage(destination, cgImage, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw CompressionError.cannotWriteImage(tempURL.lastPathComponent)
        }

        return tempURL
    }
}
