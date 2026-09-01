import Foundation

/// Decides where a compressed output is written before it is delivered onto
/// the user's file, and owns cleaning up after itself.
///
/// Two constraints pull against each other here. `replaceItemAt` and
/// `moveItem` are only atomic within a single *volume*, so the staging area
/// has to sit on the destination's volume — staging on the boot volume is
/// what made every file on an external drive fail with POSIX 18,
/// "Cross-device link". But staging in the user's own folder is a poor
/// answer: it drops a real image file into a directory iCloud Drive,
/// Dropbox, and Spotlight are all watching, on every run including the
/// boot-volume runs that never had a problem, and a force-quit mid-batch
/// leaves it there permanently with nothing to sweep it up.
///
/// `.itemReplacementDirectory` satisfies both. Foundation hands back a fresh
/// private directory on the destination's own volume (its `.TemporaryItems`),
/// outside anything the user or a sync daemon looks at.
public enum StagingArea {
    /// A staging directory plus the cleanup obligation that came with it.
    public struct Reservation: Sendable {
        /// Where the pipeline should write its output temp.
        public let directory: URL

        /// The directory to delete on release — set ONLY when we created a
        /// private one. `nil` on the fallback path, where `directory` is the
        /// user's own folder and deleting it would destroy their files.
        /// Modelled as an optional URL rather than a "did we own it?" flag so
        /// the catastrophic case can't be reached by getting a boolean
        /// backwards.
        fileprivate let ownedDirectory: URL?
    }

    /// Reserves somewhere same-volume to stage `destination`'s replacement.
    ///
    /// Ladder, in order: a private replacement directory on the destination's
    /// volume; failing that the destination's own directory (same volume by
    /// definition, so still atomic — correctness first, tidiness second);
    /// failing that a throw, because the alternative is a cross-volume copy
    /// that gives up the atomicity keeping a crash from leaving a
    /// half-written original.
    public static func reserve(for destination: URL) throws -> Reservation {
        let destinationDirectory = destination.deletingLastPathComponent()

        if let replacement = privateReplacementDirectory(on: destinationDirectory) {
            return Reservation(directory: replacement, ownedDirectory: replacement)
        }

        guard FileManager.default.isWritableFile(atPath: destinationDirectory.path) else {
            throw CompressionError.cannotStageOutput(destinationDirectory.lastPathComponent)
        }
        return Reservation(directory: destinationDirectory, ownedDirectory: nil)
    }

    /// Removes the whole private directory, not just the file inside it —
    /// every `reserve` mints a fresh one. A no-op on the fallback path.
    /// Best-effort by design: a failure here leaks an empty directory in a
    /// place the OS already reaps, and must never mask the compression
    /// result.
    public static func release(_ reservation: Reservation) {
        guard let ownedDirectory = reservation.ownedDirectory else { return }
        try? FileManager.default.removeItem(at: ownedDirectory)
    }

    private static func privateReplacementDirectory(on directory: URL) -> URL? {
        guard let replacement = try? FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: directory,
            create: true
        ) else { return nil }

        // Verified, not assumed. Handed a directory it can't resolve — one
        // that doesn't exist, say — Foundation does NOT throw: it quietly
        // returns a directory under the *boot* volume's temp, which would
        // silently reintroduce the exact cross-device failure this type
        // exists to prevent. Confirm the volumes actually match, and fall
        // back rather than trust it when they don't.
        guard isSameVolume(replacement, directory) else {
            try? FileManager.default.removeItem(at: replacement)
            return nil
        }
        return replacement
    }

    private static func isSameVolume(_ lhs: URL, _ rhs: URL) -> Bool {
        guard
            let left = try? lhs.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
            let right = try? rhs.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        else { return false }
        return left.isEqual(right)
    }
}
