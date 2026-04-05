# AstroTriage – TODO

Status: [ ] offen | [~] in Arbeit | [x] fertig

Current version: **v5.18.0** (build 61)

---

## Shipped (v1.0–v5.2.0)

All original implementation phases are complete:

- [x] **Phase 1** — Core Skeleton (Xcode/XcodeGen, libxisf, cfitsio, MTKView, Texture Pool)
- [x] **Phase 2** — STF + Metal Pipeline (CPU reference, Metal STF shader, debayer, dual-queue GPU, RAM cache, PrefetchCache)
- [x] **Phase 3** — File List + Metadata (SessionScanner, FITS/XISF header parsing, NINA filename tokens, NINA CSV reader, NSTableView)
- [x] **Phase 4** — Triage Workflow (Pre-Delete move/undo, Pre-Delete panel, keyboard shortcuts)
- [x] **Phase 5** — Filter System (wildcard + numeric filters, quality tier syntax, filter presets)
- [x] **Phase 6** — Disk Cache + Polish (thumbnail cache, settings, error handling, performance monitoring)
- [x] **SmartCull Engine** — 4-stage quality pipeline (z-scores → deep analysis → pattern rules → calibration floor)
- [x] **Star Trailing Detection** — Adaptive aperture, orientation consensus, FL-adaptive baseline (v4.2.0)
- [x] **Self-Calibration** — Per-setup Welford learning, absolute quality floor, convergence detection (v4.3.0)
- [x] **SSWEIGHT Export** — Writes weight keyword to FITS/XISF headers + CSV backup (v4.3.0)
- [x] **Color Combine** — Mono filter stacks → RGB with presets (SHO/HOO/LRGB/etc.), per-channel weights (v4.4.0)
- [x] **LightspeedStacker V2** — Min/max rejection, Lanczos-3, adaptive triangle matching (v4.4.0)
- [x] **Priority Navigation Queue** — Dual-queue caching with async GPU preview (v4.5.0)
- [x] **AIsaac AI Assistant** — Claude-powered in-app assistant with voice, app control, equipment memory (v5.0.0)
- [x] **NAS Support** — Interleaved download + pre-caching pipeline (v5.1.2)
- [x] **Quality Filter Presets** — `q:trash`, `filter:Ha`, `fwhm:>5` syntax (v5.1.2)
- [x] **Filter-Aware Trailing** — Trailing penalty scales by filter: NB 0.3×, RGB 0.6×, L 1.0× (v5.2.0)
- [x] **FL-Adaptive Eccentricity** — Rule 5: extreme ecc > 2× baseline = garbage (v5.2.0)
- [x] **Multi-Reason Garbage** — All rules checked independently, multiple reasons shown (v5.2.0)
- [x] **Decentered Target Detection** — Rule 1b: CRVAL1/CRVAL2 shift > 30% FOV (v5.2.0)
- [x] **Twilight Detection** — Rule 10: NOAA solar position from DATE-OBS + site coords (v5.2.0)
- [x] **Star Count Anomaly** — Rule 6: doubled stars from dithering/guiding jumps (v4.2.0)
- [x] **Compare with Best** — Synchronized zoom/pan side-by-side, PA overlay (v3.12.0)
- [x] **Image Preview Window** — Double-click floating window with full post-processing (v3.12.0)
- [x] **QuickLook Plugin** — Finder previews with OSC debayer for FITS/XISF (v5.1.2)
- [x] **PixInsight Bridge** — PJSR script for importing triage results (separate repo)

