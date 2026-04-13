# Getting Started

## First Launch

1. **Open your session folder** (Cmd+O) — select a folder containing FITS/XISF sub-exposures. You can also pick multiple folders, multiple individual files, or a mix of files and folders; everything gets merged into one session. Loose files at the parent level are merged with any subfolder contents automatically (e.g. `M97/` with `Ha/`, `OIII/`, `SII/` subdirs plus a stray master frame at root — you'll see all of them).
2. **Wait for caching** — AstroBlink decodes, stretches, and analyzes every frame. Progress shows in the status bar. First-time caching takes 30-90 seconds depending on file count and compression.
3. **Quality scores appear** — once caching completes, every frame gets a quality icon (green/orange/red) based on SmartCull analysis

## Recommended Workflow

1. **Blink through frames** — use arrow keys with key repeat to scan like a flip-book, or hit Play for auto-blink with adjustable delay (0.1–2s)
2. **Check the worst first** — click the Q column header to sort by quality. Trash frames at the top.
3. **Compare borderlines** — press C on any orange frame to see it side-by-side with the group's best
4. **Mark the bad ones** — Space to mark, H to hide marked from the list
5. **Try the Autopilot** — click the auto-mark button (wand icon) in the toolbar for one-click Conservative/Balanced/Aggressive auto-marking. Session Spread stats and convergence guard help you decide when to stop culling.
6. **VLM Check** — click the eye icon in the toolbar to generate mosaic wallpapers and run Claude Vision anomaly detection. Catches ice crystals, dew, clouds, and obstructions that metrics miss. Click tiles to mark, or "Mark All Flagged" for batch marking.
7. **Pre-delete** — Cmd+Backspace moves all marked files to _predel/ staging folder. Nothing is permanently deleted. Full undo with Cmd+Z.
8. **Ask AIsaac** — the collapsible AIsaac window floats on top with preset chips for instant analysis, filter advice, and session planning

## AIsaac Quick Start

AIsaac starts as a compact floating window with preset chips and an input field — always on top. Click the title "AIsaac's AstroBlink" or start typing to expand to the full chat view. Load a session first for the best experience.

**Best first question:** Click "Quality Summary" — AIsaac will analyze your entire session and tell you exactly what's good, what's bad, and what to do next. AIsaac always includes local weather, seeing, and moon data in every response.

## Tips

- **Lock STF (S key)** — freeze stretch parameters from one image and apply to all others for brightness comparison
- **Apply All** — bake current stretch + post-processing settings into all cached previews for instant navigation
- **Filter search** — type `filter:Ha` in the search bar to focus on one filter at a time
- **Multi-folder / mixed selection** — Cmd+click multiple folders and/or individual files in the Open dialog to merge them into one session. PRE-DELETE lands at the deepest common ancestor (with a one-time confirmation sheet on the first delete so you know exactly where). PRE-DELETE folders themselves are auto-skipped during recursion, but you can open one directly as the top-level folder to review or restore previously culled frames.
- **Right-side Session panel** — click "Session" in the toolbar to show/hide the group stats sidebar. Your choice sticks across folder opens AND app restarts (iCloud-synced).
- **Night mode (N key)** — red-on-black UI for dark-adapted vision at the telescope
- **Target Catalog** — open Window > Target Catalog to browse 533+ deep-sky objects with visibility charts, weather, FOV simulation, and filter gap analysis. Great for planning your next session before heading outside.

## Format Support

| Format | Compression | Library |
|--------|-------------|---------|
| XISF | Uncompressed, LZ4, LZ4HC, zlib, zstd, ByteShuffle | libxisf |
| FITS | Uncompressed, fpack (Rice, GZIP) | cfitsio |

## System Requirements

- macOS 14 Sonoma or later
- Apple Silicon recommended (M1/M2/M3/M4)
- Works on Intel Macs (slower GPU compute)
- ~5 MB app size, ~200 MB RAM for typical sessions
