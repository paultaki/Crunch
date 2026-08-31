import Foundation

/// Resolves external Homebrew tools (`pngquant`, `cwebp`) at runtime.
///
/// The tools can live in different locations depending on architecture and how
/// the user installed Homebrew:
///  - Apple Silicon default: `/opt/homebrew/bin`
///  - Intel default:         `/usr/local/bin`
///  - MacPorts fallback:     `/opt/local/bin`
///
/// Resolution is done per-call (no cache) so the implementation stays
/// `Sendable` under Swift 6 strict concurrency — six `stat` calls per
/// compression run are effectively free.
enum ToolChecker {
    private static let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin"
    ]

    /// Returns the absolute path to `tool` if it exists on disk, else `nil`.
    static func resolve(_ tool: String) -> String? {
        let fm = FileManager.default
        for dir in searchPaths {
            let candidate = "\(dir)/\(tool)"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static var pngquantPath: String? { resolve("pngquant") }
    static var cwebpPath: String? { resolve("cwebp") }

    /// Returns a user-facing install message if any tools required by
    /// `formats` are missing, or `nil` if everything is available.
    static func missingTools(for formats: Set<ImageFormat>) -> String? {
        let pngquantMissing = formats.contains(.png) && pngquantPath == nil
        let cwebpMissing = formats.contains(.webp) && cwebpPath == nil

        switch (pngquantMissing, cwebpMissing) {
        case (true, true): return MissingToolsMessage.both
        case (true, false): return MissingToolsMessage.pngquant
        case (false, true): return MissingToolsMessage.cwebp
        case (false, false): return nil
        }
    }
}
