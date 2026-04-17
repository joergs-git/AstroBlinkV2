# AstroBlinkV2 — Task Tracker

## v5.21.0 — PE Arc Detection + Bugfixes (COMPLETE 2026-04-11)

### PE Arc Gradient Rescue ✅
- [x] Gradient-based second chance in computeShape() when concentration < 2.0
- [x] medianFWHM >= 8px guard (prevents narrowband nebula false positives)
- [x] Floor guard: concentration >= 1.3 (reject truly flat nebulosity)
- [x] Gradient threshold: maxGrad/peak >= 0.08 (4-directional)
- [x] Verified: M82 PE frames 60/64 trash (was ~52/64)

### Filter-Aware Stage 1.5b ✅
- [x] Narrowband thresholds: FWHM 6 MADs, trailing scaled by filter mult, combined 7.0, ecc 0.7, severe 10
- [x] Verified: NGC7000 Ha no longer false trash

### Clouded Frame Detection ✅
- [x] Rule 0: no FWHM = trash (simple, reliable)
- [x] Rule 1: P90 star floor (<15% of group P90 = trash)
- [x] Verified: M81 Portugal clouded frames caught

### Other Fixes ✅
- [x] Stacking mixed targets: plate-solved coords + coordinate fallback (M81+M82 works)
- [x] Stretch reset persistence: saves to AppSettings
- [x] FL column: hideable focal length column

### Release ✅
- [x] Algorithm version 16, app version 5.21.0 (build 68)
- [x] ALGORITHM_CHANGELOG.md, CHANGELOG.md, What's New updated
- [x] Archive, notarize, App Store Connect upload

---

## v5.20.1 — Setup Merging + Narrowband Star Fix (COMPLETE 2026-04-07)

### Setup FL Merging ✅
- [x] Merge setups with same telescope+camera and FL within 3% tolerance
- [x] Always show FL in setup labels (fixes RC12red08 missing FL)
- [x] Multi-hash queries for nightlyTrend, setupSummary, setupComparison
- [x] Nicknames apply to all merged hashes

### Narrowband Star Detection Fix ✅
- [x] StarDetector sharpness check: peak vs neighbor ring ratio ≥1.2
- [x] StarMetricsCalculator concentration check: peak vs aperture avg ≥2.0
- [x] Fixes false star circles on H-alpha nebulosity in Compare window
- [x] Algorithm version bumped to 15

---

## v2.0.0 — Performance Optimization (COMPLETE)
- [x] Phase 1: cfitsio concurrent decode (_REENTRANT, remove mutex)
- [x] Phase 2: Zero-copy decode (posix_memalign + bytesNoCopy)
- [x] Phase 3: GPU bin2x compute kernel
- [x] Phase 4: Sliding window prefetch (OperationQueue)
- [x] Phase 5: Parallel header reading (concurrentPerform)
- [x] Phase 6: vDSP vectorized STF median
- [x] Phase 7: Combined GPU command buffers
- [x] Phase 8: Parallel network file copy
- [x] Shift+arrow shows image at cursor during multi-select
- [x] Status bar rearranged (selections left, general info right)
- [x] Add AMBTEMP + FOCTEMP as default-visible columns
- [x] Reorder default columns
- [x] Remove navigation wrap-around (stop at boundaries)
- [x] Add Page Up/Home and Page Down/End navigation
- [x] "Caching this image..." overlay on uncached images
- [x] Splash screen dismiss on any click
- [x] Fix GitHub URL in About + Help panels
- [x] Update Help with new shortcuts
- [x] README performance section
- [x] Archive and distribute v2.0.0

## Results
- v2.0.0 archived and distributed via Xcode
- 5x faster session loading (local SSD), up to 8x faster on NAS/10GbE
- Git tag: v2.0.0, pushed to origin

---

## v3.3.0 — LightspeedStacker (IN PROGRESS)
- [x] GPU warp+accumulate Metal compute kernel
- [x] Parallel star detection via TaskGroup
- [x] Hash-based triangle matching (O(1) vs O(N²))
- [x] Reduced star/triangle count (30/10 vs 50/15)
- [x] vDSP vectorized normalization
- [x] Mini preview every 3rd frame
- [x] Wire up as "LightspeedStacker" button in toolbar
- [x] Both stackers available: NormalStacker (turtle) + LightspeedStacker (bolt)
- [x] Friendly alert dialogs when no images selected
- [x] Toolbar icon bottom-alignment with multi-line labels
- [x] README FAQ: "Why is LightspeedStacker so fast?" + disclaimer
- [x] A/B test V1 vs V2 — V1 removed in v4.4.0, V2 is sole engine
- [x] Sigma clipping → min/max rejection (v4.4.0)
- [x] Sub-pixel interpolation → Lanczos-3 option (v4.4.0)

