import Foundation

enum BackupError: LocalizedError {
    case cannotCreateFolder(String)
    case cannotCopyFile(String, String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateFolder(let path):
            "Cannot create backup folder at: \(path)"
        case .cannotCopyFile(let file, let reason):
            "Cannot backup '\(file)': \(reason)"
        }
    }
}

enum BackupService {
    static let backupFolderName = "Uncompressed Backup"

    /// Copies `urls` into a per-directory `Uncompressed Backup` folder.
    ///
    /// The actual FileManager work runs in a detached task so a large batch
    /// of files doesn't block the main actor — callers should already have
    /// moved to `.compressing` state before awaiting this so the UI shows
    /// progress feedback immediately rather than appearing to hang.
    static func backupFiles(_ urls: [URL]) async throws {
        try await Task.detached(priority: .userInitiated) {
            try backupFilesSync(urls)
        }.value
    }

    private static func backupFilesSync(_ urls: [URL]) throws {
        let fm = FileManager.default

        // Group files by parent directory
        let grouped = Dictionary(grouping: urls) { $0.deletingLastPathComponent() }

        for (directory, files) in grouped {
            let backupDir = directory.appendingPathComponent(backupFolderName)

            // Create backup folder if needed
            if !fm.fileExists(atPath: backupDir.path) {
                do {
                    try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
                } catch {
                    throw BackupError.cannotCreateFolder(backupDir.path)
                }
            }

            for fileURL in files {
                let filename = fileURL.lastPathComponent
                var destinationURL = backupDir.appendingPathComponent(filename)

                // Handle name collisions
                if fm.fileExists(atPath: destinationURL.path) {
                    destinationURL = uniqueFilename(
                        in: backupDir,
                        for: fileURL.deletingPathExtension().lastPathComponent,
                        extension: fileURL.pathExtension
                    )
                }

                do {
                    try fm.copyItem(at: fileURL, to: destinationURL)
                } catch {
                    throw BackupError.cannotCopyFile(
                        filename,
                        error.localizedDescription
                    )
                }
            }
        }
    }

    private static func uniqueFilename(
        in directory: URL,
        for baseName: String,
        extension ext: String
    ) -> URL {
        let fm = FileManager.default
        var counter = 1

        while true {
            let name = "\(baseName)-\(counter).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }
}
