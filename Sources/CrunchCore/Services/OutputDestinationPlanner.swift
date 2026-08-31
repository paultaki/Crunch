import Foundation

/// Decides, up front and serially, where every file in a compression batch
/// will land on disk.
///
/// Doing this before any parallel work starts is a data-safety requirement,
/// not a tidiness one. When each task picked its own destination it could
/// (a) overwrite a pre-existing sibling that was never backed up
/// (`photo.png` → JPEG clobbering an unrelated `photo.jpg`), (b) race another
/// queued file that maps to the same name (`photo.png` and `photo.jpg` both
/// → `photo.webp`, last write wins and both sources get deleted), or
/// (c) silently overwrite output left behind by an earlier cancelled run.
///
/// The rule: an in-place compression keeps its own URL (the source is the
/// file that was backed up, so an atomic replace is correct), and a format
/// conversion always gets a path that is free both on disk and within the
/// batch.
public enum OutputDestinationPlanner {
    /// One file's ask: where it came from and what format it is becoming.
    public struct Request: Sendable {
        public let source: URL
        public let sourceFormat: ImageFormat
        public let outputFormat: ImageFormat

        public init(source: URL, sourceFormat: ImageFormat, outputFormat: ImageFormat) {
            self.source = source
            self.sourceFormat = sourceFormat
            self.outputFormat = outputFormat
        }

        var isConversion: Bool { outputFormat != sourceFormat }
    }

    /// Returns one destination per request, in the same order. Conversions
    /// are uniquified against both the filesystem and the destinations
    /// already claimed earlier in this batch.
    public static func plan(_ requests: [Request]) -> [URL] {
        var claimed: Set<String> = []
        var destinations: [URL] = []
        destinations.reserveCapacity(requests.count)

        for request in requests {
            let destination: URL
            if request.isConversion {
                let preferred = request.source.deletingPathExtension()
                    .appendingPathExtension(request.outputFormat.fileExtension)
                destination = availableURL(startingAt: preferred, claimed: claimed)
            } else {
                destination = request.source
            }
            claimed.insert(destination.standardizedFileURL.path)
            destinations.append(destination)
        }

        return destinations
    }

    /// First free path at or after `candidate`, appending `-1`, `-2`, … to
    /// the basename until nothing on disk (and nothing in `claimed`) holds
    /// it. Mirrors `BackupService`'s collision naming so the two produce
    /// recognizably similar names.
    ///
    /// Also called defensively at move time: the gap between planning and
    /// writing is small but not zero, and losing a user's file to it is not
    /// an acceptable outcome.
    public static func availableURL(
        startingAt candidate: URL,
        claimed: Set<String> = []
    ) -> URL {
        guard isTaken(candidate, claimed: claimed) else { return candidate }

        let directory = candidate.deletingLastPathComponent()
        let baseName = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension

        var counter = 1
        while true {
            let name = ext.isEmpty ? "\(baseName)-\(counter)" : "\(baseName)-\(counter).\(ext)"
            let next = directory.appendingPathComponent(name)
            if !isTaken(next, claimed: claimed) { return next }
            counter += 1
        }
    }

    private static func isTaken(_ url: URL, claimed: Set<String>) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || claimed.contains(url.standardizedFileURL.path)
    }
}
