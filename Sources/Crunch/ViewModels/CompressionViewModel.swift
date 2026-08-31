import AppKit
import CrunchCore
import Foundation
import Observation

@MainActor
@Observable
final class CompressionViewModel {
    private(set) var state: AppState = .empty
    private(set) var files: [ImageFile] = []
    private(set) var results: [CompressionResult] = []
    var settings = CompressionSettings()
    var alertMessage: String?

    /// Current in-flight compression task. Kept so the UI can cancel mid-run.
    private var compressionTask: Task<Void, Never>?

    // MARK: - Size estimation

    private(set) var estimatedCompressedSize: Int64?
    private(set) var isEstimating: Bool = false
    /// Set when the estimate couldn't run because a required compressor
    /// (pngquant/cwebp) is missing, so the UI can show an inline install
    /// notice instead of a silent dash. `nil` once the tool is found or the
    /// format no longer needs it.
    private(set) var estimateMissingToolFormat: ImageFormat?

    private let estimationService = EstimationService()
    private var estimationTask: Task<Void, Never>?

    /// How long to wait after a settings change before firing the sample
    /// run. Long enough that slider dragging doesn't thrash the compressors,
    /// short enough that the UI feels live.
    private static let estimationDebounce: Duration = .milliseconds(400)

    var canCompress: Bool {
        if case .loaded = state, !files.isEmpty { return true }
        return false
    }

    /// Stable value that changes when the top-level UI state changes case.
    /// Used to drive SwiftUI state-transition animations without leaking
    /// associated values into view identity.
    var stateID: String {
        switch state {
        case .empty: "empty"
        case .loaded: "loaded"
        case .compressing: "compressing"
        case .results: "results"
        }
    }

    var totalOriginalSize: Int64 {
        files.reduce(0) { $0 + $1.originalSize }
    }

    var totalCompressedSize: Int64 {
        results.compactMap(\.compressedSize).reduce(0, +)
    }

    var totalReduction: Double {
        let original = results.reduce(Int64(0)) { $0 + $1.originalSize }
        let compressed = results.compactMap(\.compressedSize).reduce(Int64(0), +)
        guard original > 0 else { return 0 }
        return Double(original - compressed) / Double(original) * 100
    }

