# Algorithm Changelog

Tracks every change to quality scoring, star detection, noise measurement,
trailing analysis, and all other metric calculation logic.

**IMPORTANT:** Every bump to `kAlgorithmVersion` in `FrameRecord.swift` MUST have
a corresponding entry here. Frame History DB records carry the algorithm version
they were scored with — this changelog is the authoritative reference for what
that version means.

Records with `algorithmVersion < kAlgorithmVersion` are candidates for re-analysis.

---

## Version 20 — v5.24.2 (2026-04-16)

**Curation-driven threshold tuning: trailing ceiling + chain cross-check.**

Based on analysis of 4,550 blind-curated frames with corrected confusion matrix.
187 tunable false positives identified (human=3★, algo=trash, excluding decentered/
background/twilight which human can't judge zoomed in).

### Changes

1. **Trailing absolute ceiling raised 0.50 → 0.60** — `QualityEstimator` Rule 6a.
   33 false positives clustered at trailing 0.50-0.60 where human rated 3★ (stars
   looked round enough). True garbage median trailing is 0.98; the 0.10 shift
   rescues mild trailing while preserving strong separation from real defects.

2. **Chain detection base threshold raised 0.08 → 0.10** — `QualityEstimator` Rule 9.
   56 chain FPs, mostly RC12 2423mm (28) and RASA 620mm (25). Scale range now
   0.10-0.22 (was 0.08-0.18) across plate scales 0.5-2.5"/px.

3. **Chain detection elongation cross-check added** — `QualityEstimator` Rule 9.
   Chain pattern alone no longer triggers garbage. Stars must also show elongation
   (trailing > 0.15 OR eccentricity > FL-baseline + 0.15) to confirm tracking error.
   Curation evidence: chain FP axis_ratio 0.844 (round) vs true garbage 0.626
   (elongated). Dense star fields and optical aberrations no longer false-positive.

### Impact

- **Reduced:** Trailing FPs at 0.50-0.60 no longer flagged as garbage
- **Reduced:** Chain FPs on RC12/RASA with round stars no longer flagged
- **Unchanged:** True trailing garbage (score > 0.60 with consensus) still caught
- **Unchanged:** True chain garbage (elongated stars with chain pattern) still caught

### Evidence

4,550 blind-curated frames, 5 setups (RC12 2423mm, RC12red08 1964mm, RASA 620mm,
ZWO AM5 468/904/905mm), 21 targets, 7 filters. Confusion matrix corrected for
486 race-condition frames with stale quality_tier.

### Files Changed

- `AstroTriage/Engine/QualityEstimator.swift` — Rule 6a ceiling, Rule 9 threshold + cross-check
- `AstroTriage/Model/FrameRecord.swift` — `kAlgorithmVersion` 19 → 20

---

## Version 19 — v5.24.1 (2026-04-16)

**Fix false dome/dark detection on undersampled full-frame sensors.**

Reported by user with ASI6200MM (61 MP, 3.76μm pixels) at 504mm FL (1.54"/px
plate scale). All luminance lights flagged as "no signal detected" + "noise peaks,
not real stars (dome/cap)" despite 52,785 legitimate stars and SNR 19.8.

### Root Cause

At 1.54"/px with ~2" seeing, real stars have FWHM ~1.3px. The Gaussian FWHM fit
required 8 pixels above 10% of peak — at σ=0.55px only ~5 pixels qualify, so the
fit returned nil for every star. With FWHM nil, Rule 0 flagged "no signal" and
Rule 0b flagged "dome/cap" (hardcoded FWHM > 3.0 threshold unreachable at this
plate scale).

### Changes

1. **Gaussian fit parameters relaxed for undersampled stars** —
   `StarMetricsCalculator.computeFWHMGaussian`: `minFitPixels` 8 → 4,
   threshold 10% → 3% of peak. At FWHM ~1.3px this yields ~9 qualifying pixels
   (vs ~5 before), enabling reliable fits on tight stars. The 2-parameter linear
   regression (ln(I) vs r²) only needs ≥3 points, so 4 is safe.

2. **SNR cross-check on dome/dark detection** — `QualityEstimator`: both the
   pre-pass dark frame identification AND Rule 0b now check `SNR > 5.0` before
   flagging. Dark/dome frames have near-zero SNR (random noise only). Real light
   frames with sky signal have SNR >> 1. This is the most reliable discriminator
   and prevents false positives when FWHM measurement fails for other reasons.

3. **Rule 0 SNR safety net** — `QualityEstimator` Rule 0 (noData): if FWHM is nil
   but `SNR > 5.0 AND stars > 100`, the frame clearly has signal — don't flag as
   "no signal detected". This catches measurement failures on undersampled stars.

4. **Plate-scale-aware FWHM threshold in dome detection** — `QualityEstimator`:
   replaced hardcoded `FWHM > 3.0` with `max(0.8, min(3.0, 1.5 / arcsecPerPixel))`.
   At 1.54"/px this becomes ~0.97px (matching real star FWHM under good seeing).
   At 0.5"/px it remains 3.0 (oversampled setups unaffected). Fallback to 3.0 when
   plate scale unknown.

### Impact

- **Fixed:** Full-frame sensors at short FL (ASI6200MM, ASI2600MM at 400-600mm)
  no longer false-positive as dome/dark frames in star-rich fields
- **Unchanged:** Actual dark/dome detection unaffected (SNR ≈ 0 for real darks)
- **Unchanged:** Long FL setups (>1000mm) and oversampled setups use same thresholds

### Files Changed

- `AstroTriage/Engine/StarMetricsCalculator.swift` — minFitPixels, threshold
- `AstroTriage/Engine/QualityEstimator.swift` — pre-pass, Rule 0, Rule 0b
- `AstroTriage/Model/FrameRecord.swift` — `kAlgorithmVersion` 18 → 19

---

## Version 18 — v5.22.2 (2026-04-13)

**Mixed-plate-scale session sanity — arcsec FWHM comparison, star-count skip.**

### Changes

1. **Session sanity FWHM comparison in arcseconds for mixed-plate-scale pools** —
   `QualityEstimator.sessionSanityCheck`: when the target+exposure pool contains
   frames at different plate scales (min/max `arcsecPerPixel` ratio > 1.10 and
   every frame has a plate scale available), both the pool P10 benchmark and
   the per-frame comparison are computed in arcseconds instead of pixel FWHM.
   Single-plate-scale pools — the overwhelming majority of sessions — are
   unaffected because the arcsec conversion is a uniform multiplier per frame
   and the ratio `fwhm / P10` stays identical.

2. **Session sanity star count check skipped on mixed-plate-scale pools** —
   Star detection sensitivity scales with plate scale: at longer FL (finer
   plate scale), more pixels are available per star and detection yields
   higher counts for the same sky. Pooling star counts across mixed plate
   scales lets the finer-scale frames dominate the P90 benchmark, causing
   coarser-scale frames to falsely trip the `< 0.4 × P90` check. Without a
   clean plate-scale normalization for star count (which would require image
   area and detection model), skipping the check on mixed pools is safer
   than false-flagging. Single-plate-scale pools continue to run the check.

### Why

The pre-v18 session sanity pool intentionally merged across plate scales
(the design comment cites "catch a bad night where one setup's frames are
uniformly bad while another's are fine"). That goal remains — but the
implementation compared pixel FWHM across setups, which is plate-scale
biased. With the user's M97 dataset captured on the same RC12 both with
and without a 0.81× focal reducer (FL 2423mm → 1964mm), the reduced-FL
frames at 0.40″/px dominated the pool P10 while the native-FL frames at
0.32″/px were systematically ~20 % larger in pixels for the same physical
seeing. Any native-FL frame near the seeing threshold would trip the
`> 1.3–1.6 × P10` multiplier and be demoted, even when its physical arcsec
FWHM matched the reduced-FL frames. This contributes to the over-flagging
pattern that showed up in the community_sessions telemetry for long-FL
narrowband (~74–75 % user override rate across multiple independent
setups at FL 2423 and FL 1964).

Physical seeing is the right invariant, and arcsec FWHM is the plate-scale
invariant representation of it, so we compare in arcsec when the pool
mixes plate scales. The detection is a ratio test on the per-frame
`arcsecPerPixel` values: a 10 % tolerance absorbs minor FL-reporting
noise while still catching real configuration changes (a 0.81× reducer
produces a ~25 % change, well above the tolerance).

### Impact

- Mixed-plate-scale sessions: native-FL frames no longer get falsely
  flagged as FWHM outliers when pooled with reduced-FL frames of the
  same target. Star count flagging is also disabled in this scenario.
- Single-plate-scale sessions (the common case): zero behavioral change.
  Unit-test coverage remains stable because `testSessionSanityCheck_*`
  tests don't populate `pixelSizeMicrons` or `focalLength`, so they
  fall through to the pixel-based path identical to v17.
- Golden-set M82-January and M82 datasets (both mixed FL: RC12 2455mm +
  RC12red08 1964mm): need manual verification because those are the
  only two golden fixtures with mixed plate scale. Expected behavior —
  January tracking-hop frames still catch on SNR/ecc/trailing flags
  (plate-scale invariant) and on Rule 9 `.trackingHop` Stage 1 garbage
  which fires before session sanity; March M82 good frames stay good.
- Re-analysis recommended for archive frames scored under v17 in
  sessions that mix native + reduced configurations of the same scope.

### Files changed

- `AstroTriage/Engine/QualityEstimator.swift` — `sessionSanityCheck`
  plate-scale detection, arcsec FWHM conversion in pool collection and
  per-frame comparison, star count skip on mixed pools.
- `AstroTriage/Model/FrameRecord.swift` — `kAlgorithmVersion` 17 → 18.
- `Tests/QualityEstimatorTests.swift` — new
  `testSessionSanityCheck_mixedPlateScaleArcsecNormalization` covers
  both the positive case (good mixed-FL pool not demoted) and the
  negative control (single-FL pool behavior unchanged).

---

## Version 17 — v5.22.0 (2026-04-13)

**FL-adaptive star chain detection, user quality feedback system, WCS-based display alignment.**

### Changes

1. **FL-Adaptive Star Chain Detection** — `StarMetricsCalculator.detectStarChains()`: close
   neighbor threshold now scales with plate scale when `arcsecPerPixel` is available. Uses
   40 arcsecond physical threshold divided by plate scale, capped at 120px. At long FL
   (2423mm, 0.32"/px): 120px (preserves existing behavior). At mid FL (468mm, 1.66"/px):
   24px (prevents false positives from normal star clustering, e.g. NGC2024). Directional
   consensus R threshold raised from 0.35 to 0.50 for plate scales >1.5"/px. Falls back
   to original 80px threshold when plate scale unknown.

2. **FL-Adaptive Chain Garbage Threshold** — `QualityEstimator` Rule 9: garbage threshold
   raised from 0.08 to 0.15 for plate scales >1.5"/px. Dense wide-field star fields
   naturally produce more coincidental close pairs; higher threshold prevents false
   `.trackingHop` classification while still catching real PE at any FL.

3. **User Quality Feedback** — New `QualityFeedback` enum (agree/disagree/partly) on
   `ImageEntry`. Stored in Frame History DB (`qualityFeedback` column, migration v9).
   'A' key cycles feedback, context menu submenu. Feeds into CalibrationDatabase
   counters (userAgreed/userDisagreed/userPartlyAgreed) for per-setup learning.

### Impact
- Short/mid FL setups (<1.5"/px plate scale): potential reduction in false `.trackingHop`
  garbage flags. Frames previously flagged as chain garbage may now score normally.
- Long FL setups (>1.5"/px): no change in behavior.
- Re-analysis recommended for archive frames from short FL setups.

---

## Version 16 — v5.21.0 (2026-04-11)

**PE arc gradient rescue, filter-aware Stage 1.5b, clouded frame detection, Rule 1 P90 floor.**

### Changes

1. **PE Arc Gradient Rescue** — `StarMetricsCalculator.computeShape()`: when concentration
   check (peak/avg < 2.0) fails AND medianFWHM >= 8px, a gradient-based second chance
   discriminates PE arc stars (steep gradients) from nebulosity (smooth). Three guards:
   medianFWHM >= 8 (only bloated PE arcs), concentration floor 1.3, gradient threshold 0.08.
   M82 PE detection: 52/64 → 60/64 frames caught.

2. **Filter-Aware Stage 1.5b** — `QualityEstimator.historicalBaselineCheck()` now applies
   filter-dependent thresholds: narrowband FWHM threshold 6 MADs (was 3), trailing deviation
   scaled by filterTrailingMultiplier (narrowband ×0.3), combined threshold 7.0 (was 3.5),
   eccentricity threshold 0.7 (was 0.5), severe threshold 10 MADs (was 5). Prevents false
   positives on NGC7000/IC443 H-alpha data.

3. **Rule 0: No FWHM = Trash** — Simplified clouded/dark frame detection: if computedFWHM
   is nil (Gaussian fit failed on all star candidates), the frame is garbage. Replaces
   complex multi-condition check. Catches heavy clouds, fog, lens cap, dome closed.

4. **Rule 1: P90 Star Floor** — Additional star count check: if frame has <15% of the
   group's P90 star count (top 10%), it's garbage regardless of starWeight. Catches
   partially clouded frames in bimodal groups where CV > 1.0 disabled star-count scoring.

### Impact
- PE arc detection improved (+8 frames at RC12 2400mm)
- Narrowband false positive rate reduced (NGC7000, IC443 no longer trashed)
- Clouded frame detection robust (Portugal M81 cloud gaps caught)
- No regression on good broadband data

---

## Version 15 — v5.20.1 (2026-04-07)

**Star detection sharpness filter, narrowband false positive reduction, setup merging.**

### Changes

1. **Star Detector Sharpness Check** — Added concentration ratio filter in `StarDetector.swift`:
   peak pixel must be ≥1.2x brighter than the average of its 8 neighbors (above background).
   Rejects smooth nebulosity peaks that pass the 5-sigma + local-max test, especially in
   H-alpha narrowband data where bright emission regions create false star detections.

2. **Shape Measurement Concentration Check** — Added in `StarMetricsCalculator.computeShape()`:
   peak brightness must be ≥2x the average within the measurement aperture. Prevents computing
   eccentricity/PA on diffuse nebulosity patches that survived earlier filtering.

3. **Setup FL Merging** — `FrameHistoryModel.loadAvailableSetups()` now clusters setups with
   identical telescope+camera and focal lengths within 3% tolerance. Minor plate-solve
   variations (903/904/905mm from the same scope) are merged into one entry. All merged
   hashes are queried together for charts and statistics.

4. **Always Show FL** — Setup labels now always include focal length when available, not only
   when duplicate equipment strings exist. Fixes RC12red08 missing FL display.

### Impact
- Star detection: fewer false positives on narrowband, slightly fewer detected stars overall
  (rejected candidates are nebulosity peaks, not real stars)
- Setup merging: cosmetic change, does not affect scoring or calibration database
- All existing v14 frame records should be re-scored for improved star metrics

---

## Version 14 — v5.14.0 (2026-04-03)

**Target-aware quality scoring, practical significance MAD floor, planet exclusion.**

### Changes

1. **Deep-Sky Target Database** — 229+ embedded targets with TargetType classification
   (galaxy, emission nebula, planetary nebula, globular cluster, IFN, etc.), angular size,
   RA/Dec J2000, magnitude, surface brightness, and filter recommendations per target.

2. **Target-type-aware metric weights** — Stage 2 combinedZ multiplies base weights by
   target-type modifiers:
   - Galaxy: FWHM 1.4x, trailing 1.2x (resolution-critical, trailing destroys detail)
   - Emission nebula: noise 1.4x, FWHM 0.7x (SNR-critical, diffuse targets tolerate bloated PSF)
   - IFN: noise 2.0x, FWHM 0.4x, trailing 0.3x (every photon counts)
   - Globular cluster: star 0.2x (star count meaningless due to crowding)
   - Unknown targets: all 1.0x (preserves previous behavior)

3. **FOV fill ratio modulation** — Secondary weight adjustment based on target angular size
   vs sensor FOV. Small target in large FOV → FWHM weight +20%. Target fills frame →
   noise weight +20%.

4. **Practical significance MAD floor** — Minimum effective MAD per metric prevents z-score
   amplification of tiny differences in tight sessions:
   - FWHM: FL-aware floor via `0.30 / arcsecPerPixel` (0.20-0.80px range)
   - HFR: 0.65x of FWHM floor
   - Star count: max(20, median×10%)
   - Noise MAD: 0.0008
   - Trailing: 0.04
   Ensures "FWHM 4.6 vs 4.5" never causes tier demotion.

5. **FL-dependent FWHM MAD floor** — At long focal length (small plate scale), atmospheric
   seeing spreads across more pixels. The FWHM floor scales inversely with arcsec/pixel:
   - RASA 620mm (1.25"/px): floor = 0.24px
   - Ref140 904mm (0.86"/px): floor = 0.35px
   - EdgeHD 2032mm (0.38"/px): floor = 0.79px
   - RC12 2423mm (0.32"/px): floor = 0.80px (capped)

6. **GroupKey canonicalization** — Uses `TargetCatalog.canonicalName()` instead of raw target
   strings. "NGC 7000", "NGC7000", "North America Nebula" now land in the same scoring group.
   Same fix for PoolKey in session sanity.

7. **Planet/solar system exclusion** — Targets named Jupiter, Saturn, Moon, Sun, Mars, Venus,
   Mercury, etc. are excluded from `computeScores()` entirely. Prevents homogeneous planetary
   groups from normalizing to .good via z-score compression.

### Files modified
- `QualityEstimator.swift` — Target weights, MAD floor, GroupKey/PoolKey fix, planet filter
- `DeepSkyTargetDatabase.swift` — New file: 229 targets with types, sizes, filter recs
- `FrameRecord.swift` — kAlgorithmVersion 13 → 14

### Expected impact
- **Galaxy targets**: Slightly stricter on FWHM/trailing, more lenient on noise/stars
- **Emission nebulae**: Slightly stricter on noise/SNR, more lenient on FWHM/trailing
- **IFN targets**: Much stricter on noise, very lenient on FWHM/trailing
- **Tight sessions**: Fewer false borderline/trash from insignificant metric differences
- **Long FL setups**: FWHM scoring more tolerant of seeing-limited pixel spread
- **Unknown targets**: No change (all modifiers = 1.0)
- **Planet frames**: No longer scored (excluded)
- **GroupKey**: Sessions with mixed target name formats now merge correctly

---

## Version 13 — v5.12.0 (2026-04-02)

**PSFSignalWeight as additive 6th metric + elliptical PSF fitting.**

### Changes

1. **PSF flux remains OR/replacement with star count** (additive approach tested but
   reverted — diluted scoring when psfFlux and stars diverge, causing missed garbage).
   PSF flux z-score used when available, falls back to star count when not computed.

2. **Elliptical GPU PSF fitting** — new `psf_fit_elliptical` Metal kernel fits
   5-parameter elliptical Gaussian (A, σx, σy, θ, B) via Gauss-Newton with
   Levenberg-Marquardt damping. Derives eccentricity analytically from σx/σy
   and PA from θ (preferred over image moments when fit quality is good).

3. **psfFlux persisted in Frame History DB** — new `psfFlux` column (migration v6).
   Enables historical PSF flux comparison across sessions.

4. **Frame History re-analysis** — "Re-Analyze" button in History window banner
   re-scores all stale records with current algorithm. Updates algorithmVersion
   after re-scoring.

### Impact
- More discriminating quality scores when PSF data is available
- More accurate eccentricity/PA from PSF fit vs image moments
- Slight changes to borderline frame classification (additive metrics shift combinedZ)

---

## Version 12 — v5.10.4 (2026-04-02)

**Dark frame / dome closed detection fix.**

### Problem
Closed dome images (dark frames labeled as LIGHT) showed 17,000-18,000 "stars" from hot
pixel detections but were NOT flagged as garbage. Previous Rule 0b required HFR == nil/0,
but hot pixel clusters on sensors with amp glow can produce valid HFR measurements (1-3px),
bypassing the check. Affected frames had no quality icon (blank Q column) and were not
auto-marked, mixing garbage dome frames into keep stacks.

### Root Cause
1. Hot pixels are genuine outliers in read noise distribution — survive even 16σ auto-escalation
2. Some hot pixel clusters (warm columns, amp glow regions) create 2-3px structures with
   measurable HFR, defeating the "no valid HFR = noise" assumption
3. No rule checked background level (noiseMedian) — the definitive signal for dark frames
4. Dome frames have LOW FWHM (~3px vs real ~5px) and HIGH star counts, so Rule R7
   (star count anomaly) didn't fire either (requires elevated FWHM)

### Change
Rule 0b now uses two independent detection paths instead of relying on HFR:
- **Path A**: Stars ≥ 10,000 → absolute ceiling. After PreviewGenerator's 16σ auto-escalation,
  no real star field retains this many detections (even dense Milky Way fields reduce to < 5,000)
- **Path B**: Stars ≥ 3,000 AND noiseMedian < 0.005 → dark frame. Real sky frames always have
  measurable background (> 328 ADU / 0.005 normalized) from sky glow and sensor offset

### Files modified
- `QualityEstimator.swift` — Rule 0b rewritten (HFR dependency removed)
- `FrameRecord.swift` — kAlgorithmVersion 11 → 12

### Expected impact
- Dark/dome frames with hot pixel HFR correctly flagged as garbage (`.noisePeaks`)
- Real star fields unaffected (count < 10,000 after escalation; background > 0.005)
- Dense fields (globular clusters, Milky Way): count < 5,000 after 16σ, background > 0.005

---

## Version 11 — v5.10.3 (2026-04-02)

**Trailing outlier guard for long focal length telescopes.**

### Problem
Rules 5, 6, 6a fired on frames whose trailing was at the group average (trailingZ ≈ 0).
On RC12 at 1964mm (baseline 0.255), normal optical eccentricity 0.50–0.70 produced high
trailing scores that triggered Rule 6a despite being the group norm. 112/140 frames trashed.

### Change
All trailing garbage rules (5, 6, 6a) now require `trailingZ > 1.0` — the frame must be
a trailing OUTLIER within its group. If trailing z is nil (insufficient data for z-score),
defaults to permissive (allows rules to fire, since we have no group context).

### Files modified
- `QualityEstimator.swift` — `isTrailingOutlier` guard on Rules 5, 6, 6a

### Expected impact
- **Long FL (RC12, 1964mm)**: normal frames no longer mass-trashed
- **Short/mid FL (RASA 620mm)**: genuinely trailed outliers still caught (z > 1.0)
- **Groups with ALL frames trailing**: no individual frame flagged (session sanity catches these)

---

## Version 11 — v5.10.2 (2026-04-01)

**Severity-dependent trailing multiplier for narrowband filters.**

### Problem
The flat narrowband trailing multiplier (0.3×) made garbage detection thresholds
mathematically unreachable: trailingScore capped at 1.0, but threshold = 0.7/0.3 = 2.33.
Severe trailing on narrowband (Ha, OIII, SII) was never flagged as garbage, regardless
of how elongated stars were or how strong the consensus.

### Changes
1. **Severity-dependent multiplier**: `baseMult + (1 - baseMult) × trailingScore²`
   - Mild trailing (score < 0.3): mult stays near baseMult (0.30 → 0.36)
   - Moderate trailing (score 0.5): mult escalates to 0.48
   - Severe trailing (score > 0.7): mult approaches 1.0 (full Luminance penalty)
   - Preserves narrowband benefit for mild trailing, escalates for severe cases
2. **Absolute trailing ceiling (Rule 6a)**: trailingScore > 0.50 AND consensus > 0.5 → garbage
   - Filter-independent safety net, does NOT check fwhmRulesOutTrailing
   - Tracking error produces normal FWHM + high eccentricity — consensus is the guard
3. Applied to: Rules 5, 6, Stage 2 z-score weighting, rescue rule trailingOK, SSWEIGHT

### Files modified
- `QualityEstimator.swift` — New `effectiveTrailingMultiplier()`, Rule 6a, updated all
  trailing multiplier usage (Rules 5/6, Stage 2, rescue rules, reasoning labels)
- `FrameRecord.swift` — kAlgorithmVersion 10 → 11
- `ALGORITHM_CHANGELOG.md` — This entry

### Expected impact
- **Narrowband with mild trailing (score < 0.3)**: No meaningful change
- **Narrowband with moderate trailing (score 0.3-0.5)**: Slightly stricter scoring
- **Narrowband with severe trailing (score > 0.65 + consensus)**: Now correctly flagged as garbage
- **RGB/Luminance**: Minimal to no change

---

## Version 10 — v5.6.0 (2026-03-29)

**Baseline version.** All records in the Frame History DB as of v5.6.0 are set to
this version via migration `v3_algorithm_version_baseline`.

### Active scoring logic at this version:

**Quality Estimator (QualityEstimator.swift)**
- 4-stage pipeline: z-scores → deep analysis → pattern rules → calibration floor
- Combined z-score: FWHM (negated), Stars (direct), Noise MAD (negated), Trailing (negated)
- FWHM and HFR never combined (95% correlated) — FWHM preferred, HFR fallback
- Z-score cap ±3.0 per metric
- Filter-aware trailing penalty: NB ×0.3, RGB ×0.6, L ×1.0, unknown ×0.7
- Quality tiers: Trash (0), Borderline (1), Good (2), Excellent (3), Uncertain (4)
- Uncertain tier: group <8 frames AND combinedZ in [-1.0, 0.5]

**Stage 1 — Garbage Detection Rules:**
- R1: Missing critical data (no noise stats)
- R1b: Decentered target (CRVAL shift >30% FOV)
- R2: Star count anomaly with FWHM/HFR cross-check
- R5: FL-adaptive eccentricity (ecc >2× baseline = garbage)
- R7: Background anomaly (positive deviation only, moon-aware for broadband)
- R8: FWHM rules out trailing (FWHM ≤ median×1.15 → no trailing garbage)
- R10: Twilight detection (narrowband: civil, broadband: nautical)
- fwhmRulesOutTrailing prevents false trailing garbage on good-focus frames

**Stage 1.5 — Session-Wide Sanity Check:**
- Cross-group P10/P90 comparison (pools by object+exposure, ignores filter/night)
- 2+ flags = trash, severe FWHM outlier (>1.4× P10) + 1 flag = trash
- Multi-group guard: ≥2 filter/night combos required

**Stage 3 — Rescue Rules:**
- Promotion only, never demotion
- isLockedKeep (calibration floor) → minimum tier .good

**Star Metrics (StarMetricsCalculator.swift)**
- Center-crop 70% for measurement
- Adaptive aperture: min(15, max(5, medianFWHM × 2.5))
- 60 measured stars, 10px crowding, full-res refinement
- Bright star annular measurement (skip saturated core)
- Position angle extraction via doubled-angle method

**Trailing Analysis (TrailingAnalyzer.swift)**
- Orientation consensus: ±20° of mean PA, >50% = systematic
- FL baseline: 0.8 / sqrt(focalLength / 200)
- trailingScore = excessEcc × consensusMultiplier
- Filter-independent detection (penalty response is filter-aware in QualityEstimator)

**Noise Measurement (STFCalculator.swift)**
- Center-crop 70%
- 5% random subsample (seed 42)
- Median + MAD (normalized ×1.4826)
- SNR = noiseMedian / noiseMAD

**Calibration (CalibrationDatabase.swift)**
- Welford online algorithm for incremental mean/variance/MAD
- ≥30 frames threshold before absolute quality floor activates
- Frames within 1 MAD of learned baseline → isLockedKeep

**SSWEIGHT Formula:**
- `clamp(0, 100, 50 + qualityZScore*20) * (1 - trailingScore*0.5*filterTrailingMult)`
- Locked KEEP frames: minimum weight 50

---

## How to bump the version

1. Make your change to scoring/detection/metric logic
2. Increment `kAlgorithmVersion` in `FrameRecord.swift`
3. Add a new section above with:
   - Version number and app version
   - What changed and why
   - Which files were modified
   - Expected impact on existing scores (e.g. "frames with X will now score higher")
4. Commit both the logic change and changelog together

## Files that require a version bump when modified:

- `QualityEstimator.swift` — scoring weights, tier thresholds, garbage rules, rescue rules
- `TrailingAnalyzer.swift` — consensus algorithm, FL baseline, trailing score formula
- `StarMetricsCalculator.swift` — aperture sizing, star selection, PA extraction
- `STFCalculator.swift` — noise measurement (measureNoise method only)
- `CalibrationDatabase.swift` — floor logic, lock criteria, Welford parameters
- `ConvergenceDetector.swift` — convergence thresholds (affects culling recommendations)
- `ColorCombineEngine.swift` — filter alias mapping (affects filter identification)

## Files that do NOT require a version bump:

- UI changes (display, layout, colors, labels)
- Navigation, keyboard shortcuts, menu items
- Pre-caching pipeline (decode, stretch, GPU rendering)
- Import/export (SSWEIGHT writing, CSV backup)
- AIsaac AI assistant
- Benchmark sharing, community detection service
- In-app messaging