- [x] **Font Size Scaling** — Cmd+/Cmd-/Cmd+0 across all panels (v5.4.0)
- [x] **Auto-Mark Toolbar Button** — Culling autopilot in main toolbar with gradient icon (v5.4.0)
- [x] **Toolbar Reorganization** — Grouped with dividers, two-line toggle labels (v5.4.0)
- [x] **False Satellite Trail Fix** — Axis ratio verification on extended objects (v5.4.0)
- [x] **Session-Wide Sanity Check** — Cross-group P10/P90 comparison catches uniformly bad groups (v5.5.0)
- [x] **Uncertain Tier** — Blue ? for small groups with low confidence (v5.5.0)
- [x] **Filter-Aware Twilight** — Narrowband tolerates nautical twilight (v5.5.0)
- [x] **R9 Timing Race Fix** — Merged MainActor callbacks in PrefetchCache (v5.5.0)
- [x] **Compare Cross-Group Fallback** — Finds genuinely good reference across filters (v5.5.0)

---

## Shipped — v5.14.0

- [x] **Deep-Sky Target Database** — 229+ targets with type classification, angular sizes, RA/Dec, filter recommendations
- [x] **Target-Aware Quality Scoring** — Metric weights adjust by target type (galaxy FWHM 1.4x, IFN noise 2.0x, etc.)
- [x] **FOV Fill Ratio** — Secondary weight modulation based on target size vs sensor FOV
- [x] **Practical MAD Floor** — Prevents z-score amplification of insignificant differences in tight sessions
- [x] **FL-Aware FWHM Floor** — MAD floor scales with plate scale (long FL = wider pixel floor)
- [x] **Planet/Solar Exclusion** — Solar system objects excluded from quality scoring
- [x] **GroupKey Canonicalization** — "NGC 7000" = "NGC7000" = "North America Nebula"
- [x] **GroupKey Setup Separation** — FL bucket prevents cross-setup scoring (RASA vs RC12)
- [x] **Session Sanity Cross-Setup** — PoolKey without FL allows cross-setup bad-night detection
- [x] **Compare Filter/Setup Matching** — Same filter priority, same FL, NB↔NB only
- [x] **R0b FL-Dependent Threshold** — Wide-field higher star threshold, tightened background
- [x] **Session Sanity Target-Type Thresholds** — Emission nebula FWHM 1.6x, IFN 1.8x
- [x] **Scoring Regression Tests** — 9 golden-set tests catching M82 trailing, R0b, cross-setup issues
- [x] **Float32/Float64 FITS Support** — BITPIX-aware decoder for APP/PixInsight/GraxPert output
- [x] **Blink Video Export** — GIF/MOV export with scale, loops, crop-to-zoom, size-constrained GIF (v5.17.0)
- [x] **R0b FWHM Cross-Check** — Bright nebulae (M42 H-alpha) no longer falsely flagged as dome/dark (v5.16.0)
- [x] **Moon Distance RA/DEC Fallback** — Reads RA/DEC keywords when CRVAL1/CRVAL2 absent (v5.16.0)
- [x] **Target Catalog Aliases** — 40+ Sharpless, Caldwell, common name aliases added (v5.16.0)
- [x] **VLM Check** — Visual anomaly detection via Claude Vision API. Deviation map (pixel-by-pixel median comparison) + absolute anomaly checks for ice, dew, condensation, obstruction. Supabase Edge Function for VLM inference. Tile-based evaluation with explicit per-tile visual evidence. Filter-aware (narrowband vs broadband sensitivity) (v5.18.0)

---

## Open — Planned Features

### Target Database UI
- [ ] Browsable target catalog window (like Telescopius — sortable table with type, size, magnitude, filter recommendations)
- [ ] Show which target matched the current session + active weight modifiers
- [ ] FOV fill ratio visualization for current setup

### Imaging Calendar / Planner
- [ ] Monthly calendar view with moon phases and darkness hours
- [ ] Target altitude curves per night from user's location
- [ ] Moon proximity warnings per target
- [ ] "Best targets tonight" ranking
- [ ] Requires: altitude/azimuth calculator (RA/Dec + lat/lon + LST)

### WBPP File Organizer
- [ ] Auto-organize triaged files into WBPP-compatible directory structure
- [ ] Naming convention enforcement for PixInsight WeightedBatchPreProcessing
- [ ] One-click export after culling

