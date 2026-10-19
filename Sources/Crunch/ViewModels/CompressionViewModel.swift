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
    /// Set when the estimate couldn't run because this Mac's ImageIO can't
    /// encode the resolved format at all (currently only AVIF) — distinct
    /// from `estimateMissingToolFormat` because there's no install fix to
    /// suggest, just an explanation. `nil` once the format resolves to
    /// something encodable.
    private(set) var estimateUnsupportedFormat: ImageFormat?
    /// Original/compressed sample URLs for the before/after preview sheet,
    /// or `nil` whenever there's nothing to show — estimating, no sample,
    /// or the estimate outcome wasn't a `.value`. Mirrors
    /// `EstimationService.previewPair`; see that property's doc comment for
    /// the cache-hit edge case where it can go briefly nil.
    private(set) var previewPair: (original: URL, compressed: URL)?

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

    /// Honest totals and outcome counts for the finished batch. The
    /// arithmetic deliberately lives in `CrunchCore` where tests can reach
    /// it — see `BatchSummary`.
    var batchSummary: BatchSummary {
        BatchSummary(results: results)
    }

    /// How many files are decoded at once, and how many land in `files` in
    /// a single main-actor update. 32 is about one decode per core on the
    /// Mac this was tuned on; dropping to 8 costs real throughput (300
    /// files: 174 ms at 32, 305 ms at 8) while raising it to 64 buys almost
    /// nothing (138 ms). It also caps how many decodes are in flight, which
    /// matters more for a 500-file drop than for memory — 64 concurrent
    /// 4032x3024 thumbnail decodes measured a 35 MB peak footprint, because
    /// ImageIO downsamples incrementally instead of materialising full-res
    /// buffers.
    ///
    /// `nonisolated` because this class is `@MainActor`, which isolates even
    /// its immutable statics — the detached load loop can't read the
    /// constant without it.
    private nonisolated static let loadBatchSize = 32

    /// Loads `urls` off the main thread, skipping ones already queued, and
    /// appends them in the dropped order.
    ///
    /// Files are decoded concurrently in batches of `loadBatchSize`, and
    /// each batch is appended as soon as it lands, so a big folder fills the
    /// list progressively instead of showing nothing until the last
    /// thumbnail is done. `ImageFile.loadBatch` returns each batch in the
    /// order it was given — `DropZoneView` hands over a name-sorted batch
    /// and the user expects to see exactly that order.
    ///
    /// This used to load sequentially, on the stated theory that thumbnail
    /// work was too cheap for parallelism to beat the reorder cost. Measured,
    /// that was simply wrong, and recovering the order is an array of
    /// optionals: 60 files at 2000x1500 went from 543 ms to 32 ms, and 300
    /// went from 2741 ms to 174 ms (32-core Mac, best of three). A 4-core
    /// Mac will see a smaller multiple, but never a worse one than serial.
    func addFiles(_ urls: [URL]) {
        let existingURLs = Set(files.map(\.url))
        let newURLs = urls.filter { !existingURLs.contains($0) }
        guard !newURLs.isEmpty else { return }

        Task.detached(priority: .userInitiated) { [weak self] in
            for start in stride(from: 0, to: newURLs.count, by: Self.loadBatchSize) {
                // Checked before decoding, not after: a 500-file folder is a
                // lot of work to finish for a window that has already gone.
                // The strong reference lasts one batch, then drops.
                guard let viewModel = self else { return }

                let end = min(start + Self.loadBatchSize, newURLs.count)
                let loaded = await ImageFile.loadBatch(from: Array(newURLs[start..<end]))
                await viewModel.appendLoaded(loaded)
            }
        }
    }

    private func appendLoaded(_ loaded: [ImageFile]) {
        guard !loaded.isEmpty else { return }
        files.append(contentsOf: loaded)

        // A run in flight compresses the batch it snapshotted at its start,
        // so these arrivals just queue up for the next run. Leaving state and
        // the estimate alone keeps the progress UI honest and stops a
        // re-estimate from fighting the run for pngquant/cwebp.
        if case .compressing = state { return }

        state = .loaded
        requestEstimate()
    }

    func removeFile(_ file: ImageFile) {
        files.removeAll { $0.id == file.id }
        if files.isEmpty {
            state = .empty
            estimatedCompressedSize = nil
            estimateMissingToolFormat = nil
            estimateUnsupportedFormat = nil
            previewPair = nil
            estimationTask?.cancel()
            estimationService.invalidate()
        } else {
            requestEstimate()
        }
    }

    func clearAll() {
        clearQueueAndEstimate()
    }

    func reset() {
        clearQueueAndEstimate()
    }

    /// Empties the queue and tears the estimate down. Cancels the in-flight
    /// estimation task BEFORE invalidating, so a task that's mid-`estimate()`
    /// can't repopulate the cache or resurrect a preview temp right after
    /// we've deleted it (same ordering as `removeFile`).
    private func clearQueueAndEstimate() {
        files.removeAll()
        results.removeAll()
        state = .empty
        estimatedCompressedSize = nil
        estimateMissingToolFormat = nil
        estimateUnsupportedFormat = nil
        previewPair = nil
        estimationTask?.cancel()
        estimationService.invalidate()
    }

    /// Debounced trigger that re-runs sample-based estimation. Safe to call
    /// on every settings or file change — older tasks are cancelled so the
    /// UI only sees the most recent result.
    func requestEstimate() {
        // A run in flight owns the compressors and is rewriting the very
        // files an estimate would sample. Leave the displayed estimate
        // untouched until it finishes; the cancel/finish paths re-request.
        if case .compressing = state { return }

        estimationTask?.cancel()
        // Settings (or the file set) just changed, so whatever preview pair
        // was showing no longer matches — clear it immediately rather than
        // waiting for the debounced re-estimate, same as the size/percent
        // fields below.
        previewPair = nil

        guard !files.isEmpty else {
            estimatedCompressedSize = nil
            estimateMissingToolFormat = nil
            estimateUnsupportedFormat = nil
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
                    self?.estimateUnsupportedFormat = nil
                    self?.previewPair = self?.estimationService.previewPair
                case .toolMissing(let format):
                    self?.estimatedCompressedSize = nil
                    self?.estimateMissingToolFormat = format
                    self?.estimateUnsupportedFormat = nil
                case .formatUnsupported(let format):
                    self?.estimatedCompressedSize = nil
                    self?.estimateMissingToolFormat = nil
                    self?.estimateUnsupportedFormat = format
                case .unavailable, .none:
                    self?.estimatedCompressedSize = nil
                    self?.estimateMissingToolFormat = nil
                    self?.estimateUnsupportedFormat = nil
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
        // Re-entry would start a second run over the same files while the
        // first is still rewriting them. The task handle is the
        // authoritative check because it's assigned synchronously below,
        // before any suspension point — `state` only flips to `.compressing`
        // once `runCompression`'s body starts, which a second tap can beat.
        guard compressionTask == nil else { return }
        if case .compressing = state { return }

        // Don't fight the real run for CPU or pngquant/cwebp processes.
        estimationTask?.cancel()
        let task = Task { await runCompression() }
        compressionTask = task
        await task.value
        compressionTask = nil
    }

    private func runCompression() async {
        // One snapshot drives the whole run: the tool check, the backup, the
        // progress total, the destination plan, and the work queue. Reading
        // the live `files` array after an await would let a drop that landed
        // mid-backup get compressed with no backup behind it. Files added
        // during a run stay queued for the next one.
        let batch = files
        // Settings are snapshotted alongside the files: a slider moved
        // mid-run must not change what half the batch compresses to.
        let runSettings = settings
        let total = batch.count
        state = .compressing(completed: 0, total: total)

        // Check which tools are needed
        let neededFormats = Set(batch.map { runSettings.outputFormat.resolve(for: $0.format) })
        if let missing = ToolChecker.missingTools(for: neededFormats) {
            alertMessage = missing
            state = .loaded
            return
        }

        // Backup originals. State is already `.compressing` (completed: 0)
        // so the UI shows progress feedback immediately; the copy itself
        // runs off the main actor so a large batch doesn't stall the UI.
        do {
            try await BackupService.backupFiles(batch.map(\.url))
        } catch {
            alertMessage = "Backup failed: \(error.localizedDescription)"
            state = .loaded
            return
        }

        // Assign every output path serially, before any task spawns, so two
        // conversions can't land on one name and no conversion can clobber an
        // un-backed-up bystander. See `OutputDestinationPlanner`.
        let destinations = OutputDestinationPlanner.plan(
            batch.map {
                OutputDestinationPlanner.Request(
                    source: $0.url,
                    sourceFormat: $0.format,
                    outputFormat: runSettings.outputFormat.resolve(for: $0.format)
                )
            }
        )
        let work = Array(zip(batch, destinations))

        // Compress with bounded concurrency: an unbounded task group would
        // spin up one pngquant/cwebp process per file at once, which
        // thrashes the CPU scheduler on large batches. Cap in-flight tasks
        // to the core count (minimum 2) and top up the pool as each task
        // finishes — one child task per file overall, at most N in flight.
        let maxConcurrency = min(total, max(2, ProcessInfo.processInfo.activeProcessorCount))
        var completedResults: [CompressionResult] = []
        var completed = 0

        await withTaskGroup(of: CompressionResult.self) { group in
            var pending = work.makeIterator()

            for _ in 0..<maxConcurrency {
                guard !Task.isCancelled, let next = pending.next() else { break }
                group.addTask {
                    await CompressionJob.run(
                        file: next.0,
                        settings: runSettings,
                        destination: next.1
                    )
                }
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
                if !Task.isCancelled, let next = pending.next() {
                    group.addTask {
                        await CompressionJob.run(
                            file: next.0,
                            settings: runSettings,
                            destination: next.1
                        )
                    }
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
            // Every cached ratio and the kept preview temp describe files
            // that just changed on disk, so they'd extrapolate phantom
            // savings off already-compressed bytes. Drop them, then
            // re-estimate from scratch.
            estimationService.invalidate()
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
}
