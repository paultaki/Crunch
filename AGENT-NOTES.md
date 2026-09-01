# Agent Notes

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