    /// Loads `urls` off the main thread, skipping duplicates, then appends
    /// results in the dropped order. Ordering is preserved by resolving
    /// loads sequentially inside a detached task group — the thumbnail work
    /// is cheap enough that parallelism isn't worth the reorder cost.
    func addFiles(_ urls: [URL]) {
        let existingURLs = Set(files.map(\.url))
        let newURLs = urls.filter { !existingURLs.contains($0) }
        guard !newURLs.isEmpty else { return }

        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = newURLs.compactMap { ImageFile.load(from: $0) }
            await self?.appendLoaded(loaded)
        }
    }

    private func appendLoaded(_ loaded: [ImageFile]) {
        guard !loaded.isEmpty else { return }
        files.append(contentsOf: loaded)
        if !files.isEmpty {
            state = .loaded
        }
        requestEstimate()
    }

    func removeFile(_ file: ImageFile) {
        files.removeAll { $0.id == file.id }
        if files.isEmpty {
            state = .empty
            estimatedCompressedSize = nil
            estimateMissingToolFormat = nil
            estimationService.invalidate()
        } else {
            requestEstimate()
        }
    }

    func clearAll() {
        files.removeAll()
        results.removeAll()
        state = .empty
        estimatedCompressedSize = nil
        estimateMissingToolFormat = nil
        estimationService.invalidate()
        estimationTask?.cancel()
    }

    func reset() {
        files.removeAll()
        results.removeAll()
        state = .empty
        estimatedCompressedSize = nil
        estimateMissingToolFormat = nil
        estimationService.invalidate()
        estimationTask?.cancel()
    }

    /// Debounced trigger that re-runs sample-based estimation. Safe to call
    /// on every settings or file change — older tasks are cancelled so the
    /// UI only sees the most recent result.
    func requestEstimate() {
        estimationTask?.cancel()

        guard !files.isEmpty else {
            estimatedCompressedSize = nil
            estimateMissingToolFormat = nil
            isEstimating = false
            return
        }

        let snapshotFiles = files
        let snapshotSettings = settings

        estimationTask = Task { [weak self] in
            try? await Task.sleep(for: Self.estimationDebounce)
            if Task.isCancelled { return }

            await MainActor.run { self?.isEstimating = true }

            let outcome = await self?.estimationService.estimate(
                files: snapshotFiles,
                settings: snapshotSettings
            )

            if Task.isCancelled { return }
            await MainActor.run {
                switch outcome {
                case .value(let size):
                    self?.estimatedCompressedSize = size
                    self?.estimateMissingToolFormat = nil
                case .toolMissing(let format):
                    self?.estimatedCompressedSize = nil
                    self?.estimateMissingToolFormat = format
                case .unavailable, .none:
                    self?.estimatedCompressedSize = nil
                    self?.estimateMissingToolFormat = nil
                }
                self?.isEstimating = false
            }
        }
    }

    /// Reduction percentage implied by the current estimate, or `nil` if
    /// we don't have one yet.
    var estimatedReduction: Double? {
        guard let estimated = estimatedCompressedSize, totalOriginalSize > 0 else {
            return nil
        }
        return Double(totalOriginalSize - estimated) / Double(totalOriginalSize) * 100
    }

    func cancelCompression() {
        compressionTask?.cancel()
    }

    func compress() async {
        // Don't fight the real run for CPU or pngquant/cwebp processes.
        estimationTask?.cancel()
        compressionTask = Task { await runCompression() }
        await compressionTask?.value
    }

    private func runCompression() async {
        let total = files.count
        state = .compressing(completed: 0, total: total)

        // Check which tools are needed
        let neededFormats = Set(files.map { settings.outputFormat.resolve(for: $0.format) })
        if let missing = ToolChecker.missingTools(for: neededFormats) {
            alertMessage = missing
            state = .loaded
            return
        }

        // Backup originals. State is already `.compressing` (completed: 0)
        // so the UI shows progress feedback immediately; the copy itself
        // runs off the main actor so a large batch doesn't stall the UI.
        do {
            try await BackupService.backupFiles(files.map(\.url))
        } catch {
            alertMessage = "Backup failed: \(error.localizedDescription)"
            state = .loaded
            return
        }

        // Compress with bounded concurrency: an unbounded task group would
        // spin up one pngquant/cwebp process per file at once, which
        // thrashes the CPU scheduler on large batches. Cap in-flight tasks
        // to the core count (minimum 2) and top up the pool as each task
        // finishes — one child task per file overall, at most N in flight.
        let maxConcurrency = min(total, max(2, ProcessInfo.processInfo.activeProcessorCount))
        var completedResults: [CompressionResult] = []
        var completed = 0

        await withTaskGroup(of: CompressionResult.self) { group in
            var pending = files.makeIterator()

            for _ in 0..<maxConcurrency {
                guard !Task.isCancelled, let file = pending.next() else { break }
                group.addTask { await self.compressSingleFile(file) }
            }

            for await result in group {
                completedResults.append(result)
                completed += 1
                state = .compressing(completed: completed, total: total)

                // Once cancelled, stop pulling new work from `pending` and
                // just drain the tasks already in flight — otherwise
                // `addTask` (which doesn't itself check cancellation) keeps
                // topping up the window and Cancel never actually stops
                // new files from starting.
                if !Task.isCancelled, let file = pending.next() {
                    group.addTask { await self.compressSingleFile(file) }
                }
            }
        }

        // If the user hit Cancel, reconcile the working set with disk before
        // falling back to `.loaded`: format conversions already moved their
        // output to a new URL (the old one is gone), and in-place
        // compressions changed the file's size out from under us. Without
        // this, a re-run would back up and report against stale metadata.
        if Task.isCancelled {
            await reconcileFilesWithDisk()
            state = .loaded
            requestEstimate()
            return
        }

        results = completedResults.sorted { $0.filename < $1.filename }
        state = .results
    }

    /// Reloads each surviving file's metadata (size, thumbnail) from disk
    /// and drops entries whose URL no longer exists — the two outcomes a
    /// compression run cancelled mid-flight can leave behind. Runs off the
    /// main actor since reloading touches ImageIO. Preserves each file's
    /// `id` so SwiftUI list identity survives the reconciliation.
    private func reconcileFilesWithDisk() async {
        let snapshot = files
        let reconciled = await Task.detached(priority: .userInitiated) {
            snapshot.compactMap { file -> ImageFile? in
                guard FileManager.default.fileExists(atPath: file.url.path) else {
                    // Format conversion already moved the output and removed
                    // the source; nothing left to back up or report on.
                    return nil
                }
                return ImageFile.load(from: file.url, id: file.id) ?? file
            }
        }.value
        files = reconciled
    }

    private func compressSingleFile(_ file: ImageFile) async -> CompressionResult {
        let outputFormat = settings.outputFormat.resolve(for: file.format)
        let isConversion = outputFormat != file.format

        do {
            let output = try await CompressionPipeline.run(file: file, settings: settings)

            // Never make a file worse: if compression didn't actually shrink
            // it (same format, output >= what's already on disk), leave the
            // original untouched and report "already optimized" instead of
            // replacing it with a same-or-larger file. Format conversions
            // are exempt — the user explicitly asked for a different format
            // (e.g. png → webp), so that result is always delivered even if
            // it happens to be larger.
            if !isConversion, output.bytes >= file.originalSize {
                try? FileManager.default.removeItem(at: output.url)
                return CompressionResult(
                    filename: file.filename,
                    originalSize: file.originalSize,
                    compressedSize: file.originalSize,
                    error: nil,
                    wasSkipped: true,
                    outputURL: file.url
                )
            }

            // Determine output path
            let outputURL: URL
            if outputFormat == file.format {
                outputURL = file.url
            } else {
                // New extension, same directory
                outputURL = file.url.deletingPathExtension()
                    .appendingPathExtension(outputFormat.fileExtension)
            }

            // Move temp to final location
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: output.url)
            } else {
                try FileManager.default.moveItem(at: output.url, to: outputURL)
            }

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
}