## Future TODOs — Pre-Caching Pipeline Optimization

### Analysis Summary (2026-03-10)
Current pipeline per image: decode (~100ms, 85-90%) → STF stats (~3ms) → GPU chain (~7ms)
Decode (file I/O + decompression) is the dominant bottleneck. Everything else is already fast.
Uncompressed XISF: ~17ms decode (SSD limited). LZ4-compressed: ~100-300ms (CPU decompression limited).
**Uncompressed files would cache ~4x faster.** Users choosing LZ4 in NINA trade speed for disk space.

### Optimization candidates ranked by impact

**Tier 1 — Restructure pipeline (~20-30% total gain)**
- [ ] Staged pipeline: separate decode pool (6 threads) → STF thread → GPU batch dispatch → async store
  - Currently each worker does ALL steps sequentially including GPU wait
  - Freeing workers from GPU blocking lets them start next decode 7ms sooner
  - GPU batching (multiple images per command buffer) reduces Metal overhead
  - Workers never block on `waitUntilCompleted()` — use `addCompletedHandler` + continuation

**Tier 2 — Priority navigation (~perceived instant, no total gain)**
- [ ] Predictive priority queue: current image + ±2 neighbors get highest decode priority
  - Background fill for rest of session at lower priority
  - Speculative prefetch based on navigation direction/speed
  - Eliminates "waiting for cache" experience even during initial load
  - Partially in place (cache-miss fast path exists), but no reprioritization

**Tier 3 — More workers (~10-15% gain)**
- [x] Bump maxConcurrentDecodes from 6 to 8 on high-core-count machines
  - Diminishing returns: cfitsio internal lock contention increases at high concurrency
  - SSD bandwidth not bottleneck (local), but NAS might saturate at 6 streams
  - Easy experiment: just change the cap and benchmark

**Tier 4 — Minor gains (<5% each) — CLOSED, not worth complexity**
- [x] Async GPU completion: `addCompletedHandler` instead of `waitUntilCompleted` — shipped in v4.5.0
- [x] ~~GPU histogram for STF stats~~ — <2% gain, not worth
- [x] ~~nth_element O(n) median~~ — vDSP already fast enough
- [x] ~~mmap for uncompressed FITS~~ — only helps uncompressed, not worth

**Not feasible**
- GPU-accelerated decompression: LZ4/zlib are inherently sequential stream algorithms
- Faster cfitsio: NASA reference implementation, not much room to optimize

### How to experiment
1. Add timing to BenchmarkStats for decode vs STF vs GPU per-image (not just phase totals)
2. Test with uncompressed vs LZ4 XISF to quantify decompression cost
3. Try `maxConcurrentDecodes = 10` and compare total caching time
4. Prototype async GPU (`addCompletedHandler`) — smallest change, safest to test

## Future TODOs — Other Performance
- [ ] HEIF thumbnail disk cache for instant session re-open

---

## v3.5.0 — Quality Estimator + Sort Improvements (IN PROGRESS 2026-03-11)

### A) 4-Level Sorting ✅
- [x] `prefix(3)` → `prefix(4)` in `applySortByColumnOrder` (TriageViewModel.swift)
- [x] Add `"date"`, `"time"` to default-descending via new `isDefaultDescending()` in ColumnDefinition
- [x] Reorder `allColumns`: marked → # → filename → filter → quality → date → time → snr → object → ...

### B) Auto Quality Estimator ("Schrott-Erkenner") ✅ Tier 1
- [x] QualityEstimator.swift: groups by filter+object+night+exposure, min 20 frames
- [x] Tier 1: z-scores for FWHM, HFR, StarCount — filter-aware (narrowband: starCount weight 0.3)
- [x] Combined z thresholds: > 0.5 → good, < −1.0 → trash, else uncertain
- [x] QualityTier enum (trash/uncertain/good), stored in ImageEntry.qualityTier
- [x] Triggered after header enrichment in TriageViewModel.recomputeQualityScores()
- [x] Quality column: SF Symbol icon cell (checkmark/minus/xmark + green/orange/red)
- [x] Tier 2: Background anomaly detection (>5 MAD from group median — clouds/gradient/fog)
- [x] Tier 3: Star eccentricity via 2nd moment fitting (done in v4.0.0, trailing consensus in v4.2.0)
- [x] ~~Tier 4: Dither offset histogram~~ — complex, unclear user value, closed
- [x] Show noiseMAD z-score (and available metrics) in header inspector for current image
- [x] "Auto-mark all reds in current filter group" → replaced by Culling Autopilot (v4.3.0)

