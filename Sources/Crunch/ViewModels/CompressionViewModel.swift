import AppKit
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
        estimationService.invalidate()
        estimationTask?.cancel()
    }

    func reset() {
        files.removeAll()
        results.removeAll()
        state = .empty
        estimatedCompressedSize = nil
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
            isEstimating = false
            return
        }

        let snapshotFiles = files
        let snapshotSettings = settings

        estimationTask = Task { [weak self] in
            try? await Task.sleep(for: Self.estimationDebounce)
            if Task.isCancelled { return }

            await MainActor.run { self?.isEstimating = true }

            let result = await self?.estimationService.estimate(
                files: snapshotFiles,
                settings: snapshotSettings
            )

            if Task.isCancelled { return }
            await MainActor.run {
                self?.estimatedCompressedSize = result
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

        // Backup originals
        do {
            try BackupService.backupFiles(files.map(\.url))
        } catch {
            alertMessage = "Backup failed: \(error.localizedDescription)"
            state = .loaded
            return
        }

        // Compress in parallel
        var completedResults: [CompressionResult] = []
        var completed = 0

        await withTaskGroup(of: CompressionResult.self) { group in
            for file in files {
                group.addTask {
                    await self.compressSingleFile(file)
                }
            }

            for await result in group {
                completedResults.append(result)
                completed += 1
                state = .compressing(completed: completed, total: total)
            }
        }

        // If the user hit Cancel, fall back to the loaded state and leave
        // existing partial work in place. The backup folder already has the
        // originals, and successfully compressed files are simply kept.
        if Task.isCancelled {
            state = .loaded
            return
        }

        results = completedResults.sorted { $0.filename < $1.filename }
        state = .results
    }

    private func compressSingleFile(_ file: ImageFile) async -> CompressionResult {
        let outputFormat = settings.outputFormat.resolve(for: file.format)

        do {
            let output = try await CompressionPipeline.run(file: file, settings: settings)

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
                error: nil
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
