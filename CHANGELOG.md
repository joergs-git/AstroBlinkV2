# Changelog

All notable changes to AstroBlinkV2 will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [3.7.0] — 2026-03-13

### Added
- **Benchmark Sharing & Leaderboard**: Share your stacking and session load benchmarks anonymously with the community. See how your machine ranks against others. Powered by Supabase with privacy-first design (only hardware specs and timing shared, machine identity is a non-reversible SHA256 hash).
- **Session Load Benchmarks**: New "Session Load" tab in the leaderboard — compare file scanning, first image display, header reading, and pre-caching performance across machines. Ranked by MB/s throughput, auto-detects local SSD vs network storage.
- **Sortable Leaderboard Columns**: Click any column header to sort ascending/descending. Active sort column highlighted with chevron indicator. Secondary sort by primary metric on ties.
- **Release Notes in Help Menu**: "What's New" menu item shows release notes for each version directly inside the app.
- **Share & Compare Button**: Green prominent button in Quick Stack result windows and Benchmark Stats window. Uploads benchmark and opens the community leaderboard.
- **Speedometer Toolbar Icon**: Quick access to Benchmark Stats from the main toolbar.
- **Duplicate Prevention**: Identical benchmarks are detected before upload and silently skipped.

### Changed
- **Toolbar Layout**: Thin separator line between toolbar icons and image settings row. Image settings (stretch, sharp, contrast, dark) are now centered. MeridianFlip toggle moved to toolbar row 1 between Lock STF and Apply All.
- **Reset Button**: Now shows icon + "Reset" label for clarity.
- **Toolbar Spacing**: Slightly increased padding between main toolbar icons.
- **Leaderboard Ranking**: Stacking benchmarks ranked by t/frame (seconds per frame) instead of absolute time for fair comparison across different frame counts. Added ms/MP/frame metric for cross-resolution comparison.

## [3.6.0] — 2026-03-12

### Added
- **GPU-Accelerated Star Metrics**: HFR (Half-Flux Radius) and FWHM (Full Width at Half Maximum) are now automatically computed for every image during session loading using GPU star detection + CPU Gaussian fitting. No external software or FITS header data required.
- **ROTATOR-based Meridian Flip Detection**: For mounts without PIERSIDE header (e.g. ZWO ASIAIR on AM5), AstroBlinkV2 now detects meridian flips from the ROTATOR angle (~180° change).
- **"Night" column**: New default-visible column showing the astronomical observing night (evening date). Images captured after midnight are correctly attributed to the previous evening's session.
- **Header Inspector: Copy support**: Multi-row selection with Cmd+Click/Shift+Click, Cmd+C to copy selected rows as "KEY = VALUE" lines, plus a "Copy All" button.
- **Quality score tooltips**: Hovering over the Q column now explains the score meaning or why it's empty (e.g. "needs ≥20 images per group").

### Changed
- **Column order**: Quality metrics (Q, SNR, FWHM, HFR) now grouped together right after Filter for quick scanning. "Date" column moved to hidden-by-default (replaced by "Night").
- **Observing night grouping**: Quality scoring and Session Overview now group by astronomical night (evening date) instead of calendar date. Sessions spanning midnight are no longer split into two groups.
- **Star detection shared**: Extracted star detection into shared `StarDetector` utility used by both QuickStack engines and the new star metrics pipeline.

### Fixed
- **FWHM computation**: Replaced coarse 0.5px annuli radial profile (always returned ~2.50) with linearized Gaussian fit for accurate, per-star FWHM values.
- **Star metrics coverage**: Relaxed star filtering criteria (saturation 95%→98%, edge margin 15→12px, crowding distance 20→15px, min stars 3→2) so more images get computed metrics.
- **Stars column**: No longer shows internal measurement count (capped at 30). Only displays header/filename-sourced star counts to avoid confusion.

## [3.5.1] — 2026-03-11

### Fixed
- UTI declarations: removed exported UTIs, use standard identifiers

## [3.5.0] — 2026-03-10

### Added
- Quality scoring with noiseMAD metric
- Filename column moved right in default order

## [3.4.0] — 2026-03-08

### Added
- LightspeedStacker (V2): GPU-accelerated stacking engine
- Benchmark Stats window
- ZoomableTextureMTKView for Quick Stack results
