# AstroBlinkV2 — Task Tracker

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
- [ ] Bump maxConcurrentDecodes from 6 to 8-10 on high-core-count machines
  - Diminishing returns: cfitsio internal lock contention increases at high concurrency
  - SSD bandwidth not bottleneck (local), but NAS might saturate at 6 streams
  - Easy experiment: just change the cap and benchmark

**Tier 4 — Minor gains (<5% each)**
- [ ] Async GPU completion: `addCompletedHandler` instead of `waitUntilCompleted` (~5-7%)
  - Can implement standalone without full pipeline restructure
- [ ] GPU histogram for STF stats instead of CPU vDSP sort (~2ms saved, ~2%)
  - Metal kernel computes 65536-bin histogram, CPU derives median/MAD from it
- [ ] nth_element O(n) median instead of full sort (vDSP_vsort is already ~3x faster than stdlib)
- [ ] mmap for uncompressed FITS (~10-20% on uncompressed only, not worth for compressed)

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
- [ ] Tier 4: Dither offset histogram (pairwise centroid offset clustering)
- [ ] Show noiseMAD z-score (and available metrics) in header inspector for current image
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
- [ ] Update Help panel with SmartCull explanation
- [ ] Update README + App Store description with SmartCull marketing copy
- [ ] Run validation on more user setups (different software: SGP, Voyager, APT)

---

## AIsaac — In-App AI Assistant (NEXT UP)

### Concept
"Ask AIsaac" — AI-powered assistant for astrophotography quality analysis.
Named after Isaac Newton (astronomer, optics). Backend proxy via Supabase Edge Function
calling Claude API. Rate-limited per user to control costs.

### Architecture: Supabase Backend Proxy
- App → Supabase Edge Function → Claude API → response back
- User authenticates via anonymous Supabase auth (no signup required)
- Rate limit: N queries per day per device UUID (e.g. 20/day free, more with account)
- Cost control: set monthly Claude API budget cap on Supabase side
- Estimated cost: ~$0.01/query text, ~$0.02/query with image → at 1000 users × 5 queries/day = ~$3/day
- Cache common queries (object info) → reduces API calls by ~50%

### Phase 1: Object Info (mostly free)
- [ ] Local object database (Messier, NGC, IC — name, type, constellation, mag, size)
- [ ] "Tell me about [OBJECT]" from FITS header → local DB first, Claude API fallback
- [ ] Supabase Edge Function: `/ask-aisaac` endpoint
- [ ] Swift client: `AIsaacClient.swift` — URLSession to Supabase, Keychain for device ID
- [ ] UI: "Ask AIsaac" button in toolbar or session overview panel

### Phase 2: Quality Explanation
- [ ] "Why is this frame borderline?" → send metrics JSON (no image needed)
- [ ] "What's wrong with my marked frames?" → send tier distribution + reasons
- [ ] Pre-prepared system prompts with astrophotography context
- [ ] Claude responds with natural language explanation

### Phase 3: Visual Analysis (Claude Vision)
- [ ] "What's the problem with this image?" → send 800px JPEG thumbnail
- [ ] "Compare these two frames" → send pair of thumbnails
- [ ] Star shape analysis, trailing detection, background gradient identification
- [ ] Privacy: only thumbnails (800px), never full-res, never file paths

### Phase 4: Session Summary
- [ ] "How was my night?" → narrative from per-filter metrics + temporal trends
- [ ] "Which filter needs more data?" → integration time recommendations
- [ ] Auto-generate after session load (opt-in)

### Pre-Prepared Prompts (system prompt templates)
```
OBJECT_INFO: "You are AIsaac, an expert astrophotography advisor. The user is imaging
{OBJECT} with {TELESCOPE} ({FOCAL_LENGTH}mm) and {CAMERA}. Filter: {FILTER}.
Provide: 1) What this object is, 2) Recommended filters and exposure,
3) Common challenges, 4) Tips for this specific setup. Be concise."

QUALITY_EXPLAIN: "You are AIsaac. The user has {TOTAL} frames of {OBJECT}.
Quality distribution: {EXCELLENT} excellent, {GOOD} good, {BORDERLINE} borderline,
{TRASH} trash. The highlighted frame has: FWHM={FWHM}, Stars={STARS}, SNR={SNR},
TrailingScore={TRAIL}. Group median FWHM={MED_FWHM}. Explain why this frame
is rated {TIER} and whether the user should keep or delete it."

IMAGE_ANALYSIS: "You are AIsaac analyzing an astrophotography subframe.
Setup: {TELESCOPE} + {CAMERA}, {FOCAL_LENGTH}mm, {FILTER} filter.
Metrics: FWHM={FWHM}, Stars={STARS}, Ecc={ECC}, Trail={TRAIL}.
Look at the image and describe: star shapes, trailing, background uniformity,
any artifacts. Is this a good frame for stacking?"
```

### Privacy & Cost Control
- Device UUID for rate limiting (no personal data)
- Monthly budget cap on Supabase (e.g. $50/month → alert at 80%)
- Cache object info responses for 30 days (same object = same answer)
- All AI features optional — app works fully offline
- Never send: file paths, real names, full-resolution images, API keys

---

## Future TODOs — Batch Operations
- [ ] Test batch rename with real FITS/XISF files (manual verification)
- [ ] Batch undo integration with Cmd+Z (currently separate undoBatchRename method)
- [ ] Cleanup old batch backups on app quit or session reload

## Future TODOs — Testing
- [ ] Fix pre-existing DecoderTests.testMetalBufferCreation failure
- [ ] CI: GitHub Actions workflow running tests on push
- [ ] Consider SPM-only test target for pure-logic tests (~5s vs ~30s)
