# Changelog

All notable changes to AstroBlinkV2 will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [3.13.0] — 2026-03-14

### Added
- **Help: Background Tab** — Comprehensive FAQ-style documentation covering quality scoring (4-tier system with z-scores), metric bars, smart 4-case column sorting, STF stretching algorithm, debayering, denoise, deconvolution, triage tips.
- **4-Tier Quality Icons** — Full green (excellent), half-green (good), orange (borderline), red (garbage). Z-score shown on hover. Fine-grained sorting within tiers via raw z-score.
- **Compare with Best (C key)** — Side-by-side comparison with synchronized zoom/pan against the best frame in group. Opens maximized at 300% zoom. ESC to close.
- **Metric Bar Indicators** — Per-group red-to-green bars below Stars, FWHM, HFR, SNR values showing relative ranking within the same target+filter+exposure group.
- **Context Menu Enhancements** — Open With... (PixInsight, etc.), Show in Finder, Compare with Best.
- **Pitch-Black Frame Detection** — Frames with no stars and no noise data (camera failure, shutter stuck) marked as garbage.
- **Splash "Don't show on startup"** — Checkbox to suppress splash screen on launch.

### Changed
- **Smart Column Sorting** — 4-case auto-sort by session type with exposure as grouping element. Sort fires once after initial precache using recommended order (not saved layout).
- **Quality Scoring Refinements** — Two-stage detection, star weight 1.2x, narrowband 25% garbage threshold, FWHM/HFR sort ascending.

### Fixed
- **FITS Special Characters** — `fits_open_diskfile` replaces `fits_open_file` for bracket/parenthesis support.
- **Initial Sort Timing** — Sort correctly fires after first precache completes, regardless of saved UserDefaults column order.
- **PNG Export Colors** — RGBA vs BGRA pixel format check prevents R/B channel swap.
- **vDSP STF Bug** — Fixed `vDSP_vsadd` scalar parameter misuse in preview STF computation.

## [3.12.0] — 2026-03-14

### Added
- **Double-Click Image Preview**: Open any image in a floating window with Stretch, Sharp, Contrast, Dark, Color, Denoise, and Deconvolution sliders. Multiple windows for side-by-side comparison.
- **GPU Bilateral Denoise**: Two-pass noise reduction — bilateral filter (pixel noise) + chrominance denoise in YCbCr (color patches). 0-200% slider.
- **Richardson-Lucy Deconvolution**: Iterative GPU deconvolution with Gaussian PSF. Toggle between RL and multi-scale Unsharp Mask (USM). 5-20 iterations.
- **OSC Debayer in Stacking**: Color camera images debayered (GPU bilinear) before stacking — full-color stacked results.
- **Hot/Cold Pixel Rejection**: GPU cosmetic correction before stacking — sigma-clipped median detects and replaces hot/cold pixels.
- **Color Saturation Slider**: 0-3x saturation control in all result windows (RGB images only).
- **Leaderboard Latest Badge**: Most recent personal entry highlighted with bold fonts and green "LATEST" badge.

### Changed
- **True Star Count**: Stars column shows actual total detected stars (GPU atomic counter), not capped at 50.
- **Dynamic Column Order**: Auto-reorder columns based on single vs multi-object sessions after header enrichment.
- **Center-Crop Quality (70%)**: HFR, FWHM, noise stats measured from center 70% of image — excludes edge optical effects.
- **Per-Channel STF Stretch**: Unlinked per-channel c0/mb with Linked toggle. Precomputed from full-res data via STFCalculator.
- **Benchmark Icon**: Medium dark green speedometer icon.
- **Benchmark Default Tab**: Session Load tab shown by default when no stacking data.
- **File List Auto-Focus**: Keyboard focus set to file list after initial load for immediate arrow key navigation.

### Fixed
- **PNG Export Colors**: Correct RGBA/BGRA handling — red channel no longer swapped with blue.
- **vDSP STF Bug**: Fixed vDSP_vsadd API misuse (&scalar vs [scalar]) that corrupted MAD computation in preview STF.
- **Splash Dismiss**: Splash screen dismisses on any click (inside or outside window).
- **Stretch Slider**: Precomputed STF params only used at default 25% — slider adjustments now recompute correctly.

