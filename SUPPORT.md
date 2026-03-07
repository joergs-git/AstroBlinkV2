# Support & Information

**Developer:** joergsflow
**Contact:** joergsflow@gmail.com

---

## Apps by joergsflow

### AstroBlinkV2 — Astrophotography Session Culler (macOS)

Fast visual culling for astrophotography sessions. Blink through hundreds of FITS and XISF sub-exposures in seconds, mark the bad ones, and move them aside — without ever permanently deleting a file.

**Key Features:**
- Metal GPU rendering with PixInsight-compatible STF auto-stretch
- Keyboard-first workflow: arrow keys to blink, Space to mark, Cmd+Backspace to pre-delete
- Full NINA filename parsing and FITS/XISF header extraction
- Session Overview with per-filter integration times and Fact Sheet generator
- Sortable metadata columns (filter, exposure, HFR, star count, temperature, etc.)
- Network volume support with local caching for NAS/SMB shares
- Non-destructive: files are moved to a PRE-DELETE folder, never permanently deleted
- Full undo stack for all operations

**Requirements:** macOS 13 Ventura or later, Apple Silicon recommended

**Formats:** FITS (plain, fpack), XISF (uncompressed, LZ4, LZ4HC, zlib, zstd, ByteShuffle)

---

### AstroFileViewer — FITS/XISF Viewer (iOS / iPadOS)

A simple, focused viewer for astronomical image files on iPhone and iPad. Open FITS and XISF files from the Files app, Safari downloads, AirDrop, or any share sheet — and see your astro images properly stretched and displayed.

**Key Features:**
- Opens FITS and XISF files directly from Files, Safari, AirDrop, or other apps
- PixInsight-compatible STF auto-stretch for proper visualization of linear data
- Pinch-to-zoom (up to 10x) with smooth pan
- FITS/XISF header inspector showing all keywords with important ones highlighted
- Save to Photos as bin2 JPEG (stretched, half-resolution for sharing)
- Supports all common compression: LZ4, LZ4HC, zlib, zstd, fpack (Rice, GZIP)
- Registers as the default handler for .xisf, .fits, .fit, .fts files

**Requirements:** iOS 16.4 or later, iPhone or iPad

---

## Getting Help

### Bug Reports & Feature Requests

Please open an issue on GitHub:
- [github.com/joergs-git/AstroBlinkV2/issues](https://github.com/joergs-git/AstroBlinkV2/issues)

Include:
- Which app and version you're using
- What you expected to happen
- What actually happened
- The file format if relevant (FITS/XISF, compression type)

### General Questions

Email: joergsflow@gmail.com

---

## About the Developer

I'm an astrophotographer who built these tools for my own workflow and decided to share them. You can see my imaging work on Astrobin.

- [Astrobin Gallery](https://app.astrobin.com/u/joergsflow#gallery)
- [Instagram](https://www.instagram.com/joergsflow/)
- [GitHub](https://github.com/joergs-git)

---

## Open Source

Both apps are open source under the **GNU General Public License v3.0**.

Source code: [github.com/joergs-git/AstroBlinkV2](https://github.com/joergs-git/AstroBlinkV2)

Libraries used:
- **libxisf** (GPLv3) — XISF 1.0 file format reader
- **cfitsio** (NASA Open Source) — FITS file format reader

---

*Clear skies and happy imaging!*