### Built-in Plate Solving
- [ ] Superfast local plate solve for all loaded frames
- [ ] Enables accurate decentered-target detection without pre-existing CRVAL headers
- [ ] Must run during prefetch without blocking navigation
- [ ] Approaches: index-based solver (astrometry.net style) or GPU-accelerated star pattern matching
- [ ] Would enable mosaic planning and astrometric quality checks

### History Window Chart Improvements
- [x] Y-axis percentile clamping — P2/P98 range, outliers clamped
- [x] Fixed window-width charts — no horizontal scrolling
- [x] Summary cards row (Frames, Nights, Best FWHM, Trash Rate, Targets)
- [x] X-axis chronological sorting — Date-based, not categorical strings
- [x] Filter name normalization — L/LE/Lext → "L", H→Ha, etc.
- [x] "All Setups" = scatter dots (no spaghetti lines)
- [x] 6 KPI charts: Score, Efficiency, Performance, Conditions, Progress, Setups
- [x] Legends on all charts explaining colors
- [x] Target name enrichment — 300+ targets (all Messier, major NGC/IC/SH2/Barnard/Abell/vdB/LDN)
- [x] Moon impact split by broadband vs narrowband
- [x] Equipment Health per-setup warning
- [x] **Hover tooltips** — chartOverlay + GeometryReader on Score/Efficiency/Performance charts
- [x] **Time range selector** — All/3M/6M/9M/12M/24M/36M filter in header bar
- [x] **Rolling average window picker** — 5/10/20 sessions (segmented on Performance chart)
- [x] **Integration Progress rethink** — hours not frames, per-filter stacked bars, detail annotations
- [x] **Chart clipping** — `.clipped()` on all chart plot areas prevents bar overflow
- [x] **Rich tooltips** — Score/Efficiency show targets, filters, FWHM, moon%, "Likely:" cause for bad nights
- [x] **Performance tooltip** — per-setup FWHM breakdown when "All Setups" selected, orange highlight on outliers
- [x] **Conditions redesign** — multi-factor X-axis: Moon/FWHM/Temp/Bortle segmented picker, nearest-point hover with full breakdown
- [x] **Setups tooltip** — frame count, date range, trash rate, targets per setup on bar hover
- [ ] Monthly aggregation when date range >6 months
- [ ] Historical median reference line (dashed horizontal)

### AIsaac Session Planner
- [x] "Plan Tonight" context — moon phase, twilight times, target integration status, filter gaps
- [x] Astronomical twilight timing from SunCalculator (15min sampling)
- [x] Filter recommendation based on moon phase + target history
- [x] Recent performance trend (last 2-3 sessions FWHM/retention in prompt)
- [x] Weather-adaptive advice (wind→shorter exp, humidity→dew warning, moon→narrowband)
- [x] Setup awareness (dome vs portable guidance in system prompt)
- [ ] Meteoblue/Clear Outside seeing forecast integration (7Timer + Open-Meteo already wired)

### Frame History Re-Analysis
- [ ] Detect stale records: `WHERE algorithmVersion < kAlgorithmVersion`
- [ ] UI indicator in History window showing how many records are outdated
- [ ] "Re-analyze" button that re-runs quality scoring on stale records
- [ ] Batch re-analysis for Archive Scanner results (background, resumable)
- [ ] Option to re-analyze on session load if DB has older-version scores

### SSWEIGHT Reset / Removal
- [ ] Option to remove or reset SSWEIGHT keywords from FITS/XISF headers
- [ ] Undo path for cases where weights were written based on incorrect scoring
- [ ] Could be per-file (context menu) or batch (whole session)
- [ ] Must also handle the CSV backup file (`AstroBlinkV2_SSWEIGHT.csv`)

