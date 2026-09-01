import Foundation

/// Compresses one queued file and puts the result where the batch planner
/// said it goes. This is the step that actually touches the user's data, so
/// it is kept apart from the view model's queue and progress bookkeeping and
/// exercised directly by tests.
///
/// Main-actor bound on purpose: it is called from `CompressionViewModel`'s
/// task group, and keeping the isolation the view model already had means the
/// per-file move/replace ordering is exactly what it was before this type
/// existed. The expensive part (`CompressionPipeline.run`) suspends and does
/// its work off the actor either way.
@MainActor
public enum CompressionJob {
    /// Runs `file` through the pipeline and delivers the output to
    /// `destination`, the path `OutputDestinationPlanner` reserved for it
    /// before the batch fanned out. `destination` equals `file.url` for an
    /// in-place compression and is a guaranteed-free path for a conversion.
    ///
    /// Never throws: a failure is reported as a `CompressionResult` carrying
    /// the message, so one bad file can't take the batch down with it.
    public static func run(
        file: ImageFile,
        settings: CompressionSettings,
        destination: URL
    ) async -> CompressionResult {
        let outputFormat = settings.outputFormat.resolve(for: file.format)
        let isConversion = outputFormat != file.format

        do {
            // Stage the compressed output in the folder it is about to land
            // in. `deliver` below relies on `replaceItemAt`/`moveItem`, which
            // are only atomic within one volume — staging in the system temp
            // directory broke every delivery onto an external drive or
            // network share ("Cross-device link"). The destination is already
            // fixed by `OutputDestinationPlanner` before any task spawned, so
            // its directory is known here.
            let output = try await CompressionPipeline.run(
                file: file,
                settings: settings,
                stagingDirectory: destination.deletingLastPathComponent()
            )

            // The pipeline hands ownership of its temp to us. Every exit from
            // here that doesn't move it into place has to delete it — the
            // skip below, and any throw from the move itself.
            var outputDelivered = false
            defer {
                if !outputDelivered {
                    try? FileManager.default.removeItem(at: output.url)
                }
            }

            // Never make a file worse: if compression didn't actually shrink
            // it (same format, output >= what's already on disk), leave the
            // original untouched and report "already optimized" instead of
            // replacing it with a same-or-larger file. Compare against the
            // CURRENT on-disk size, not the size cached at drop time, since a
            // previous cancelled run may already have shrunk this file.
            // Format conversions are exempt — the user explicitly asked for a
            // different format (e.g. png → webp), so that result is always
            // delivered even if it happens to be larger.
            let currentSize = fileSize(of: file.url) ?? file.originalSize
            if !isConversion, output.bytes >= currentSize {
                return CompressionResult(
                    filename: file.filename,
                    originalSize: file.originalSize,
                    compressedSize: file.originalSize,
                    error: nil,
                    wasSkipped: true,
                    outputURL: file.url
                )
            }

            let outputURL = try deliver(output.url, to: destination, isConversion: isConversion)
            outputDelivered = true

            // If the output landed at a different path than the source (format
            // conversion, e.g. photo.jpg → photo.webp), the original still sits
            // in the main folder. The backup copy in `Uncompressed Backup` is
            // already on disk, so it's safe to remove the source now.
            if outputURL.standardizedFileURL != file.url.standardizedFileURL {
                try? FileManager.default.removeItem(at: file.url)
            }

            return CompressionResult(
                filename: outputURL.lastPathComponent,
                originalSize: file.originalSize,
                compressedSize: output.bytes,
                error: nil,
                outputURL: outputURL
            )
        } catch {
            return CompressionResult(
                filename: file.filename,
                originalSize: file.originalSize,
                compressedSize: nil,
                error: error.localizedDescription
            )
        }
    }

    /// Moves the pipeline's temp onto `destination` and returns where it
    /// actually landed.
    ///
    /// In-place compressions replace atomically, so a crash mid-write can
    /// never leave a half-written source. Conversions move onto a path the
    /// planner reserved as free; if something claimed it in the meantime we
    /// step aside to a fresh name rather than overwrite a file that has no
    /// backup.
    private static func deliver(
        _ temp: URL,
        to destination: URL,
        isConversion: Bool
    ) throws -> URL {
        let fm = FileManager.default

        guard isConversion else {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: destination)
            }
            return destination
        }

        let target = fm.fileExists(atPath: destination.path)
            ? OutputDestinationPlanner.availableURL(startingAt: destination)
            : destination
        try fm.moveItem(at: temp, to: target)
        return target
    }

    private static func fileSize(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }
}
