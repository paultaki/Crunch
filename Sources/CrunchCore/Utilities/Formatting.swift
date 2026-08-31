import Foundation

public extension Int64 {
    /// Human-readable file size, e.g. `"2.4 MB"`. Uses the system
    /// `ByteCountFormatter` so it respects locale and OS conventions.
    ///
    /// `ByteCountFormatter` isn't `Sendable`, so we instantiate per call
    /// rather than cache a shared instance.
    var formattedBytes: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: self)
    }
}
