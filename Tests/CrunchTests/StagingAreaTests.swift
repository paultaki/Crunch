import CrunchCore
import Foundation
import Testing

/// Pins the invariant the whole cross-volume fix rests on: whatever
/// `CompressionJob` hands the pipeline must be on the destination's volume
/// (or `replaceItemAt` fails with "Cross-device link") and must not be the
/// user's own folder (or every run leaks a real image file into a directory
/// iCloud, Dropbox, and Spotlight are watching). Nothing pinned this before,
/// which is exactly how a regression would slip back in.
@Suite("StagingArea")
struct StagingAreaTests {
    private func volumeIdentifier(of url: URL) -> (any NSObjectProtocol)? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
    }

    @Test("reserves a directory on the destination's volume, outside the destination's folder")
    func reservesSameVolumeOutsideUserFolder() throws {
        let fm = FileManager.default
        let userFolder = fm.temporaryDirectory
            .appendingPathComponent("crunch-staging-user-\(UUID().uuidString)")
        try fm.createDirectory(at: userFolder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: userFolder) }

        let destination = userFolder.appendingPathComponent("photo.png")
        let reservation = try StagingArea.reserve(for: destination)

        #expect(fm.fileExists(atPath: reservation.directory.path))

        // Same volume: the reason the atomic replace can work at all.
        let stagingVolume = try #require(volumeIdentifier(of: reservation.directory))
        let destinationVolume = try #require(volumeIdentifier(of: userFolder))
        #expect(stagingVolume.isEqual(destinationVolume))

        // Not the user's folder, and not nested inside it.
        #expect(reservation.directory.standardizedFileURL != userFolder.standardizedFileURL)
        #expect(!reservation.directory.standardizedFileURL.path
            .hasPrefix(userFolder.standardizedFileURL.path))

        // Release removes the whole private directory it created...
        StagingArea.release(reservation)
        #expect(!fm.fileExists(atPath: reservation.directory.path))
        // ...and never the destination's own folder.
        #expect(fm.fileExists(atPath: userFolder.path))
    }

    @Test("each reservation gets its own directory")
    func reservationsAreDistinct() throws {
        let fm = FileManager.default
        let userFolder = fm.temporaryDirectory
            .appendingPathComponent("crunch-staging-distinct-\(UUID().uuidString)")
        try fm.createDirectory(at: userFolder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: userFolder) }

        let first = try StagingArea.reserve(for: userFolder.appendingPathComponent("a.png"))
        let second = try StagingArea.reserve(for: userFolder.appendingPathComponent("b.png"))
        defer {
            StagingArea.release(first)
            StagingArea.release(second)
        }

        // Two files in one batch compress concurrently; sharing a staging
        // directory would mean one file's release deleting the other's
        // in-flight output.
        #expect(first.directory != second.directory)
    }

    // Foundation does NOT throw when it can't resolve the volume for
    // `appropriateFor:` — it quietly hands back a boot-volume directory,
    // which would silently reintroduce the cross-device failure. A
    // destination whose folder doesn't exist reproduces that, and the
    // volume check plus the unwritable fallback have to turn it into a
    // clear error naming the folder.
    @Test("a destination whose folder can't take a temp file throws, naming the folder")
    func unstageableDestinationThrows() throws {
        let folderName = "crunch-missing-\(UUID().uuidString)"
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(folderName)
            .appendingPathComponent("photo.png")

        #expect {
            _ = try StagingArea.reserve(for: destination)
        } throws: { error in
            error.localizedDescription.contains(folderName)
        }
    }
}
