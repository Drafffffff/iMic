# CRT HiDPI verification · 2026-11-02

These are review artifacts for `docs/tasks/2026-11-02-site-crt-hidpi.md`, not golden image assertions. Before: `418392e`; after: the accompanying change. The only server was this worktree's `python3 -m http.server 48764 --bind 127.0.0.1 --directory site`.

Chrome: **156.0.8078.76**, `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`. Canvas sessions used `--enable-blink-features=CanvasDrawElement`; CSS sessions omitted the flag and confirmed the API was absent. No production pages were used for screenshots.

- `*-matrix.webp`: full first-screen before/after pairs for each language and rendering path. Rows are 1440×900 DPR 1, 1440×900 DPR 2, 2560×1440 DPR 1, 2560×1440 DPR 2. Left: before; right: after. Each screenshot is reduced to 720 px wide for the contact sheet.
- `*-dpr2-before.webp` / `*-dpr2-after.webp`: original 2880×1800 screenshots for the 1440×900 DPR 2 canvas cases, losslessly encoded.
- `glitch-dpr2.webp`: real canvas tearing during an `imic:glitch` event.
- `fallback-scale.webp`: readable CSS title after injecting a 1.5× draw transform.
- `before-results.json`: 16 baseline configurations, native image sizes, draw geometry, and CDP mouse selections.
- `after-results.json`: all 16 configurations plus 4 DPR transitions, 2 injected failures, and a simulated void-return API case: **23 passed**.
- `browser-{css,canvas}-results.json`: complete site suite, **68/68 passed** in each mode. `python3 tools/check-site.py` also passed (4 HTML pages, 42 files, references/accessibility attributes/budgets).

At 1440×900 the Chinese native element image grows from 527×170.5625 at DPR 1 to 1054×341.125 at DPR 2. The original additional context transform doubles its CSS drawing geometry. Explicit destination dimensions with an identity context transform fix both rows without changing the real heading. Every matrix case uses CDP mouse press/move/release to select the complete title exactly once.

The installed Chrome unexpectedly still returns a DOMMatrix. That native return path is tested; the documented newer void return with automatic geometry synchronization is emulated in the dedicated test. **No Chrome earlier than 155 was available**, so its binary behavior remains unverified. DPR changes are CDP device-metrics changes at a fixed CSS viewport (1 → 2 → 1.25 → 3 → 1), exercising the zoom/cross-display resolution path; physical window dragging and browser keyboard zoom were not manually tested.

Reproduce from the worktree:

```sh
IMIC_SITE_URL=http://127.0.0.1:48764/ node tools/test-site-crt.mjs after
IMIC_SITE_URL=http://127.0.0.1:48764/ \
  AGENT_BROWSER_EXECUTABLE_PATH='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
  node tools/test-site-browser.mjs
IMIC_SITE_URL=http://127.0.0.1:48764/ \
  AGENT_BROWSER_EXECUTABLE_PATH='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
  AGENT_BROWSER_ARGS='--enable-blink-features=CanvasDrawElement' \
  node tools/test-site-browser.mjs
python3 tools/check-site.py
```

Run `test-site-crt.mjs before` on the baseline to record without size assertions. The tools write original PNGs and JSON under ignored `build/`; committed WebP images are lossless evidence exports (contact sheets additionally resample to the labeled thumbnail size).
