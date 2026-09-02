# Agent Notes

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
