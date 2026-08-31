# Hero GIF recording notes

The README references `demo.gif`, which doesn't exist yet. Record it and drop it at the repo root as `demo.gif` (or update the README path if you put it elsewhere, e.g. `docs/demo.gif`).

## What to capture

10-15 seconds, screen recording of the actual app window, no narration needed:

1. Start with the app window empty (drop zone visible).
2. Drag 4-6 image files (mix of PNG and JPEG works well) onto the window.
3. Let the live size estimate appear (the "estimated size" readout updates after ~400ms).
4. Click Compress.
5. Let it run to completion, results view showing the per-file before/after sizes.

## How to record

- `Cmd+Shift+5` (or QuickTime Player → New Screen Recording), select just the app window, no audio.
- Trim tightly, cut any dead air before the drag starts or after results settle.
- Convert to a GIF (`ffmpeg`, Gifski, or similar) and keep it under a few MB so it loads fast on the README. A rough target: 800px wide, 12-15fps is plenty for UI motion.

```
ffmpeg -i demo.mov -vf "fps=15,scale=800:-1:flags=lanczos" -c:v gif demo.gif
```

or use Gifski for better compression/quality tradeoff on the same source.

## Where it goes

Place `demo.gif` at the repo root and it will render directly under the `<!-- demo.gif: ... -->` placeholder comment in `README.md`. If you'd rather keep it under `docs/`, update the placeholder to reference `docs/demo.gif` instead.
