# Getting Started

## First Launch

1. **Open your session folder** (Cmd+O) — select the folder containing your FITS or XISF sub-exposures
2. **Wait for caching** — AstroBlink decodes, stretches, and analyzes every frame. Progress shows in the status bar. First-time caching takes 30-90 seconds depending on file count and compression.
3. **Quality scores appear** — once caching completes, every frame gets a quality icon (green/orange/red) based on SmartCull analysis

## Recommended Workflow

1. **Blink through frames** — use arrow keys with key repeat to scan like a flip-book
2. **Check the worst first** — click the Q column header to sort by quality. Trash frames at the top.
3. **Compare borderlines** — press C on any orange frame to see it side-by-side with the group's best
4. **Mark the bad ones** — Space to mark, H to hide marked from the list
5. **Try the Autopilot** — click the quality status pill (bottom bar) for one-click Conservative/Balanced/Aggressive auto-marking
6. **Pre-delete** — Cmd+Backspace moves all marked files to _predel/ staging folder. Nothing is permanently deleted. Full undo with Cmd+Z.
7. **Ask AIsaac** — click the sparkles button for AI-powered session analysis, filter advice, and planning

## AIsaac Quick Start

The glowing purple teaser bar at the top-right says "I am AIsaac — ask me about your stars." Click it to open AIsaac. Load a session first for the best experience.

**Best first question:** Click "Quality Summary" — AIsaac will analyze your entire session and tell you exactly what's good, what's bad, and what to do next.

## Tips

- **Lock STF (S key)** — freeze stretch parameters from one image and apply to all others for brightness comparison
- **Apply All** — bake current stretch + post-processing settings into all cached previews for instant navigation
- **Filter search** — type `filter:Ha` in the search bar to focus on one filter at a time
- **Multi-folder** — Cmd+click multiple folders in the open dialog to merge sessions
- **Night mode (N key)** — red-on-black UI for dark-adapted vision at the telescope

## Format Support

| Format | Compression | Library |
|--------|-------------|---------|
| XISF | Uncompressed, LZ4, LZ4HC, zlib, zstd, ByteShuffle | libxisf |
| FITS | Uncompressed, fpack (Rice, GZIP) | cfitsio |

## System Requirements

- macOS 13 Ventura or later
- Apple Silicon recommended (M1/M2/M3/M4)
- Works on Intel Macs (slower GPU compute)
- ~5 MB app size, ~200 MB RAM for typical sessions