## [3.10.0] — 2026-03-13

### Added
- **About / Splash Screen**: Custom About window replacing standard macOS panel. Shows app icon, version, social links, Tell a Friend share sheet, What's New button, and App Store link. Displays as splash on launch (auto-dismiss after 6s or click outside).
- **Tell a Friend**: Native macOS share sheet for recommending AstroBlinkV2 — available in About window and Release Notes.

### Changed
- **Quality Scoring**: Cross-night comparison by default. Groups by filter + target + exposure only (removed night grouping). Consistently bad nights now score lower overall instead of being judged only within their own night.
- **Toggle Order**: Toolbar toggles reordered to Apply All → Debayer → Lock STF → MeridianFlip for consistent left-to-right workflow.
- **Benchmark Icon**: Light blue speedometer, positioned right of Night toggle.
- **Leaderboard Chip Column**: Left-aligned header to match textual column content.
- **Toolbar Cleanup**: Removed MEM/CPU system stats from toolbar row 1.

### Fixed
- **Star Column Empty**: `displayStarCount` now includes GPU-computed star count (`computedStarCount`), not just NINA-sourced `starCount`.
- **Spacebar Marking**: Keyboard-highlighted rows now correctly toggle pre-delete marks. Works with multi-selection and filtered views (hideMarked, showOnlyMarked, search filter).
- **Benchmark Total Ready Time**: `totalSessionDuration` is now a frozen stored value instead of a computed property. Stops counting once both caching and header enrichment complete.
- **Lock STF Darkening**: Locking STF while showing a cached preview no longer causes images to go dark. Current image is decoded first to capture correct STF params.
- **Stretch Slider + Lock STF**: Moving the stretch slider while STF is locked now recalculates STF params AND re-freezes the lock, so the change is visible.
- **Reset Sliders**: Reset now restores `applyAllEnabled = true`, matching the exact state after initial folder load.

## [3.9.0] — 2026-03-13

### Added
- **Anti-Moiré Trilinear Filtering**: GPU mipmap generation + trilinear sampler eliminates moiré artifacts when images are zoomed out on lower-resolution screens (MacBook 13"/14"). Pixel-accurate nearest-neighbor zoom preserved when zoomed in.
- **Leaderboard Copy Button**: Copy entire leaderboard as tab-separated text for pasting into spreadsheets or forums.

### Changed
- **Leaderboard Layout**: Proper column alignment with consistent spacing, increased font sizes (10→11pt), divider between headers and data, wider window (920px). All numeric columns right-aligned, chip name left-aligned.
- **Leaderboard Limit**: Fetch up to 1000 entries (was 200), ordered by newest first.

### Fixed
- **Calibration Frame Filtering**: Flexible case-insensitive substring matching for DARK/FLAT/BIAS in filenames and folder names. No longer requires strict NINA `_DARK_` underscore pattern.

## [3.8.0] — 2026-03-13

### Added
- **Lights-Only Folder Scan**: When opening a folder, calibration frames (DARK, FLAT, BIAS) are now automatically excluded. Detection works via both NINA filename tokens (`_DARK_`, `_FLAT_`, `_BIAS_`) and calibration subfolder names (`DARK/`, `FLAT/`, `BIAS/`, `DARKS/`, `FLATS/`, etc.). Individual file selection bypasses this filter so you can still open any file type directly.

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

## [3.5.1] — 2026-03-12

### Fixed
- UTI declarations: removed exported UTIs, use standard identifiers.

## [3.5.0] — 2026-03-11

### Added
- **Quality Estimator**: Automatic frame quality scoring using z-scores within filter/object/night/exposure groups (min 20 frames). Metrics: FWHM, HFR, StarCount. Filter-aware weighting for narrowband (Ha/OIII/SII). Three tiers: good (green checkmark), uncertain (orange minus), trash (red X).
- **SNR Column**: Signal-to-noise ratio computed from noiseMedian/noiseMAD, sortable and searchable (`snr:<10`).
- **Quality column**: Color-coded SF Symbol icons in file list.
- **noiseMAD metric**: Robust noise estimation for quality scoring.