### C) Column Reorder — New Default ✅
- [x] allColumns reordered: filter, quality, date, time, snr before object/type/camera
- [x] Quality column: isDefaultVisible=true, isHideable=true, defaultWidth=28 (icon only)
- [x] Object stays after snr; user drags to col 1 for multi-target sessions

---

## v3.11.0 — Batch Rename, Unit Tests, Tooltips, Calibration Fix (COMPLETE 2026-03-13)

### A) Automated Unit Test Suite ✅
- [x] QualityEstimatorTests — 12 tests (scoring, z-scores, grouping, narrowband, zero-std)
- [x] SessionScannerTests — 11 tests (calibration detection, folder scan, subfolder logic)
- [x] ImageEntryTests — 17 tests (observing night, display helpers, formatting, file types)
- [x] ColumnDefinitionTests — 18 tests (exposure formatting, SNR, numeric values, sort defaults)
- [x] MetadataExtractorTests — added normalizeFrameType test
- [x] Test scheme configured in project.yml (DEVELOPMENT_TEAM, TEST_HOST, PRODUCT_MODULE_NAME)
- Total: 91 tests (65 new), 90 passing, 1 pre-existing failure (DecoderTests.testMetalBufferCreation)

### B) Batch Rename & Header Edit ✅
- [x] C bridge: write_fits_keyword (cfitsio READWRITE), write_xisf_keyword (XISFModify)
- [x] BatchOperations.swift — preview/execute/undo with mandatory backup + verification
- [x] BatchRenameWindow.swift — scope selector, search/replace, regex, preview table
- [x] Menu item: Edit > Batch Rename & Header Edit... (Cmd+Shift+R)
- [x] `batchModified` flag on ImageEntry + `⇄` indicator in file list
- [x] TriageViewModel integration: applyBatchResult, undoBatchRename, batchUndoStack

### C) Informative Tooltips ✅
- [x] Column header tooltips via ColumnDefinition.headerToolTip(for:) — quality, SNR, FWHM, HFR, stars, filter, night, etc.
- [x] Enhanced toolbar tooltips — Inspector, Session, Delete, Stackers, Benchmark

### D) Calibration False-Positive Fix ✅
- [x] isFileCalibration() — frame type token parsing (not substring) for filenames
- [x] isFolderCalibration() — substring matching (appropriate for folder names)
- [x] Targets like "Dark Nebula" no longer falsely excluded

---

## v4.3.0 — Self-Calibration, Convergence, SSWEIGHT (COMPLETE 2026-03-17)
- [x] CalibrationDatabase — per-setup Welford learning, JSON persistence, SHA256 fingerprint
- [x] Absolute quality floor — isLockedKeep after 30+ learned frames
- [x] Culling autopilot — Conservative/Balanced/Aggressive auto-mark popover
- [x] SSWEIGHT export — FITS/XISF header writing + CSV backup
- [x] Background anomaly detection — >5 MAD from group median
- [x] Culling status — actionable "N× trash remaining" / "Culling complete" / SNR warning
- [x] Compare: bold KEEP/DELETE/REVIEW styling (green/red/orange)
- [x] Compare: PA direction lines + consensus arrow
- [x] Compare: full-field star coverage (90% shape crop, 16384 GPU buffer)
- [x] Stacking alignment fix — ≥6 inliers, dual-axis scale, alignment info display
- [x] Stacking: 80 detected stars for better dither coverage
- [x] Scroll flicker fix — NSAnimationContext duration=0
- [x] Status bar tooltips on all pills
- [x] Help panel updated (autopilot, SSWEIGHT, calibration, compare PA)
- [x] GPU star detection buffer 512→16384

## v4.3.1 — Bug Fixes (IN PROGRESS 2026-03-18)

### Completed fixes
- [x] MetadataExtractor: strip single quotes from FITS/XISF header string values
- [x] MetadataExtractor: DATE-LOC unconditionally overrides filename date, DATE-OBS fallback only
- [x] StarMetricsCalculator: RANSAC collinear trail detection removes satellite/plane detections before all metrics
- [x] StarMetricsCalculator: trail-contaminated frames use verified real star count (not GPU atomic)
- [x] QualityEstimator: Rule 6 (starCountAnomaly) requires elevated FWHM/HFR, not just high star count
- [x] TriageViewModel.navigateToObject: match "unknown" group, case-insensitive, nil/"none" filter convention
- [x] TriageViewModel.navigateToObject: accepts exposure parameter for correct group navigation
- [x] SessionOverview: onFilterTapped passes exposure to distinguish L@180s vs L@300s
- [x] wireSessionOverviewCallbacks called from all load paths (loadSession, loadFiles, loadMultipleFolders)

### App hang during precaching — RESOLVED
- [x] No longer reproduces after v4.3.1 fixes (likely resolved by quote stripping or trail detection changes)

---

