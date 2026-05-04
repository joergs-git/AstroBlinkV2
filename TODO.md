# AstroTriage – TODO

Status: [ ] offen | [~] in Arbeit | [x] fertig

Current version: **v6.0.0** (build 89) — shipped 2026-05-03 ([release notes](https://github.com/joergs-git/AstroBlinkV2/releases/tag/v6.0.0))

---

## v6.x Post-Launch Backlog

Welle-3 work from the 2026-05-03 launch-readiness audit. Three patch
releases planned (v6.0.x → v6.1.x → v6.2.x), priority order top to bottom.
Working file with full context: `tasks/launch-readiness-2026-05.md` (gitignored).

### Patch 1 — Service hygiene + safety nets

- [~] **Pre-launch verifications**:
  - [ ] PrefetchCache stress test (500+ FITS, fast ←/→ nav) —
        manual on Release build, repro steps in
        `tasks/launch-readiness-2026-05.md` § "M1"
  - [x] Manipulated FITS bounds test — automated as
        `testFITSBoundsCheck_RejectsAbsurdDimensions` in
        `Tests/DecoderTests.swift`
  - [ ] Golden-Set regression (7 setups × 1638 frames, ±2%) —
        `Tests/ScoringRegressionTests.swift` covers the synthetic
        portion; full real-data sweep stays manual,
        repro steps in `tasks/launch-readiness-2026-05.md` § "M3"

- [x] **`SupabaseClient` → real service layer**
  - Retry with exponential backoff on transient 5xx (502/503/504) +
    recoverable URLErrors (timedOut, networkConnectionLost, dns…)
  - Per-call timeout via `send(_, timeout:, retries:)` parameter
  - Typed `SupabaseError` (notConfigured / network / cancelled /
    invalidResponse). 4xx / non-transient 5xx pass through as
    `(data, response)` so callers retain their own status-code
    handling (e.g. 429 → first-class result)
  - `X-App-Version` header now on every request (e.g.
    "AstroBlinkV2/6.0.0 (89)")
  - All 10 callers migrated; SSE-streaming callers stay raw
    (AIsaacService + Claude-API fallback in VisualAnomalyDetector)
  - Commits: 0a26281 (helper), 6780797 (BenchmarkSharing),
    b40ca29 (remaining 8)

- [x] **CI: enforce `kAlgorithmVersion` bump** on quality-critical edits.
  Workflow `.github/workflows/algorithm-version-check.yml` diffs PR/push
  against the seven scoring files, blocks if `kAlgorithmVersion` did
  not bump, warns if `ALGORITHM_CHANGELOG.md` was not updated alongside.

- [x] **Force-Unwrap-Sweep** — audit complete 2026-05-03,
  deliverable at `tasks/force-unwrap-audit.md` (gitignored).
  100 sites total: 71 system-guaranteed | 18 internal-invariant
  | **11 Category C real risks**. Surprise finding: 4 of the 5
  named launch-readiness Category-C sites were already fixed in
  v6.0.0 (only `SessionCache.swift:35` remains).
  Top files for Category-C fixes (follow-up patch):
  - `TriageViewModel.swift` — 5 (best!.qualityTier×2, sessionRootURL!,
    cropRect!×2, all session-lifecycle, NOT scoring)
  - `StarMetricsCalculator.swift` — 4 (RANSAC trail post-processing
    lines 667–670; quality-critical so will need `kAlgorithmVersion`
    bump even though happy-path behavior is unchanged)
  - `QualityEstimator.swift` — 1 (line 1343, diagnostic write only,
    NOT scoring → no version bump needed)
  - `SessionCache.swift`, `AppMessageService.swift`,
    `AIsaacWindowController.swift` — 1 each

### Patch 2 — TriageViewModel split + QualityEstimator stages

The big one. Snapshot tag before each step (`pre-refactor-<slice>`), build
+ smoke test between every commit.

- [x] **`SessionOrchestrator`** (shipped, commits d3e471b → 371d14b):
  Session loading, prefetch + caching pipeline, header enrichment,
  scoring trigger, post-scoring cascade (SNR retention, convergence,
  Frame History persistence, moon, Bortle), VLM mosaic + Claude Vision,
  and community session-commit hook all live on
  `SessionOrchestrator` (+Headers, +Prefetch, +Scoring, +VLM
  extensions). TriageViewModel.swift trimmed 6118 → 4219 LOC (-31%).
  SessionHost protocol owns the narrow seam back into TriageViewModel
  for state mutation + a few orientation/display bridges
  (detectMeridianFlip, applyWCSAlignment, updateMeridianRotation,
  checkForMixedDimensions, applySortByColumnOrder,
  shouldRotateForMeridian) that stay on the view model.
  Snapshot tags pre-refactor-orchestrator-{protocol,load,prefetch,
  enrich,scoring,vlm,community} cover rollback.

- [x] **`TriageState`** (shipped, commit a45db93): Selection /
  filter / marked / sort UI-state extracted to a dedicated
  TriageState class. View model keeps thin forwarder properties of
  the same name; sub-object's `objectWillChange` is forwarded into
  the view model's so SwiftUI bindings continue to repaint
  unchanged. Scope: selectedIndex, hideMarked, skipMarked,
  showOnlyMarked, pendingColumnOrder, pendingColumnVisibility,
  needsQualityResort. `filterText` deliberately stays on the view
  model (Binding-projection constraint).

- [x] **`QualityEstimator` stages → separate files** (shipped,
  commit aa53d42, kAlgorithmVersion 24 → 25): pure mechanical move,
  byte-for-byte preservation. Split into +Helpers (227 LOC),
  +SessionSanity (250 LOC), +Historical (387 LOC).
  QualityEstimator.swift 2112 → 1292 LOC. ALGORITHM_CHANGELOG entry
  in v25 documents the rationale + the no-logic-change guarantee.
  Synthetic ScoringRegressionTests green; full real-data
  BatchQualityAnalysis stays manual per launch-readiness M3.

- [x] **`FrameHistoryDatabase` iCloud-Sync extraction** (shipped,
  commit 9956e7a): iCloud rotating-backup workflow moved into a
  dedicated FrameHistoryICloudSync class. Database keeps its
  storageURL + dbQueue private; helper holds iCloud directory
  state and reaches into the database via a weak ref + narrow
  internal `reopenAfterImport(replacingWith:)` API. All four
  external call sites work unchanged via thin DB forwarders.

- [x] **`FrameHistoryModel`** (shipped, commit accad72): 20 nested
  domain types split into a FrameHistoryModel+Domain.swift
  extension. Pure mechanical move — every reference site keeps
  working unchanged because Swift looks nested types up by
  enclosing type, not by declaration file. FrameHistoryModel.swift
  1289 → 1099 LOC.

### Patch 3 — Cross-platform + tests + concurrency

- [x] **Decoder sharing macOS ↔ iOS** (commit f16a659):
  AstroFileViewer-iOS/Packages/ImageDecoder/ retired (-610 MB from iOS
  subtree). iOS now references `../Packages/ImageDecoder` via project.yml.
  C++ bridge unified — macOS canonical (superset). cfitsio thread-safety
  stays platform-specific via CFITSIO_LOCK macro: macOS no-op + _REENTRANT
  cSettings.when(platforms:[.macOS]); iOS std::lock_guard on a static
  std::mutex. Both apps build clean. **Manual verification before next
  iOS App Store submission**: smoke-test FITS+XISF decoding on actual iOS
  hardware — simulator can mask page-alignment / mutex contention issues.

- [x] **Granular telemetry toggles** (commit 990c4f2):
  communityLearning master toggle split into telemetryPerformanceBenchmarks
  / telemetryFrameQualityRatings / telemetryCommunityBaselines. One-time
  migration in AppSettings.migrateLegacyTelemetryToggle() preserves opted-out
  users' choice across all three new keys. Status-bar Community indicator
  now opens a popover with three checkboxes + descriptions + "Enable all" /
  "Disable all" master buttons. Onboarding splash keeps the single master
  toggle. PRIVACY.md updated. Privacy bug fix in passing: BenchmarkSharing +
  CurationService previously gated only on BenchmarkConfig.isConfigured —
  the granular split closes that opt-out gap.

- [x] **Test coverage** (commit 0eff9b8):
  - QualityEstimatorTests +13 tests: R6 star anomaly (4), R7 background
    incl. negative-deviation invariant (5), isLockedKeep absolute floor (4),
    Stage 1.5b narrowband (1 deliberate XCTSkip — needs DI seam refactor)
  - ScoringValidationTests +12 tests: aliasing (5), type weight modifiers (7)
  - DecoderTests testMetalBufferCreation: pre-existing wrong-assertion bug
    fixed (buffer.length is page-aligned for bytesNoCopy, not == totalBytes)
  - Total: 24 active + 1 skip = 25 new tests, all passing
  - Golden-Set in CI: still listed as a future item (synthetic golden set
    is automated; full real-data sweep stays manual per launch-readiness M3)

- [ ] **Strict Concurrency / Swift 6 migration** — there are ~30
  Sendable warnings in `TriageViewModel.Task.detached` blocks (capture
  of `var self` etc.). `swift-language-mode complete` once we're
  ready to fix them all. Deferred — should pair with Patch 2's
  TriageViewModel split since the hot spots overlap.

### Smaller observations (quick wins, anytime)

- [x] Status-bar Community Learning indicator: sibling `info.circle`
      button opens PRIVACY.md on GitHub (commit 5c58729). Lives
      outside the toggle tap-area to avoid accidental opt-out flips.
- [x] `AIsaacUserProfile.delete()` posts `Notification.Name.aisaacProfileDeleted`
      (commit 5c58729). `TargetDatabaseViewModel` observes it and
      refreshes its cached `equipmentSetups` / `allLocations`
      mirrors. Other callers freshly `.load()` each time, so they
      already see the blank profile — no observer needed.

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

### UI Polish — v5.25.1 (SHIPPED)

**Blink Controls:**
- [x] Blink delay dropdown widened (60→72pt) + 0.05s option added. Default stays 0.1s
- [x] P key to toggle play/pause auto-blinking

**Zoom:**
- [x] Minus key zoom goes down to 5% (was 25%), 5% steps below 25%
- [x] Compare window: Cmd+1 (100%) and Cmd+2 (200%) quick zoom, +/- zoom keys, 0 to reset

**Compare Window:**
- [x] C key toggles star circle overlay on/off (shared state with UI toggle)
- [x] Metadata redesign: BEST (green) / SELECTED (orange) bold labels, one-line summary (Filter, Exposure, Cam-Temp, Night, Time), smaller filename below. Centered metric comparison bar (Stars, FWHM, HFR, Ecc, SNR) with green vs orange coloring.

### Tilted-Plane Background in GPU PSF Fit (Future R&D)
- [ ] GPU `psf_fit_gaussian`: expand 3-param (A, σ, B) to 5-param (A, σ, B0, Bx, By) with tilted-plane background
- [ ] CPU `computeFWHMGaussian`: gradient pre-subtraction from stamp edge pixels before linearized fit
- [ ] Standard approach in professional photometry (SExtractor, DAOphot) for handling moon/LP gradients
- [ ] Tested 2026-04-17: did NOT fix the external user's NGC 2251 moonlit B-filter issue (FWHM went 11.88 → 13.20, worse)
- [ ] Root cause was star detection contamination (noise peaks on bright background), not gradient bias
- [ ] May still help for genuine gradient-only cases (non-crowded fields, moderate moon). Needs testing on more diverse data.
- [ ] Implementation reference: plan `mutable-singing-glacier.md` and git stash/conversation from 2026-04-17

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

### Curation-Driven Threshold Learning (Phase 2) — PLANNED, READY TO IMPLEMENT

**Problem:** 192 of 417 false positives (46%) are z-score-only trash — combinedZ < -2.0 but no Stage 1 reason. The static -2.0 threshold is too aggressive for some setups.

**Solution:** Grid search on curated star ratings finds per-setup offsets:
- **Borderline offset** (±0.8 max) — adjusts -2.0 trash/borderline threshold
- **Trailing ceiling offset** ([-0.15, +0.20]) — adjusts 0.60 trailing ceiling

**Cost function:** FP × 1.5 + FN × 2.5 (false negatives penalized more). Ties favor offset=0.

**Activation:** ≥50 curated frames with ≥10 at 1★ and ≥10 at 3★. Never learn from: decentered, background, twilight.

**Implementation steps (8 files, 2 new):**
- [ ] Step 1: `CalibrationDatabase.swift` — Add `LearnedThresholds` struct + `CalibrationProfile.learnedThresholds` field
- [ ] Step 2: `ThresholdLearner.swift` — **NEW** grid search engine with non-learnable exclusions
- [ ] Step 3: `FrameHistoryDatabase.swift` — Add `curatedFrameRecords(setupHash:)` query
- [ ] Step 4: `QualityEstimator.swift` — Add `learnedThresholds` param, use effective thresholds in Rule 6a + tier assignment
- [ ] Step 5: `TriageViewModel.swift` — Wire learning after `commitSession()`, pass thresholds to `computeScores()`
- [ ] Step 6: `FrameRecord.swift` — Bump `kAlgorithmVersion` 20 → 21
- [ ] Step 7: `ALGORITHM_CHANGELOG.md` — Document v21
- [ ] Step 8: `Tests/ThresholdLearnerTests.swift` — **NEW** 6 unit tests

**Full plan:** `~/.claude/plans/mutable-singing-glacier.md`
**Data:** 4,550 blind-curated frames in Supabase. Baseline analysis in memory (`project_curation_baseline_2026_04_16.md`)

### Onboarding / Welcome Screen
- [x] First-launch onboarding splash — 4 marketing pillars (Speed Demon, Data Nerd, Community Learner, Power User) with hover details (v5.19.1)
- [x] Accessible via About menu, non-dismissable on first launch, "Don't show on startup" checkbox (v5.19.1)
- [ ] Interactive tutorial: "Open a folder → review quality → mark bad frames → pre-delete"
- [ ] Equipment profile setup (telescope, camera, focal length) during onboarding for immediate calibration

### Community Calibration — Site-Aware Comparison
- [ ] **Location/Bortle metadata** — Store observing site Bortle class, lat/lon, altitude alongside calibration data. Setup fingerprint stays equipment-only, but comparisons can be filtered by observing conditions.
- [ ] **Raw-data ice/frost detection** — Radial brightness profile analysis in the scoring pipeline (before auto-stretch). Far more reliable than post-stretch VLM/mosaic analysis. Star count is the best metadata proxy for optical cleanliness.

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
