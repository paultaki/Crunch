# Agent Notes

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