## v4.4.0 — Stacking Improvements (IN PROGRESS 2026-03-18)

### Phase 1: Min/Max Pixel Rejection ✅
- [x] New GPU min/max tracking in warp_accumulate shader (buffer indices 7,8)
- [x] Normalization: `result = (sum - min - max) / (count - 2)` when count >= 3
- [x] CPU fallback also tracks min/max
- [x] No UI toggle — transparent, always active when count >= 3

### Phase 2: M81 Alignment Fix ✅
- [x] triangleStarLimit 15 → 20 (C(20,3) = 1140 triangles)
- [x] Retry on alignment failure: triangleStarLimit=25, inlier threshold 15px (was 10px)
- [x] matchTrianglesHashed accepts configurable inlierThreshold

### Phase 3: Lanczos-3 Interpolation ✅
- [x] New warp_accumulate_lanczos GPU kernel (6x6 kernel, sinc windowed, 3px margin)
- [x] InterpolationMode enum (.bilinear/.lanczos) on QuickStackEngineV2
- [x] Segmented picker in V2 progress view (visible during decode/detect phases)
- [x] Pipeline selection at dispatch time (falls back to bilinear if Lanczos unavailable)

### Phase 4: V1 Engine Removal ✅
- [x] Deleted QuickStackEngine.swift (781 lines)
- [x] Removed V1 views from QuickStackWindow.swift (QuickStackProgressView + StackResultView)
- [x] Removed V1 toolbar button from ContentView.swift
- [x] Removed V1 properties/methods from TriageViewModel.swift
- [x] Removed V1 phase observer from ContentView.swift
- [x] Preserved shared renderFloatToTexture function
- [x] XcodeGen regenerated, build passes

## Future TODOs — Stacking

## Future TODOs — UI Polish
- [ ] Smooth arrow-key scrolling: holding up/down should pin selection at visible edge while rows scroll past (like Finder). Current behavior still stutters — likely needs NSTableView subclass override of `moveDown:`/`moveUp:` to control scroll position directly instead of relying on `scrollRowToVisible`.
- [ ] User-adjustable font size for file list table (currently hardcoded: 11pt columns, 12pt filename, 22pt row height). Cmd+/- or preferences slider. Needs to scale row height proportionally.
- [ ] Backspace to remove selected files from session — remove from images array, clear from prefetch cache, reclaim cache memory, recompute quality scores. Files stay on disk untouched — just excluded from the current session as if never loaded. Useful for removing calibration frames that slipped through, test exposures, etc.

---

## v4.6.0 — SmartCull: Multi-Stage Quality Engine (ANALYSIS COMPLETE 2026-03-19)

### Validation Results (1457 frames, 6 setups, 3 telescopes, mono+OSC)
- Stage 1 (z-scores): 1237 decided, 220 debatable (15%)
- Stage 2 (deep analysis): 165 resolved (75%)
- Stage 3 (pattern rules): 47 more resolved → KEEP with lower SSWEIGHT
- **Final: 37 for user (2.5%), of which 23 are FWHM-only → ~14 genuine edge cases (0.96%)**

### Completed — Research Phase
- [x] BatchQualityAnalysisTests.swift — processes images, generates annotated thumbnails + CSV
- [x] Fix: Metal .private texture → blit to .shared before getBytes
- [x] M82 Stage 1+2 deep dive: temporal trends, XISF header forensics (FOCPOS, AIRMASS, humidity)
- [x] Full 6-setup batch test (5307 seconds, all passed)
- [x] Stage 2 cross-setup analysis: 75% auto-resolution across all setups
- [x] Stage 3 pattern mining: two new rules (FWHM+noise→KEEP, star-dip+good-FWHM→transient KEEP)
- [x] Design decision: FWHM-only borderlines → KEEP with lower SSWEIGHT (not delete)
- [x] Memory: project_edge_case_resolution.md, project_smartcull_marketing.md, project_ai_integration_idea.md

### Design Decisions
1. **FWHM-only borderlines = KEEP with low SSWEIGHT** (they add signal, weighted stacking handles quality)
2. **Culling Autopilot maps to stages**: Conservative=Stage1 only, Balanced=+Stage2+3, Aggressive=+FWHM borderlines
3. **Always show WHY** — tooltip/popover explains reasoning per frame (not a black box)
4. **Header forensics is opportunistic** — works with whatever headers are available, graceful fallback
5. **Tagline: "1,457 frames. 14 decisions."**

