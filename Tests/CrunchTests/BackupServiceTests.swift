import CrunchCore
import Foundation
import Testing

/// A `final class` (not a struct) so each test gets a fresh temp directory
/// in `init` and it's reliably cleaned up in `deinit` — Swift Testing gives
/// every test method its own instance.
final class BackupServiceTests {
    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crunch-backup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("backs up a file into a sibling Uncompressed Backup folder")
    func backsUpToSiblingFolder() async throws {
        let fileURL = tempDir.appendingPathComponent("photo.png")
        try Data("original".utf8).write(to: fileURL)

        try await BackupService.backupFiles([fileURL])

        let backupFile = tempDir
            .appendingPathComponent(BackupService.backupFolderName)
            .appendingPathComponent("photo.png")
        #expect(FileManager.default.fileExists(atPath: backupFile.path))
    }

    @Test("collision naming increments -1, -2 on repeated backups")
    func collisionNamingIncrements() async throws {
        let fileURL = tempDir.appendingPathComponent("photo.png")
        let backupDir = tempDir.appendingPathComponent(BackupService.backupFolderName)

        try Data("v1".utf8).write(to: fileURL)
        try await BackupService.backupFiles([fileURL])

        try Data("v2".utf8).write(to: fileURL)
        try await BackupService.backupFiles([fileURL])

        try Data("v3".utf8).write(to: fileURL)
        try await BackupService.backupFiles([fileURL])

        #expect(FileManager.default.fileExists(atPath: backupDir.appendingPathComponent("photo.png").path))
        #expect(FileManager.default.fileExists(atPath: backupDir.appendingPathComponent("photo-1.png").path))
        #expect(FileManager.default.fileExists(atPath: backupDir.appendingPathComponent("photo-2.png").path))
    }

    @Test("collision naming on an extensionless file doesn't emit a trailing dot")
    func collisionNamingWithoutExtension() async throws {
        let fileURL = tempDir.appendingPathComponent("photo")
        let backupDir = tempDir.appendingPathComponent(BackupService.backupFolderName)

        try Data("v1".utf8).write(to: fileURL)
        try await BackupService.backupFiles([fileURL])

        try Data("v2".utf8).write(to: fileURL)
        try await BackupService.backupFiles([fileURL])

        #expect(FileManager.default.fileExists(atPath: backupDir.appendingPathComponent("photo").path))
        #expect(FileManager.default.fileExists(atPath: backupDir.appendingPathComponent("photo-1").path))
        #expect(!FileManager.default.fileExists(atPath: backupDir.appendingPathComponent("photo-1.").path))
    }

    @Test("groups backups by each file's parent directory")
    func groupsByParentDirectory() async throws {
        let subDirA = tempDir.appendingPathComponent("A")
        let subDirB = tempDir.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: subDirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subDirB, withIntermediateDirectories: true)

        let fileA = subDirA.appendingPathComponent("a.jpg")
        let fileB = subDirB.appendingPathComponent("b.jpg")
        try Data("a".utf8).write(to: fileA)
        try Data("b".utf8).write(to: fileB)

        try await BackupService.backupFiles([fileA, fileB])

        let backupA = subDirA
            .appendingPathComponent(BackupService.backupFolderName)
            .appendingPathComponent("a.jpg")
        let backupB = subDirB
            .appendingPathComponent(BackupService.backupFolderName)
            .appendingPathComponent("b.jpg")

        #expect(FileManager.default.fileExists(atPath: backupA.path))
        #expect(FileManager.default.fileExists(atPath: backupB.path))
        // Each source directory got its own backup folder, not one shared one.
        #expect(!FileManager.default.fileExists(
            atPath: subDirA.appendingPathComponent(BackupService.backupFolderName)
                .appendingPathComponent("b.jpg").path
        ))
    }
}
