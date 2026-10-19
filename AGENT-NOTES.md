# Agent Notes

## 2026-10-19 · claude-code — concurrent drop ingestion

- **Did:** Made drop ingestion concurrent and order-preserving. `ImageFile.loadBatch(from:)`
  is new in `CrunchCore`: it decodes a batch in a task group where each child writes its own
  index-keyed slot, so results come back in the order they were given even though they finish
  out of order. `CompressionViewModel.addFiles` now strides the deduped URLs in batches of 32
  and appends each batch as it lands, so a big folder fills the list progressively instead of
  showing nothing until the last thumbnail decodes. Measured on this Mac (32 cores, best of
  three, page cache warm, real `ImageFile.load`): 60 files at 2000x1500 **549 ms -> 32 ms
  (17.2x)**, 300 files **2749 ms -> 171 ms (16.1x)**, 64 photo-sized 4032x3024 files
  **2319 ms -> 119 ms (19.5x)**. First rows now land at ~18 ms on the 300-file drop instead of
  at the 2.7 s mark. 49 tests in 11 suites green (46 before, plus 3 for `loadBatch`).
- **Why:** The old comment claimed "the thumbnail work is cheap enough that parallelism isn't
  worth the reorder cost". Measurement says otherwise, and the reorder cost is one array of
  optionals. 31 of 32 cores sat idle while the user waited on a folder drop.
