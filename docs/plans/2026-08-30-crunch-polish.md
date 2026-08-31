# Crunch Polish & GitHub-Readiness Plan

## Context

Crunch is a macOS 15+ SwiftUI image compressor (SPM executable target, Swift 6, ~2,100 lines).
Drag-and-drop PNG/JPEG/WebP → compress via pngquant (PNG), native ImageIO (JPEG), cwebp (WebP),
with live size estimation, backups to an "Uncompressed Backup" folder, and a results view.
Goal: fix verified bugs, then make the repo publishable on GitHub as a portfolio piece, then add
the highest-delight features found in competitive research (Squoosh/ImageOptim/Optimage/Curtail).

Verified findings this plan addresses (from code review, 2026-08-30):
- WebP source + resize + PNG/JPEG output always fails: `ImageResizer.resize` derives the temp
  encode UTType from the SOURCE extension; ImageIO cannot encode WebP, so
  `CGImageDestinationCreateWithURL` returns nil. Reachable from UI; also breaks estimates.
- The resize→compress orchestration is duplicated in `CompressionViewModel.compressSingleFile`
  and `EstimationService.compressSample` (root cause of the double bug).
- `BackupService.backupFiles` runs synchronous FileManager copies on the MainActor → UI freeze.
- Cancel mid-batch leaves `files` out of sync with disk (converted originals deleted, in-place
  files already overwritten) → confusing errors and polluted backups on re-run.
- Unbounded `withTaskGroup` → one `pngquant`/`cwebp` Process per file, hundreds at once.
- Output larger than original still replaces the original, and `ResultRowView` renders "−-12%".
- `CGContext` creation fails for straight-alpha (non-premultiplied) PNGs in `ImageResizer`.
- Temp output files leak on the failure path in `compressSingleFile`.
- Missing tools during estimation fail silently (estimate shows "—" with no explanation).
- No git/README/LICENSE/tests/CI/app-bundle (repo now initialized; rest still missing).

## Global Constraints

- Swift 6 strict concurrency must stay clean: `swift build` succeeds with zero errors AND zero
  new warnings. This is the verify gate for every task.
- Data safety is the top invariant: never delete or overwrite a user's file unless a backup of
  the true original already exists on disk. Preserve the existing temp-file + atomic
  replace/move write pattern.
- Keep the existing architecture: MVVM, small focused files (<400 lines), services as
  enums/static or small classes. No new third-party dependencies in Phase 1 or 2.
- Match existing code style: doc comments explain constraints/why, not what; `let` over `var`;
  early returns; no force unwraps.
- UI copy stays terse and friendly, matching existing strings.
- Never rename the "Uncompressed Backup" folder (users may have existing ones).

## Phase 1 — Correctness & Performance

### Task 1: Extract shared CompressionPipeline; fix WebP-resize and straight-alpha bugs

Create `Sources/Crunch/Services/CompressionPipeline.swift` containing the single
resize→compress orchestration used by BOTH the real run and estimation:

```swift
enum CompressionPipeline {
    struct Output: Sendable {
        let url: URL        // temp file holding compressed result
        let bytes: Int64
    }
    /// Compresses `file` per `settings` into a temp file and returns it.
    /// Caller owns moving/deleting the temp file. Cleans up ALL intermediate
    /// temps (e.g. resize output) itself via defer, including on throw.
    static func run(file: ImageFile, settings: CompressionSettings) async throws -> Output
}
```

Requirements:
1. Move the resize + format-switch + compress logic out of
   `CompressionViewModel.compressSingleFile` (lines ~220-322) and
   `EstimationService.compressSample` into this one type. Both call sites shrink to: call
   pipeline, then handle the result (move-into-place for the real run; read ratio + delete for
   estimation).
2. Fix the WebP-resize bug: `ImageResizer.resize` gains an explicit output UTType/format
   parameter chosen from the TARGET output format, never the source extension. Since ImageIO
   cannot encode WebP: when output format is WebP, resize is always delegated to `cwebp
   -resize` (already the behavior); when the SOURCE is WebP and output is PNG/JPEG, the resize
   temp must be encoded as PNG (lossless intermediate).
3. Fix straight-alpha: in `ImageResizer`, build the destination `CGContext` with
   `.premultipliedLast` (RGBA8) regardless of source alpha info, drawing the source into it.
   Non-alpha sources may use `.noneSkipLast`. `CGContext` creation failure gets its own error
   message (not "Cannot read image").
4. All intermediate temp files cleaned up via `defer` inside the pipeline, on success and
   throw. The returned Output temp is the caller's responsibility.
5. `swift build` clean. Manually trace both call sites compile-and-behave equivalently.

### Task 2: Backup off the main actor; bounded concurrency; truthful state after cancel

