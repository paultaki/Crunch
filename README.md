# Crunch

[![CI](https://github.com/paultaki/Crunch/actions/workflows/ci.yml/badge.svg)](https://github.com/paultaki/Crunch/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Native, offline, drag-and-drop image compression for the Mac. Squoosh-class savings, ImageOptim simplicity, native SwiftUI.

<!-- demo.gif: drag files in → watch estimate → compress -->

See `docs/recording-notes.md` for exactly what to capture.

## Features

- Drag and drop a batch of images and compress them all at once.
- Live size estimate before you commit: it runs a real file through the actual compression pipeline (not a guess) and extrapolates to the batch, debounced and cached so dragging a slider stays smooth.
- Compression runs in parallel, bounded to your CPU core count, with working cancellation mid-batch.
- Originals are copied to an `Uncompressed Backup` folder next to the source files before anything is overwritten.
- Never makes a file worse: if the compressed output isn't smaller than the original, the original is left alone and the result is reported as "Already optimized." Explicit format conversions (say, PNG to WebP) always deliver, even if the converted file happens to be larger.
- PNG, JPEG, and WebP, including conversion between the three and resolution scaling.
- Writes are atomic: compress to a temp file, then replace the original in place, so a crash or kill mid-run can't leave a half-written file.
- If pngquant or cwebp aren't installed, Crunch tells you inline and gives you the install command instead of failing silently.

## Install

```
scripts/make-app.sh
```

This builds a release binary and assembles `dist/Crunch.app`, ad-hoc signed and ready to run. Not notarized; running it the first time requires right-click → Open, or removing the quarantine flag.

Prerequisites for PNG and WebP compression:

```
brew install pngquant webp
```

JPEG compression works with zero external dependencies, it uses ImageIO natively.

## How it works

PNG compression shells out to `pngquant`, WebP to `cwebp`. Both are located at runtime by checking `/opt/homebrew/bin`, `/usr/local/bin`, and `/opt/local/bin` in order, then falling back to a `PATH` scan. JPEG is handled entirely in-process via ImageIO, no subprocess involved.

Every compression writes to a temp file first, then atomically replaces the original (`FileManager.replaceItemAt`) so a partial write never corrupts a source file. Before any of that happens, the batch is copied to `Uncompressed Backup` in the same folder as the originals.

## Development

```
swift run    # launch the app
swift test   # run the test suite
```

The package splits into a `CrunchCore` library (models, services, utilities: the compression pipeline, backup, tool discovery) and a `Crunch` executable (SwiftUI views and view models). `CrunchTests` covers `CrunchCore` with Swift Testing; the PNG and WebP suites skip automatically when `pngquant`/`cwebp` aren't on the machine running the tests, which is the expected state in CI.

Requires macOS 15+ and Swift 6.

## License

MIT, see [LICENSE](LICENSE).