### PSFSignalWeight Compatibility
- [ ] Compute PixInsight-compatible PSFSignalWeight (PSFSW) from existing star detection
- [ ] ΣPSFFlux: sum of detected star brightness values (total star signal per frame)
- [ ] ΣPSFMeanFlux: mean star brightness (resolution/seeing proxy)
- [ ] N*: robust noise from noiseMAD (already computed)
- [ ] M*: background level from noiseMedian (already computed)
- [ ] Write PSFSW keyword alongside SSWEIGHT so WBPP can use either
- [ ] More robust than SNRWeight — PSF fitting inherently rejects non-PSF sources (satellites, hot pixels)
- [ ] Reference: PixInsight 1.8.9+ SubframeSelector PSF Signal Weight algorithm

### False Positive Reporting
- [ ] Right-click → "Report Wrong Detection" on any garbage/trash frame
- [ ] Upload to Supabase: full QualityBreakdown (z-scores, garbage reasons, tier), setup fingerprint, filter, exposure, FL, pixel size, all metrics, algorithm version
- [ ] Include 512px JPEG thumbnail (STF-stretched preview, downscaled, ~50-100KB) for visual verification
- [ ] Anonymous — setup fingerprint is already anonymized SHA256, no filenames/paths
- [ ] Dashboard/admin view to analyze reports: which rules produce most false positives, per-setup patterns
- [ ] Feeds into Community Detection Phase 2 (agreement learning) and future ML training data
- [ ] Could also allow reporting false negatives (good frames that should have been flagged)

### ~~Benchmark Sharing~~ ✓ (shipped)
- [x] Upload/compare stack benchmarks via Supabase
- [x] Community leaderboard for stacking performance

### Community Detection Learning
- [x] **Phase 1: Upload & Bootstrap** — shipped v5.3.0
  - [x] `CommunityBaseline.swift` — model structs
  - [x] `CommunityDetectionService.swift` — upload/download/caching
  - [x] `QualityEstimator` — `isCommunityFloorLocked`, community floor
  - [x] `TriageViewModel` — wire upload + fetch
  - [x] `AppSettings` — `communityLearning` toggle (opt-in)
  - [x] `FileListView` — gray lock badge
  - [x] `ContentView` — clickable status bar icon with tooltips
  - [x] Supabase: table + RPC + validation trigger + admin RPCs
  - [x] `Tests/CommunityDetectionTests.swift` — 15 tests
  - [ ] `AIsaacService` — community context in system prompt (deferred)
- [ ] **Phase 2: Agreement Learning** — future (adjust thresholds from community override rates)
- [ ] **Phase 3: Contextual Priors** — future (empirical Bayesian metric weights)

### Onboarding / Welcome Screen
- [ ] First-launch onboarding flow — guided walkthrough of key features (SmartCull, AIsaac, shortcuts)
- [ ] Interactive tutorial: "Open a folder → review quality → mark bad frames → pre-delete"
- [ ] Equipment profile setup (telescope, camera, focal length) during onboarding for immediate calibration
- [ ] Option to show on first launch only, with "Show again" in Help menu

### PixInsight Integration Plugin
- [x] **PJSR Bridge Script** — imports triage results (separate repo, shipped)
- [ ] Deeper integration: launch PixInsight WBPP directly from AstroBlink with pre-configured file list
- [ ] Two-way sync: read PixInsight SubframeSelector weights, write AstroBlink SSWEIGHT back
- [ ] PixInsight process icon export for batch processing pipelines

---

## Performance Gates (verified)

| Scenario                             | Target        | Method                   |
|--------------------------------------|---------------|--------------------------|
| First Display (cold, 50MP XISF LZ4) | < 200ms       | Stopwatch from key press |
| Next Image (Cache-Hit)               | < 32ms        | MTLCommandBuffer.gpu*Time|
| Session Load 500 Files (scan + meta) | < 3s          | os_signpost              |
| Thumbnail Batch 100 Files            | < 30s         | Timer                    |
| GPU Utilization during Prefetch      | > 80%         | Metal System Trace       |
| RAM at 1000-File Session             | < 10 GB       | Activity Monitor         |