All in `CompressionViewModel` + `BackupService`:

1. Make `BackupService.backupFiles` async and run its FileManager work off the MainActor
   (e.g. wrap body in a detached task or make the enum method nonisolated and call from a
   background context). The `.compressing` state must be set BEFORE the backup starts so the
   UI shows progress feedback immediately; add a distinct backup phase representation if
   trivial (e.g. keep `completed: 0` while backing up).
2. Bound compression concurrency to `min(files.count, max(2, ProcessInfo.processInfo.activeProcessorCount))`
   using the standard task-group window pattern (add initial N tasks, add one more as each
   completes). One child task per file overall, but at most N in flight.
3. After a cancelled run (`Task.isCancelled` branch in `runCompression`): reconcile `files`
   with disk before returning to `.loaded` — drop entries whose URL no longer exists (format
   conversions already moved them), and re-read `originalSize` (and refresh any cached
   thumbnail if cheap) for entries that were compressed in place, so a re-run backs up and
   reports honestly. Re-request the estimate afterwards.
4. `swift build` clean.

### Task 3: Never make a file worse + honest results UI + tool-path fallback

1. In the real-run call site (ViewModel, post-pipeline): if `output.bytes >=` the file's
   current on-disk size, do NOT replace/move; delete the temp and record the result as
   "already optimized" — keep original size as compressed size, reduction 0, with a marker.
   EXCEPTION: when the output format differs from the source format (user explicitly asked for
   conversion, e.g. png → webp), always deliver the converted file even if larger.