### Completed — Implementation (2026-03-19)
- [x] Fix noiseZ explosion: cap individual metric z-scores at ±3 in QualityBreakdown
- [x] Fix background anomaly: group-size-aware threshold (10→6.5 MAD, 20+→5.0)
- [x] Stage 3 rescue rules in QualityEstimator: Rule A (FWHM+noise OK→good), Rule B (star dip transient→good), Rule C (FWHM-only trash→borderline)
- [x] reasoningText field on QualityBreakdown + generateReasoning() method
- [x] "Why?" section in quality tooltip (FileListView.swift)
- [x] All 106 non-batch tests pass, 0 failures

### Remaining — SmartCull Polish
- [x] Update Help panel with SmartCull explanation
- [x] Update README + App Store description with SmartCull marketing copy
- [ ] Run validation on more user setups (different software: SGP, Voyager, APT) — when data is available

---

## AIsaac — In-App AI Assistant (v5.0.0 SHIPPED)

### Stage 0+1: COMPLETE ✅ (2026-03-20)
- [x] Purple floating chat window, streaming Claude API, Supabase Edge Function
- [x] 6 presets: Quality Summary, Smart Mark, Filter Advice, About This Object, Nearby Objects, Plan Tonight
- [x] Two-tier: Free Sonnet Buddy + Opus Superexpert (user's own API key via Keychain)
- [x] Per-frame metrics, FITS headers, thumbnails sent to Claude Vision
- [x] App control commands (navigate, highlight, mark, filter, stack, compare, open preview)
- [x] Voice input/output, streaming responses, quick-reply buttons, retry
- [x] Equipment learning database, iCloud sync ready, location/Bortle awareness
- [x] Rolling hourly auth token, Pushover alerting, rate limiting

### AIsaac — Next Improvements
- [ ] Custom icon asset (friendly old man with beard, glasses, 3 blinking stars)
- [ ] Give AIsaac full keyboard shortcut reference in system prompt
- [ ] Give AIsaac Help panel content knowledge for user support questions
- [x] iCloud sync — already active (entitlements + AIsaacUserProfile dual-write to iCloud Drive + local fallback)
- [ ] Persistent rate limiting in Supabase database (survives cold starts)
- [ ] Cache common object info queries (reduce API calls)
- [ ] Response streaming for Opus mode (currently works, verify edge cases)
- [ ] **Metrics-first rule in system prompt** — AIsaac must examine the frame's computed metrics (FWHM, HFR, stars, SNR, moon%, moon distance, ecc, trailing) and FITS headers BEFORE searching external sources. Current behavior: researches externally when the answer is in the local data.
- [ ] **Include calculated metrics + FITS headers in AIsaac context** — Send full metric set + key FITS headers (moon illumination, moon distance, filter, gain, exposure, FL) for the current/selected frame(s). Currently AIsaac doesn't see per-frame computed metrics.
- [ ] **Use hash IDs not sequential numbers** — AIsaac references frames as "#3" or "#24" (sequential position) but UI shows hash-based short IDs (#4A-7566). Must use the visible # column value.
- [ ] **FWHM nil explanation** — When FWHM is nil, AIsaac should explain why (saturated stars, too few candidates, undersampled) using measurement metadata, not guess.

## v5.1.0 — UX Improvements (COMPLETE)

### a. Scroll to top on folder open ✅
- [x] `needsScrollToTop` flag set after session load in all 3 load paths
- [x] FileListView observes flag, calls `scrollRowToVisible(0)` + select row 0

### b. Red fuel bar for loading/caching progress ✅
- [x] Red gradient fuel bar replaces old ProgressView during loading AND caching
- [x] Shows scanning, header loading count/total, and precaching count/total
- [x] White bold text centered over bar, stop/continue buttons preserved
- [x] Replaces old separate progress bar section

### c. Time estimates for loading AND precaching ✅
- [x] `headerEstimatedSecondsRemaining` computed after 20 headers read
- [x] `cachingEstimatedSecondsRemaining` computed after 20 images cached
- [x] Displayed in fuel bar as "— Est: Xs"
- [x] Reset to nil when phase completes

### d. AIsaac awareness of loading/precache state ✅
- [x] `loadingStatus` field on AIsaacSessionContext
- [x] Built from loadingPhase/caching state in AIsaacWindowController
- [x] Prepended to session block in AIsaacContextBuilder

### e. Unmark all (U key) ✅
- [x] `unmarkAll()` on TriageViewModel — clears all marks, updates SNR retention + convergence
- [x] U key in KeyboardHandler
- [x] `unmark_all` AIsaac command + callback wired in ContentView

### f. Quality filter presets ✅
- [x] `q:trash`, `q:borderline`, `q:good`, `q:excellent`, `q:unscored` filter syntax
- [x] `trail:>0.5` trailing score filter
- [x] Color aliases: `q:red` = trash, `q:orange` = borderline, `q:green` = excellent
- [x] Filter preset dropdown menu next to search field (Quality / Filters / Metrics sections)
- [x] AIsaac prompt updated with new filter syntax

---

---

## PixInsight Bridge — "AstroBlink Importer" (v1.2.0 COMPLETE 2026-04-03)

Subdirectory `pixinsight-astroblink/` in main repo. PJSR Script (ES5/SpiderMonkey 24) for
PixInsight that imports AstroBlink triage results and prepares WBPP workflow.
Distributed via PI Update Repository on GitHub Raw URLs.

### Phase 1: PJSR Script ✅
- [x] Project structure (`src/scripts/AstroBlinkImporter/`)
- [x] CSV import (`AstroBlinkV2_SSWEIGHT.csv` parser, subfolder search)
- [x] Triage table UI (TreeBox widget, color-coded quality tiers, sortable columns)
- [x] SSWEIGHT header sync (write via FileFormatInstance read-modify-write pattern)
- [x] Summary stats (total frames, kept, rejected, avg SSWEIGHT/FWHM)

### Platform & Prerequisite Checks ✅
- [x] Detect macOS vs Windows (informational, non-blocking)
- [x] Check if AstroBlink is installed (returns true on macOS for dev builds)

### Phase 2: PI Update Repository ✅
- [x] `updates.xri` manifest + ZIP package with correct `src/scripts/` paths
- [x] GitHub Raw URL: `https://raw.githubusercontent.com/joergs-git/AstroBlinkV2/main/pixinsight-astroblink/`
- [x] One-click install via PI Resources → Updates → Manage Repositories
- [x] Script appears under Script → Batch Processing → AstroBlink Importer

### Phase 2.5: PI → AstroBlink Handoff ✅
- [x] "Open in AstroBlink" button — clipboard marker + ExternalProcess.execute
- [x] AstroBlink clipboard timer picks up ASTROBLINK_PI_OPEN: marker
- [x] NSOpenPanel pre-navigated to folder (sandbox-safe, user clicks "Open Session")
- [x] "Prepare for WBPP" button — writes kept-files list + WBPP instructions
- [x] "Refresh" button — re-imports CSV after triage

### Phase 3: Extensions (post-V1)
- [ ] Quality visualizer in PI (FWHM/Stars/SNR timeline from Frame History DB)
- [ ] JSON triage report (richer than CSV)
- [ ] SubframeSelector comparison (correlate PI metrics with AstroBlink)
- [ ] PI Developer Certification for signed repository

### Phase 4: Community & Marketing
- [ ] PI Forum post (New Scripts and Modules)
- [ ] AstroBlink Wiki page: "PixInsight Integration"
- [ ] README with install screenshots + example session

---

## Future TODOs — Deconvolution & Structure Enhancement (needs R&D)
- [ ] Research BlurXTerminator approach — spatially varying PSF, trained neural network, star masking
- [ ] Consider CoreML model for learned deconvolution (Apple Neural Engine = fast on M-series)
- [ ] Metal FFT via MPSGraph for proper frequency-domain Wiener on GPU
- [ ] Star masking via threshold + morphological operations for cleaner structure boost
- [ ] Iterative GPU deconvolution (conjugate gradient method)
- [ ] Test current implementation with more diverse data (different FL, seeing)
- [ ] Current Wiener and Structure work but results are "not convincing" — needs proper R&D before marketing

## Future TODOs — Astrometry & Annotations
- [ ] Superfast plate solving / astrometric solution (hassle-free for users)
- [ ] Image annotations (object labels, constellation lines, star names)
- [ ] RA/DEC coordinate overlay on images

---

## Future TODOs — Batch Operations
- [x] ~~Test batch rename with real FITS/XISF files~~ — validated by shipping since v3.11.0
- [ ] Batch undo integration with Cmd+Z (currently separate undoBatchRename method)
- [x] ~~Cleanup old batch backups on app quit or session reload~~ — not needed, no user reports

## Future TODOs — Master Calibration Stacking

### Concept
Stack darks and flats into masterdarks/masterflats directly in AstroBlinkV2.
No normalization — pure pixel integration following PixInsight ImageIntegration logic.
State of the art: sigma-clipped mean (or winsorized sigma clipping) for darks,
median or averaged sigma-clipped for flats.

### Implementation Plan
- [ ] CalibrationStacker engine — separate from QuickStackEngineV2 (different workflow)
- [ ] Dark stacking: sigma-clipped mean (3σ, 3 iterations) — removes hot pixels, cosmic rays
- [ ] Flat stacking: averaged sigma-clipped mean → divide by mean to normalize
- [ ] Input: select folder of darks/flats → auto-detect by IMAGETYP header or filename
- [ ] Output: single master FITS/XISF with proper headers (IMAGETYP=MASTER_DARK etc.)
- [ ] GPU compute kernel for sigma-clipped accumulation (extend warp_accumulate)
- [ ] No alignment needed (darks/flats are taken at fixed position)
- [ ] Temperature matching for darks (group by CCD-TEMP ± 1°C)
- [ ] UI: "Create Master" button in toolbar → select Dark/Flat/Bias → folder picker → progress → save

### PixInsight Reference (ImageIntegration)
- Rejection: sigma clipping (low=3σ, high=3σ) or winsorized sigma clipping
- Normalization: none for darks/bias, multiplicative for flats (divide by mean)
- Combination: mean (after rejection)
- Weight: equal (all calibration frames same exposure/conditions)
- PixelMath for master flat: `$T / mean($T)` after integration

## v5.13.0 — User Confidence Rating, Chart Zoom, PI Bridge (COMPLETE 2026-04-03)

### User Confidence Rating ✅
- [x] `userConfidence: Int` (0-3) on ImageEntry
- [x] GRDB migration v7 — `userConfidence` column on frame_record
- [x] Keyboard 1/2/3 sets rating (same key toggles off), works with multi-selection
- [x] Yellow star icons ★ column after Quality, default visible
- [x] Persistence: write to Frame History DB on rating change, restore on file hash match
- [x] Filter syntax: `rating:1`, `rating:2`, `rating:3`, `rating:>0`
- [x] Column alias: `rating`, `conf`, `confidence`

### Chart Scroll & Zoom ✅
- [x] `chartScrollableAxes(.horizontal)` on Session Score, Efficiency, Equipment Health
- [x] 90-day visible domain, positioned at most recent data
- [x] Pinch/scroll zoom on time axis

### PixInsight Bridge v1.2.0 ✅
- [x] Full PI Update Repository (updates.xri + ZIP package)
- [x] "Open in AstroBlink" — clipboard marker + ExternalProcess.execute + sandbox-safe dialog
- [x] "Prepare for WBPP" — kept-files list + WBPP instructions
- [x] Color-coded quality tiers, sort dropdown, SNR/Trailing columns
- [x] Correct FileFormatInstance read-modify-write for header writing

### Future: Community Learning Integration
- [ ] Anonymous upload: (setupFingerprint, qualityMetrics, userConfidence) tuples
- [ ] Crowdsourced ground truth for detection algorithm training
- [ ] Export confidence column in SSWEIGHT CSV

## v5.6.0 — Frame History Database + Archive Scanner (COMPLETE 2026-03-28)
- [x] GRDB.swift SQLite integration (FrameHistoryDatabase, FrameRecord, SessionRecord)
- [x] Per-frame quality persistence (UPSERT on SHA256 file hash, no duplicates)
- [x] Global unique frame IDs (#XX-NNNN from file hash, deterministic)
- [x] MoonCalculator (illumination, position, angular separation)
- [x] Moon% and MoonDist columns in file list
- [x] Moon-aware background anomaly scoring (broadband threshold relaxed near bright moon)
- [x] Cross-session historical baselines (historicalZScore, historicalPercentile)
- [x] History window with SwiftUI Charts (Quality, Metrics, Moon, Setups tabs)
- [x] Filter-accurate chart colors (R=red, B=blue, Ha=orange, OIII=teal, etc.)
- [x] "All Setups" consolidated view + Setup Comparison chart
- [x] Archive Scanner — background folder crawler with per-file progress
- [x] Scanner exclusion rules (DARK/FLAT/BIAS, PixInsight, calibration)
- [x] Post-scan quality tier scoring (groups by target+filter+exposure)
- [x] Resumable scans (scan_progress table, crash-safe, resume dialog on startup)
- [x] iCloud rotating backup (lazy resolution, non-blocking)
- [x] Advanced menu: Reset Frame History Database
- [x] AIsaac historical context (setup summary in system prompt)
- [x] Meridian flip in Compare window (UV flip, zero GPU cost)
- [x] Deployment target bumped to macOS 14.0 (chartScrollableAxes, onChange new syntax)
- [x] 24 new tests (16 FrameHistoryDB + 8 MoonCalculator), all passing

## v5.12.0 — Elliptical PSF, Re-Analysis, Monthly Charts (COMPLETE 2026-04-02)
- [x] Frame History re-analysis — "Re-Analyze" button re-scores stale records with current algorithm
- [x] Elliptical GPU PSF fitting — 5-param kernel (A, σx, σy, θ, B) via Gauss-Newton
- [x] PSF-derived eccentricity + PA (preferred over image moments when fit quality is good)
- [x] ~~PSFSignalWeight as additive 6th metric~~ — reverted, dilutes scoring. PSF flux stays OR/replacement
- [x] PSF Flux Z-score in Quality Metrics panel + tooltip
- [x] FWHM CPU fallback when GPU fit chi² fails (fixes nil FWHM on poor seeing)
- [x] psfFlux column in FrameRecord DB (migration v6)
- [x] Monthly chart aggregation — auto-aggregates when date range >6 months
- [x] kAlgorithmVersion bumped to 13
- [x] PixInsight Bridge repo skeleton (pixinsight-astroblink)

## Open TODOs — Frame History & Charts
- [x] Chart zoom: pinch/scroll zoom on time axis (chartScrollableAxes, 90-day window)
- [ ] Chart tooltip/hover: show exact values on hover (SwiftUI Charts annotation)
- [ ] Twilight bands overlay on quality timeline chart (AreaMark background)
- [ ] FWHM histogram: current session distribution overlaid on historical
- [ ] Archive scanner: detect and flag files that no longer exist (fileGone marker)
- [ ] Archive scanner: progress notification via Pushover when done
- [ ] Bortle class estimation from SITELAT/SITELONG (needs embedded light pollution dataset)
- [x] User confidence rating (1/2/3 stars) — persisted in FrameHistory DB (v5.13.0)
- [ ] WBPP file organizer: auto-organize files into WBPP directory structure
- [ ] PI Bridge: show Frame History data in PI script window

## v5.15.0 — Target Catalog Browser (COMPLETE 2026-04-04)

### Target Catalog Window ✅
- [x] Supabase `target_catalog` table with 515 deep-sky objects, 15 types, 46 constellations
- [x] TargetCatalogService — Supabase fetch, 24h TTL disk cache, flexible JSON decoder
- [x] AltAzCalculator — alt/az computation, visibility curves, transit time, sunset/sunrise
- [x] TargetDatabaseViewModel — filtering, sorting, Frame History queries, weather, visibility
- [x] TargetDatabaseWindow — full SwiftUI UI (HSplitView, ~1200 lines)
- [x] Search, type filter chips, constellation/difficulty pickers
- [x] Alt/Az visibility chart with moon altitude overlay + current-time red dot
- [x] Weather bar: cloud/seeing/temp/humidity/wind, location-relative seeing quality
- [x] Hourly cloud cover mini-chart with current hour highlight
- [x] FOV simulation with equipment profiles
- [x] Filter gap analysis (recommended vs actual integration)
- [x] Location & setup picker with weather refresh on switch
- [x] Moon distance in list + detail, moon illumination in weather bar
- [x] DSS thumbnails (disk-cached by RA/Dec) in detail panel
- [x] Frame History integration (hours, sessions, median FWHM per target)
- [x] Night mode + font scaling
- [x] Menu item (Window > Target Catalog) + toolbar button
- [x] AIsaac knowledge + Supabase remote knowledge updated for v5.14.0
- [x] In-app What's New v5.14.0 entry

### Future: Target Catalog Improvements
- [ ] Upload DSS thumbnails to Supabase Storage for faster loading
- [ ] Expand catalog to 1000+ objects (more Sharpless, Abell, LDN, southern sky)
- [ ] Add imaging_notes and description for all 515 targets (many are null from bulk insert)
- [ ] Date picker for visibility chart (check other nights)
- [ ] "Best targets tonight" sorted list (pre-filtered by altitude + low moon + clear weather)
- [ ] Export target list to NINA sequence file
- [ ] Target-specific recommended integration time estimator (based on SB + Bortle + equipment)

---

## v5.14.0 — Target-Aware Scoring + Float FITS (COMPLETE 2026-04-03)

### Target-Aware Quality Scoring ✅
- [x] DeepSkyTargetDatabase — 229+ targets with type classification
- [x] Type-based metric weight modifiers (galaxy/nebula/cluster)
- [x] FL-aware MAD floor (prevents z-score explosion on uniform sessions)
- [x] Planet exclusion from quality scoring
- [x] GroupKey canonical target names
- [x] ScoringValidationTests

### Float32/Float64 FITS Support ✅
- [x] BITPIX-aware decoder — checks BITPIX before choosing read datatype
- [x] Float FITS (BITPIX=-32/-64) read as TFLOAT with auto-range detection
- [x] Fixed in macOS decoder (Packages/ImageDecoder/)
- [x] Fixed in iOS decoder (AstroFileViewer-iOS/Packages/ImageDecoder/)
- [x] Supports APP, PixInsight, GraxPert output files

### iOS AstroFileViewer v1.4.1 (build 17) ✅
- [x] Float FITS decoder fix applied
- [x] TestFlight upload

---

## Future TODOs — Testing
- [ ] Fix pre-existing DecoderTests.testMetalBufferCreation failure
- [x] ~~CI: GitHub Actions workflow~~ — Metal required, won't work on GitHub runners
- [ ] Consider SPM-only test target for pure-logic tests (~5s vs ~30s)
