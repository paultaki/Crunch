import Foundation

enum WebPCompressor {
    static func compress(
        input: URL,
        output: URL,
        quality: Int,
        resize: (Int, Int)? = nil
    ) async throws {
        guard let cwebp = ToolChecker.cwebpPath else {
            throw CompressionError.toolMissing("cwebp")
        }

        var arguments = ["-q", "\(quality)"]

        // cwebp has built-in resize support
        if let resize {
            arguments += ["-resize", "\(resize.0)", "\(resize.1)"]
        }

        arguments += ["-o", output.path, input.path]

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