### Changed
- **Column order**: Filename moved right in default layout. Quality metrics (Q, SNR) promoted to early positions.
- **4-level sort**: Column sorting now supports 4 sort levels (was 3).

## [3.4.0] — 2026-03-10

### Added
- **LightspeedStacker (V2)**: GPU-accelerated stacking engine — ~15s for 16 frames vs ~102s with NormalStacker. GPU warp+accumulate Metal kernel, parallel star detection via TaskGroup, hash-based triangle matching O(1), vDSP normalization.
- **Dual Stacker UI**: NormalStacker (turtle icon) and LightspeedStacker (bolt icon) side by side in toolbar.
- **Benchmark Stats Window**: Horizontal bar chart showing file scanning, first image, header reading, caching, Quick Stack durations plus live memory/swap usage (Window menu).
- **Photoshop-style Zoom**: Click-drag horizontal zoom in Quick Stack result window, plus pinch-to-zoom and scroll-to-pan.

## [3.3.0] — 2026-03-10

### Added
- **SNR Column**: Signal-to-noise ratio in file list, computed from noise statistics, sortable and searchable.
- **Memory Budget Warning**: Warns before caching if session exceeds 70% of physical RAM, with reduction percentage and safe image count recommendation.
- **Quality Overview Help**: Embedded example screenshot, enlarged window (600×750), real-world example data walkthrough.

### Changed
- **Status bar stats**: Replaced pixel dimensions with cache/file size stats (e.g. "108 cached (6.0 GB) — Raw: 10.2 GB").
- **Session overview panel**: Top-aligned layout (was vertically floating).

### Fixed
- **File list focus**: Fixed Shift+Space multi-mark and keyboard nav stealing focus to header inspector table.

## [3.2.0] — 2026-03-10

### Added
- **Quick Stack**: Select 3+ subs and stack with triangle star matching + affine alignment. GPU bin2x pre-processing, blue star crosses, full result window with 4 sliders + Save as PNG. Same-target validation (name + RA/DEC).
- **Save as PNG**: Export stacked results with current adjustments, smart filename from session metadata.

### Changed
- **Doubled slider ranges**: Stretch 0–100%, Sharpening -4/+4, Contrast -2/+2, Dark Level 0–1.0.
- **vDSP-optimized rendering**: Quick Stack result slider adjustments ~5-10x faster.
- **Quality Overview**: Interactive ? help button with beginner-friendly walkthrough. Brown replaces yellow for readability. Expanded quality section, compact fact sheet.

### Fixed
- Zoom +/- keys no longer lose file list focus.
- Header inspector scroll position preserved across image navigation.

## [3.0.0] — 2026-03-09

### Added
- **Spotlight-style Search**: Real-time toolbar filtering with `column:value` syntax (e.g. `filter:Ha`, `fwhm:>4`, `file:Veil`). Plain text searches across all columns. Column aliases (`fil`, `obj`, `cam`). Numeric operators (`>`, `<`, `>=`, `<=`, `=`).
- **Cmd+M Move to Folder**: Move checkmarked files to any destination folder with "Create New Folder" dialog. Full undo via Cmd+Z.
- **H Cycles 3 View States**: All files → hide marked → show only marked → all. Orange "Only Marked" pill in status bar.
- **Lock STF (S key)**: Freeze STF stretch params from current image for brightness comparison across frames.
- **Apply All**: Bake current stretch + post-processing into all cached previews for instant navigation.
- **GPU Post-Processing**: Real-time sharpening (unsharp mask), contrast (S-curve), and dark level sliders via Metal compute.
- **Mark/Unmark Filtered**: Batch checkmark all search results for quick triage.
- **Persistent Settings**: Sliders, toggles, column order remembered across sessions via UserDefaults.
- **19 default-visible columns**: Date, Time, Type, Camera promoted to default-visible.

### Fixed
- OSC debayer: proper mono/color toggle with correct stretch for both modes.
- Keyboard focus stays on table after clicking image/sliders.

## [2.2.0] — 2026-03-09

### Added
- **Lock STF toggle** (S key): Freeze exact c0/mb stretch params for brightness comparison.
- **Apply All toggle**: Bake stretch + post-processing into all cached previews.
- **GPU post-processing pipeline**: Sharpening, contrast, dark level sliders via Metal compute.
- **Persistent settings**: All sliders and toggles saved via UserDefaults.