2. `CompressionResult` gains `wasSkipped: Bool` (or similar) so the UI can distinguish
   "already optimized" from "0% saved". `ResultRowView` shows "Already optimized" in secondary
   style for skipped rows; for conversion rows that grew, show "+N%" in orange (mirror
   `EstimatePreviewView`'s existing branch at lines ~98-112). The "−-12%" double-minus bug
   must be impossible: never format a negative reduction with a hardcoded "−" prefix.
3. `ColorTier` (AppState.swift) gets a distinct tier for grew/skipped so they aren't bucketed
   with small wins.
4. `ToolChecker`: after the three fixed paths miss, fall back to resolving via
   `/usr/bin/which <tool>` through `Process` (or scanning `PATH` env directly — simpler and no
   subprocess: split `ProcessInfo.processInfo.environment["PATH"]` on ":" and stat each dir).
   Keep it synchronous and cheap.
5. Estimation missing-tool surfacing: when `EstimationService.estimate` bails because a tool
   is missing, the ViewModel/UI must learn why. Give `estimate` a way to report
   tool-missing (e.g. return an enum/result instead of bare nil) and show a compact inline
   notice in `EstimatePreviewView` (e.g. "Install pngquant for PNG estimates") instead of a
   silent "—". Keep the copy consistent with `MissingToolsMessage`.
6. `swift build` clean.

## Phase 2 — GitHub-Readiness

### Task 4: App bundle build script + icon

1. Create `scripts/make-app.sh` (executable): builds release (`swift build -c release`),
   assembles `dist/Crunch.app` with proper `Contents/{MacOS,Resources}` layout, a minimal
   `Info.plist` (bundle id `com.paultakisaki.crunch`, name Crunch, version 1.0.0,
   `LSMinimumSystemVersion` 15.0, `NSHighResolutionCapable`, icon file entry), and an
   `AppIcon.icns` generated from the existing `icon_generator.swift` (run it via `swift
   icon_generator.swift`, then `iconutil -c icns`). Ad-hoc codesign the bundle
   (`codesign --force --deep -s - dist/Crunch.app`) so it runs locally; notarization is a
   documented manual step, not in the script.
2. The script must be idempotent, `set -euo pipefail`, and print the final .app path.
3. Verify by RUNNING it: the .app must launch (`open dist/Crunch.app` — verify process starts;
   it's fine to kill it after). `dist/` gets added to `.gitignore`.
4. If `icon_generator.swift` output doesn't work as-is, fix the generator minimally.

### Task 5: Tests

1. Add a test target to Package.swift (`CrunchTests`, Swift Testing framework — `import
   Testing`, `@Test`/`#expect`). This requires the executable target's code to be importable:
   split the target into a library target `CrunchCore` (Models, Services, Utilities — no
   SwiftUI) plus the executable (Views, ViewModels, app entry) depending on it. Keep the move
   mechanical; no logic changes.
2. Tests (filesystem tests use a fresh temp dir per test, cleaned in deinit):
   - `Formatting` byte formatting.
   - `OutputFormat.resolve(for:)` matrix (auto keeps format; explicit converts).
   - `BackupService` — backs up to sibling folder; collision naming produces -1, -2; groups
     by parent dir.
   - `ImageResizer` — resizes a programmatically-generated straight-alpha PNG without
     throwing; output dimensions correct (this pins the Task 1 alpha fix).
   - `CompressionPipeline` JPEG path end-to-end on a generated image (native ImageIO, no
     external tools needed). PNG/WebP paths: only run when the tool resolves, else skip via
     `try #require` / conditional trait — CI may not have pngquant.
3. `swift test` passes locally; note in the report which suites ran vs skipped.

### Task 6: README, LICENSE, CI

1. `LICENSE`: MIT, copyright 2026 Paul Takisaki. (pngquant/cwebp are invoked as external
   processes, not linked or distributed, so MIT is fine.)
2. `.github/workflows/ci.yml`: macOS-15 runner, `swift build` + `swift test`. Badge in README.
3. `README.md` — this is the portfolio centerpiece; structure:
   - H1 + one-line tagline that names the wedge: native, offline, drag-drop image compression
     for the Mac ("Squoosh-class savings, ImageOptim simplicity — native SwiftUI").
   - Placeholder block for hero GIF: `<!-- demo.gif: drag files in → watch estimate → compress -->`
     plus a `docs/` note telling Paul exactly what to record (10-15s screen recording).
   - Features list (live size estimate that runs the real pipeline on a sample; parallel
     compression with cancellation; automatic backups; never makes a file worse; PNG/JPEG/WebP).
   - Install: `scripts/make-app.sh` path + prerequisites (`brew install pngquant webp` — note
     JPEG works with zero dependencies via ImageIO).
   - How it works: short honest section (pngquant/cwebp subprocesses, ImageIO for JPEG,
     temp-file + atomic replace, backup-before-write).
   - Development: `swift run`, `swift test`, architecture one-liner.
   - License badge/footer. No em-dashes in README prose. Keep it tight — screenshot-first,
     few words, no marketing fluff.

## Phase 3 — Delight

### Task 7: Reveal in Finder + drag-out on results

1. `ResultRowView`: context menu + small hover button "Reveal in Finder"
   (`NSWorkspace.shared.activateFileViewerSelecting`). Row is draggable as the compressed
   file URL (`.draggable` / `NSItemProvider` with file URL) so users can drag results
   straight into Slack/Mail.
2. `ResultsView` footer gains "Show in Finder" for the containing folder and "Open Backup
   Folder" when a backup exists for the batch.
3. Requires results to carry their output URL: add `outputURL: URL?` to `CompressionResult`.
4. `swift build` clean; UI matches existing visual style.

### Task 8: AVIF output format (zero new dependencies)

1. Add `.avif` to `OutputFormat` (UI label "AVIF") using ImageIO encoding
   (`CGImageDestinationCreateWithURL` with the AVIF UTType, quality option honored). Encode
   support exists on macOS 15 targets; verify at runtime with
   `CGImageDestinationCopyTypeIdentifiers()` and hide the option if unavailable.
2. Wire through `CompressionPipeline`, estimation, and `ImageFormat` detection (AVIF inputs
   should also be readable — ImageIO decodes AVIF since macOS 13).
3. Resize path: manual `ImageResizer` (PNG intermediate not needed — feed CGImage directly;
   reuse existing flow).
4. `swift build` clean; verify an actual AVIF file is produced and is smaller than the JPEG
   equivalent for a photo-class test image (document the numbers in the report).

### Task 9: Before/after preview slider

The flagship delight feature (Squoosh-style), scoped to fit the existing estimate flow:

1. When files are loaded and an estimate sample has been compressed,
   `EstimationService` keeps the sample's compressed temp output (instead of deleting it) and
   exposes `previewPair: (original: URL, compressed: URL)?` — invalidated/deleted on settings
   change, file removal, and app exit.
2. New `ComparePreviewView`: shows the sample image with a draggable vertical divider —
   original on the left, compressed render on the right, labels "Original / Compressed" and
   sizes underneath. Opens as a sheet/popover from a "Preview" button next to the estimate in
   `EstimatePreviewView`. Zoomable is out of scope; fit-to-view only.
3. Divider drag must be smooth (both images loaded once into `NSImage`/`Image`, clipped with
   a mask — no re-decode per frame).
4. Graceful states: estimating (spinner), sample unavailable (button hidden).
5. `swift build` clean.

## Deferred (explicitly out of scope for this plan)
- Auto perceptual-quality mode (Optimage-style) — needs a quality-metric spike first.
- Clipboard-watch background mode (Clop-style) — second product surface.
- Finder Services menu, Sparkle updates, notarization automation, Homebrew cask (needs a
  public repo + signed release first).
- GIF demo recording (manual step for Paul; README carries instructions).