- **Next:** **Part 2 of this task is NOT done and is deliberately deferred** — removing the
  resize disk round trip (`ImageResizer.resize` encodes a throwaway lossless PNG to the system
  temp dir, ~8.7 MB per resized photo, which the next compressor immediately re-decodes; also
  the one staging path that ignores the `StagingArea` volume rule and lands on the boot volume
  even when the user's files are on an external drive). It edits the same four compressors a
  sibling session is changing for EXIF/ICC metadata preservation
  (branch `claude/objective-visvesvaraya-4d3c56`, in flight, 0 commits ahead of main at the
  time of writing). Pick it up after that work merges. Prior measurement: 110 ms -> 22 ms on a
  4032x3024 JPEG resized 50% then compressed to JPEG q80.
- **Watch out:** Three things that look like tidy-ups but are not. (1) The index-keyed slot
  array in `loadBatch` is the ordering guarantee — `Tests/CrunchTests/ImageFileLoadBatchTests.swift`
  fails on an append-as-completed rewrite, verified by actually breaking it. (2)
  `loadBatchSize` must stay `nonisolated`: `CompressionViewModel` is `@MainActor`, which
  isolates even its immutable statics, and the detached loop cannot read it otherwise. (3)
  `addFiles` now calls `appendLoaded` once per batch rather than once per drop, so
  `requestEstimate` fires up to one call per batch; that is safe only because `requestEstimate`
  cancels the previous task and debounces 400 ms, which coalesces them into one estimate.
  Also: committed on `claude/unruffled-jepsen-1fb9a1`, **not pushed and not merged to `main`**. The 32 batch size was tuned on a 32-core Mac; a 4-core machine will see a smaller
  multiple, never a worse one than serial.

## 2026-10-19 · claude-code — metadata preservation fix

- **Did:** Fixed the metadata data-loss bug written up as audit item 01 — Crunch discarded
  **all** image metadata on every compression, so capture date, camera, GPS and EXIF
  orientation vanished and a phone photo came out visibly rotated 90°. Each format lost it for
  a different reason, so each needed a different fix. New `ImageMetadata` reads the preserved
  dictionaries (Exif/ExifAux/TIFF/GPS/IPTC + Orientation) off the user's original and merges
  them into the ImageIO destination options for JPEG and AVIF. cwebp strips by documented
  default, so WebP now passes `-metadata all`. pngquant on macOS strips by default *and has no
  flag to stop it* (`--help`: "remove optional metadata (default on Mac)"), so new
  `PNGMetadataWriter` splices a freshly-minted `eXIf` chunk into pngquant's finished output by
  chunk surgery — no re-encode, IDAT untouched, output actually ends up smaller because the
  bulky XMP chunk goes away. New `OrientationBaker` handles the one case no tag can cover:
  ImageIO's AVIF encoder discards orientation unconditionally, so AVIF rotates the pixels
  instead. Added the `stripMetadata` setting and a "Strip metadata" toggle in `ControlsView`,
  defaulting to preserve. 66 tests (was 46), all green.
- **Why:** Silent, unrecoverable data loss on every single run, with a visible symptom
  (rotation) that most users would blame on their phone.
- **Next:** The original audit's remaining items. Worth considering whether `ImageFile` should
  expose orientation-corrected dimensions — the UI's thumbnail honours orientation but
  `pixelWidth`/`pixelHeight` are raw, so the resolution percentages describe the stored buffer
  rather than the photo as displayed. Not wrong today, just inconsistent.
- **Watch out:** Metadata is threaded from `file.url` (**the user's original**), never from the
  compressor's input, and this is load-bearing rather than stylistic — under a resize the
  pipeline hands the compressor an `ImageResizer` temp with no metadata at all, so the naive
  "read it from the input" fix preserves everything at 100% resolution and silently loses it at
  99%. There is a test that fails specifically on that mistake. Two more traps: a placeholder
  used to mint an `eXIf` payload must match the OUTPUT's dimensions, because ImageIO stamps the
  EXIF pixel-dimension tags from whatever image it writes (a 1x1 placeholder yields a payload
  claiming 1x1); and `CGImageDestinationCopyImageSource` is the wrong tool here despite looking
  right — it swaps metadata on *already-encoded* bytes and so cannot apply a quality, which is
  the entire job. Stripping deliberately keeps orientation: it is a rendering instruction, not
  information about the user, and dropping it just returns sideways photos. For WebP that costs
  a lossless-PNG normalize hop (measured 1.5s -> 2.5s on a 4032x3024 photo) because cwebp
  copies metadata wholesale or not at all — but only when stripping a non-upright source.

## 2026-10-19 · claude-code — source and benchmark audit

- **Did:** Source + benchmark audit of the whole app (no code changed). Produced a ranked
  top-10 improvement roadmap across delight / performance / efficiency / simplicity. Four
  measurements taken on this Mac (32 cores, APFS): resize-to-JPEG of a 12 MP photo is
  **110 ms via the current PNG-temp round trip vs 22 ms in memory (5x)**, with an **8.7 MB
  throwaway lossless PNG per resized file**; `addFiles` thumbnail ingestion is **1116 ms
  sequential vs 70 ms concurrent for 60 files (16x)**, extrapolating to **9.3 s vs 0.6 s for
  a 500-file drop**. Suite re-run green: 46/46.
- **Why:** Asked for the highest-value remaining improvements. Everything is cited to file
  and line so the fixes can be picked up without re-deriving them.
- **CONFIRMED BUG (reproduced, highest priority):** `JPEGCompressor` and `AVIFCompressor`
  decode to a bare `CGImage` and write it with only a quality key, so **all source metadata
  is discarded**. A probe built a JPEG with `Orientation 6` + EXIF and ran the exact calls at
  `JPEGCompressor.swift:9-28`: orientation, `DateTimeOriginal`, `UserComment` and TIFF `Make`
  all came back `ABSENT`. Practical effect: **a phone photo stored as landscape pixels plus an
  orientation tag comes out of Crunch visually rotated 90 degrees**, and capture date / camera /
  GPS are gone. `grep -rn "kCGImageProperty|Orientation|Exif" Sources/` finds no handling
  anywhere. Fix: pass `CGImageSourceCopyPropertiesAtIndex` into `CGImageDestinationAddImage`,
  add `-metadata all` to the `cwebp` args, then offer an explicit strip-metadata toggle.
- **Next:** Fix the metadata bug first with a per-format round-trip test. Then the two measured
  perf items (return a `CGImage` from `ImageResizer`; concurrent order-preserving ingestion).
  Then `CFBundleDocumentTypes` + `NSServices` + `@AppStorage`, which is the biggest reach win.
- **Watch out:** Two plausible-sounding changes are **wrong** and should not be made.
  (1) `FileManager.copyItem` **already APFS-clones** — 40 x 5 MB copied in 6 ms consuming ~0 MB,
  so there is no win in switching `BackupService` to `clonefile(2)`; the backup issue is clutter
  and missing restore, not speed. (2) `ToolChecker`'s no-cache re-stat measured **0.007 ms** per
  compression over a 32-entry `PATH`; the "effectively free" comment is accurate, leave it alone.
  Also: the `cwebp` metadata claim is inferred from its documented default, not reproduced —
  probe it before fixing. Roadmap: https://claude.ai/artifact/Ue6MWG2k3XPiN6zWQ9rj4i

## 2026-09-02 · claude-code

- **Did:** Published the repo to GitHub as **public** at `paultaki/Crunch` and pushed `main`
  (25 commits). Pre-flight before going public: `git grep` for credential patterns and
  `/Users/paul` paths over all tracked content (clean), confirmed `.gitignore` keeps `.build/`,
  `dist/`, `.remember/`, `.superpowers/`, and `.DS_Store` out, and re-ran the suite: 46 tests
  in 10 suites, all green. First CI run on `macos-15` passed in 45s. Added the description and
  eight topics (macos, swift, swiftui, image-compression, image-optimization, webp, avif,
  pngquant).
- **Why:** Last remaining launch item. The demo GIF landed in b682189, so the repo had nothing
  left blocking a public push.
- **Next:** Manual QA of the built `dist/Crunch.app` on a real photo folder (still unticked from
  the 08-30 launch checklist). Consider a tagged release with a zipped `.app` so people can try
  it without building.
- **Watch out:** The README CI badge hardcodes `paultaki/Crunch`, so renaming the repo silently
  breaks it. CI logs one deprecation annotation: `actions/checkout@v4` targets Node.js 20 and is
  being force-run on Node 24, harmless today, bump to `@v5` when convenient. The app is only
  ad-hoc signed and not notarized, so anyone downloading a prebuilt binary hits Gatekeeper.


## 2026-09-01 · claude-code (round 2)

- **Did:** Addressed two independent reviews of the `fix-cross-volume` branch. (1) Replaced
  round 1's "stage in the destination directory" with `StagingArea`, which uses
  `.itemReplacementDirectory` to get a private directory on the destination's *volume* but
  outside the user's folder, with a fallback ladder (replacement dir -> destination dir ->
  throw) and whole-directory cleanup. Rename fails across volumes, not directories, so round 1
  was a bigger hammer than needed and leaked image files into folders iCloud/Dropbox/Spotlight
  watch. (2) Closed a real data-loss hole: `.fileSize` on an empty file is `Optional(0)`, not
  nil, so a 0-byte output unwrapped cleanly, passed the never-worse guard, and would be
  delivered onto the user's photo. Now guards `fileSize > 0`; the writability probe is deleted
  (it had become the hazard it was meant to prevent). (3) Summary bar no longer paints a batch
  that *grew* the files green. 46 tests, incl. `CompressionJob`'s first direct tests.
- **Why:** Round 1 fixed the crash but with the wrong staging location, and left the more
  dangerous bug open.
- **Next:** Merge `fix-cross-volume` to `main`; re-shoot the demo on the external volume.
- **Watch out:** `FileManager.url(for: .itemReplacementDirectory, appropriateFor:)` does NOT
  throw when it can't resolve the volume — it silently returns a *boot-volume* directory, which
  would reintroduce the cross-device bug with no error anywhere. `StagingArea` verifies the
  volume identifiers match and falls back rather than trust it. Any future use of that API
  needs the same check. Also: the staging cleanup obligation is an optional URL, not a bool,
  because on the fallback rung the staging directory IS the user's folder.

## 2026-09-01 · claude-code

- **Did:** Fixed two bugs found testing the shipped app on an external drive (branch
  `fix-cross-volume`). (1) CRITICAL: `CompressionPipeline` staged its output temp in the
  system temp dir (boot volume), so `replaceItemAt`/`moveItem` delivery failed with POSIX 18
  "Cross-device link" for every file on a non-boot volume. The pipeline now takes an explicit
  `stagingDirectory`; `CompressionJob` passes the destination's own folder, `EstimationService`
  keeps system temp. Staging file is dot-prefixed; an unwritable folder throws
  `CompressionError.cannotStageOutput` with no cross-volume fallback. (2) HIGH: results totals
  used `compactMap(\.compressedSize)`, so an all-failed batch rendered as "SAVED 29.7 MB /
  100% REDUCTION". New `BatchSummary` (CrunchCore) computes successes-only totals plus
  outcome counts; header reads "8 of 11 compressed, 3 failed" and an all-failed batch gets a
  red failure notice instead of the green savings bar.
- **Why:** The app was unusable off the boot disk and the summary lied about it.
- **Next:** Merge `fix-cross-volume` to `main`; re-shoot the demo recording on the external
  volume now that delivery works.
- **Watch out:** An atomic replace is only guaranteed within one directory — any future code
  that writes a temp destined for a user file must stage it in that file's own folder. The
  probe file the pipeline creates to test writability is deleted again on purpose, so a
  compressor that exits clean without writing still fails the size check instead of producing
  a 0-byte "output" that would sail past the never-worse guard. Verified end to end on a real
  external APFS volume (`/Volumes/Untitled 2`, scratch folder, removed after).

## 2026-08-30 · claude-code

- **Did:** Full polish pass for GitHub publication (18 feature/fix commits + 3-commit final
  fix wave on `polish-v1`, merged to `main`). Phase 1: extracted shared CompressionPipeline,
  fixed WebP-resize + straight-alpha bugs, off-main backup, bounded cancellable concurrency,
  truthful cancel state, never-worse guard. Phase 2: CrunchCore/Crunch/CrunchTests split
  (30 tests), README, MIT LICENSE, CI workflow, `scripts/make-app.sh` app bundler. Phase 3:
  reveal-in-Finder/drag-out, AVIF output via ImageIO (32.6% smaller than JPEG at q80),
  Squoosh-style before/after preview slider. Final gate: Fable whole-branch review + Grok
  second opinion (11 real findings incl. 1 critical un-backed-up-compression hole), all fixed
  and re-review clean.
- **Why:** Paul wants to publish Crunch on GitHub as a portfolio piece.
- **Next:** Record `demo.gif` per `docs/recording-notes.md`; manual QA (drag result row to
  Desktop, hover reveal button, context menu, preview sheet resize, 5-segment picker look);
  confirm GitHub slug (badges assume `paultaki/Crunch`) and push; later: notarization,
  Homebrew cask, Sparkle.
- **Watch out:** pngquant/cwebp are runtime prerequisites (PATH-scanned); AVIF availability is
  runtime-gated via `CGImageDestinationCopyTypeIdentifiers`; the never-worse guard exempts
  explicit format conversions by design; "Uncompressed Backup" folder name is a frozen
  contract.