### Changed
- Redesigned toolbar with SF Symbol toggles + status bar pills.
- Debayer pill hidden when session has no OSC images.
- Real-time CPU/memory stats in status bar.

### Fixed
- updateNSView now respects debayerEnabled + stretchStrength (was overriding user).
- Red-on-blue selection readability in night mode.

## [2.1.0] — 2026-03-08

### Added
- **QuickLook Preview Extension**: Spacebar preview in Finder shows STF auto-stretched FITS/XISF images. CPU rendering with 65536-entry LUT per channel, parallel row processing. Bin2x for images >4096px.
- **QuickLook Thumbnail Extension**: Thumbnail provider for FITS/XISF in Finder.

## [2.0.1] — 2026-03-08

### Fixed
- PRE-DELETE sandbox permission when files opened individually (request folder access via NSOpenPanel).

## [2.0.0] — 2026-03-08

### Added
- **8-Phase Performance Optimization**: Up to 5x faster on local SSD, 8x faster on NAS/10GbE.
  - Concurrent FITS decode via cfitsio `_REENTRANT` (4x throughput)
  - Zero-copy Metal buffers via `posix_memalign` + `bytesNoCopy` (-116 MB/image)
  - GPU bin2x compute kernel (30–150 ms → <1 ms per image)
  - Sliding window prefetch via OperationQueue (50% less stall)
  - Parallel header reading via `concurrentPerform` (6x faster)
  - Vectorized STF median via `vDSP_vsort` (3x faster)
  - Combined GPU command buffers (single submission)
  - Parallel network file copy (4 concurrent streams)
- **Ambient/focuser temperature columns** in file list.
- **Page Up/Home, Page Down/End** jump to first/last image.

### Changed
- Status bar rearranged: selections left, general info right.
- Navigation: arrow keys stop at boundaries (no wrap-around).
- Column order: checkbox, #, filename, object, filter, exp, amb, foc, temp, gain, size, fwhm, hfr, stars, subfolder.

## [1.3.0] — 2026-03-08

### Added
- **Bin2 display** for large sensor images (>8192px) — prevents crash on ZWO ASI6200MM (9576×6388).
- **Stretch slider** from 0% (fully linear) to 100%.

## [0.9.7] — 2026-03-08

### Added
- **Debayer toggle** (D key): OSC Bayer pattern detection (RGGB/GRBG/GBRG/BGGR) from headers, GPU bilinear interpolation, default OFF for speed.
- **Night mode** (N key): Red-on-black UI for dark-adapted vision.
- **Stretch slider**: Adjustable 0–100% stretch strength per image.
- **Splash screen**: About panel on launch, auto-dismiss after 2 seconds.
- **Cache indicator**: Checkmark next to cached filenames.
- **App Nap prevention**: Background processing continues during caching.
- **Two-phase loading**: Fast filename scan + background header enrichment in parallel.

### Fixed
- Image navigation for uncached images.
- Debayer toggle refreshes currently displayed image immediately.

## [0.9.4] — 2026-03-07

### Added
- **Initial public release**: Fast visual culling tool for astrophotography sessions on macOS.
- Metal GPU rendering with PixInsight-compatible STF auto-stretch.
- FITS/XISF decoding via libxisf + cfitsio (all compression formats).
- NINA filename token parsing (date, target, time, filter, exposure, gain, temp, HFR, stars, etc.).
- Integrated side panels: Header Inspector + Session Overview with Fact Sheet generator.
- Pre-delete workflow: mark with Space, move to `_predel/` subfolder with Cmd+Backspace, full undo stack.
- Multi-level column sorting (click to sort, drag to reorder, 20+ columns).
- Keyboard-first navigation with key repeat for rapid blinking.
- Smart folder scanning with subfolder auto-detection.
- Individual file selection support.
- Network volume caching with 4 parallel streams.

### iOS — AstroFileViewer v1.0.0
- FITS/XISF viewer for iPhone/iPad with STF auto-stretch, pinch-to-zoom, header inspector, Save to Photos.
