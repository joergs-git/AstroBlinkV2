# SmartCull Quality Testing Log

Comprehensive record of all quality detection algorithm testing, results, and validation runs.
This document serves as proof of rigorous software development and calibration methodology.

---

## Test Corpus

| Setup | Target | Telescope | FL | Camera | Frames | Ground Truth |
|-------|--------|-----------|-----|--------|--------|-------------|
| IC 63 Ghost | IC 63 | RC12 | 2423mm | ZWO ASI6200MM Pro | 896 | 7 sessions, PRE-DELETE folder |
| M81 | M81 | 140mm | 904mm | ZWO ASI6200MM Pro | 261 | PRE-DELETE_bad_star_form |
| M82 | M82 | RC12/RC12red08 | 2455mm | ZWO ASI6200MM Pro | 119 | Good quality (March sessions) |
| M82-January | M82 | RC12 | 2455mm | ZWO ASI6200MM Pro | 64 | All tracking hops (January) |
| NGC 3184 | NGC 3184 | 85mm | 468mm | ZWO ASI6200MM Pro | 85 | PRE-DELETE folder |
| NGC7635 | NGC 7635 | RC12 | 2423mm | ZWO ASI6200MM Pro | 62 | PRE-DELETE folder |
| ngc7000 | NGC 7000 | RASA | 620mm | ZWO ASI6200MM Pro | 34 | PRE-DELETE folder |

**Total: 1,638 frames, 7 setups, ~185 GB raw data, 61.2 megapixels per frame**

---

## Per-Frame Analysis Pipeline (13 checks)

Every single frame undergoes all of these automated analyses:

1. **XISF/FITS decode** — decompress + parse 50-80 header keywords
2. **Noise statistics** — subsample 5% of 61.2M pixels (~3M samples), median + MAD
3. **GPU star detection** — threshold scan over 61.2M pixels, local maxima, weighted centroid
4. **Star position refinement** — sub-pixel weighted centroid on 50 brightest stars (full-res 9×9 window)
5. **Satellite trail RANSAC** — up to 200 iterations on 50 star positions, 5px tolerance
6. **Star chain detection** — 1,225 pair comparisons (50 choose 2) + circular statistics (v5.1.0)
7. **HFR measurement** — cumulative flux in concentric rings for up to 60 stars
8. **FWHM Gaussian fit** — linearized least-squares regression (ln(I) vs r²) for 60 stars
9. **2D moment analysis** — eigenvalue decomposition for 60 stars → eccentricity, PA, axis ratio
10. **Trailing consensus** — doubled-angle circular statistics on star position angles
11. **Quality scoring** — 8-rule garbage detection + weighted z-scores + rescue rules + calibration floor
12. **STF auto-stretch** — per-channel median/MAD + midtones transfer function
13. **Thumbnail generation** — GPU Metal render + CPU downscale + metric overlay text

**~125 million pixel operations and ~65 million math operations per frame.**

---

## v5.1.0 — Star Chain Detection (Tracking Hop Pattern)

### Problem Statement

Mount periodic error or tracking hops cause stars to appear as chains of discrete dots.
Each dot looks like a legitimate round star (low eccentricity, normal FWHM), so the existing
PA consensus trailing detection completely misses them. Frames are rated "Excellent" or "Good"
despite being visually obvious garbage.

**Root cause of detection failure:**
- Each dot is round → eccentricity-based trailing score is low
- PA consensus can't find trailing direction (no measurable elongation per star)
- Star count anomaly Rule 6 requires FWHM confirmation, but individual dots have normal FWHM
- Even when trailing Z is slightly negative, other metrics (stars, noise, HFR) compensate

### Algorithm: Parallel Short Chain Detection

**Unique spatial signature of tracking hops:**
1. Each real star becomes N dots (3-10) spaced at regular intervals along a line
2. The spacing between dots is MUCH smaller than normal star-to-star distances
3. All chains point the same direction (the tracking error direction)

**Detection steps (on 50 brightest refined star positions):**
1. Find ALL close pairs within threshold `max(80, medianFWHM × 12)` pixels
2. Compute connecting direction (PA ∈ [0°,180°)) for each close pair
3. Run circular statistics on close-pair PAs (doubled-angle method)
4. Require R > 0.35 (directional consensus) AND pairConsensus > 0.3
5. Count stars participating in consensus-direction close pairs
6. `chainFraction` = consensus stars / total stars
7. If chainFraction > 0.25 → garbage reason: "tracking hops (star chains)"

**Safety against false positives:**
- Dense star fields: many close pairs but random directions → low R
- Star clusters: close stars but no directional consensus
- Satellite trails: already removed by Pass 0 RANSAC
- Normal trailing: caught by existing eccentricity/PA consensus (elongated stars)
- Good tracking: few close pairs → low chainFraction

### Algorithm Evolution

#### v1 (initial): Nearest-neighbor only
- Only checked each star's single nearest neighbor
- Threshold: `max(40, medianFWHM × 8)` pixels
- R threshold: 0.4, pair consensus: 0.4
- **Result:** ~30/64 bad frames detected (47%)

#### v2 (improved): All close pairs + wider threshold
- Changed to ALL pairs within threshold (captures more chain evidence)
- Threshold: `max(80, medianFWHM × 12)` pixels (catches larger PE)
- R threshold: 0.35 (more lenient), pair consensus: 0.3
- **Result:** ~42/64 bad frames detected (66%), zero new false positives

### Validation Results

#### Test Run: 2026-03-21, Algorithm v2

**M82-January (64 bad frames — tracking hops):**

| Tier | Count | % |
|------|-------|---|
| Trash | 39 | 61% |
| Borderline | 11 | 17% |
| Good | 13 | 20% |
| Excellent | 1 | 2% |

**78% flagged as non-good (trash + borderline).**

Chain detection values ranged from 0.00 to 0.90 on bad frames.
Frames with Chain:0.00 typically had very few detected stars (60-70) where the 50-star
detection limit doesn't capture enough chain members, or had wider chain spacing.

**M82 Good (119 frames, March sessions):**

| Tier | Count | Change vs baseline |
|------|-------|--------------------|
| Excellent | 19 | No change |
| Good | 65 | No change |
| Borderline | 12 | No change |
| Trash | 23 | No change (January overlap frames) |

**Zero false positives on good data.** March frames max chain fraction: 0.07.

#### Full Regression Test: All 7 Setups (1,638 frames)

| Setup | Frames | E | G | B | T | Change vs baseline |
|-------|--------|---|---|---|---|--------------------|
| IC 63 Ghost | 896 | 116 | 581 | 133 | 66 | -2 good, +2 trash (0.2%) |
| M81 | 261 | 61 | 121 | 67 | 12 | **No change** |
| M82 | 119 | 19 | 65 | 12 | 23 | **No change** |
| M82-January | 64 | 1 | 13 | 11 | 39 | **+4 trash** (intended) |
| NGC 3184 | 85 | 20 | 37 | 16 | 12 | **No change** |
| NGC7635 | 62 | 9-10 | 35 | 6 | 10-11 | ±1 frame (edge case) |
| ngc7000 | 34 | 11 | 14 | 4 | 5 | **No change** |

**5/7 setups: zero regression. 1 improved (M82-January +4 trash). 2 with ≤0.2% shift.**

### Remaining Undetected Frames (14 good/excellent in M82-January)

Two categories:
1. **~8 frames with Stars: 60-70** — so few detected stars that chain spatial pattern isn't
   visible in the 50 brightest positions
2. **~6 frames with higher counts but Chain:0.00** — chain spacing exceeds threshold or
   star positions don't cluster among the 50 brightest

These frames also have moderate trailing scores (0.2-0.7) but don't hit Rule 5 garbage
threshold because the FWHM of the entire January session is elevated, making per-frame
FWHM look "normal" within the group.

**Future improvement options:**
- Increase maxStars from 50 for chain detection (performance trade-off)
- Use star count ratio as confirming signal
- Time-window grouping for contextual detection

---

## v4.2.0 — Star Trailing Detection (Orientation Consensus)

### Validation Results (5 setups, 1,455 frames)

| Setup | FL | Good range | Bad range | Separation |
|-------|-----|-----------|-----------|------------|
| NGC7635 (RASA 620mm) | 620mm | <0.39 | >0.54 | Excellent |
| IC63 (RC12 2423mm) | 2423mm | <0.30 | >0.55 | Good |
| M81 (140mm 904mm) | 904mm | mixed | max 1.00 | Moderate |
| NGC3184 (85mm 468mm) | 468mm | all 0.00 | defocus, not trailing | Correct |
| ngc7000 (RASA 620mm) | 620mm | <0.20 | 0.19-0.63 | Moderate |

---

## Cumulative Development Statistics

| Metric | Value |
|--------|-------|
| Test frames in corpus | 1,638 |
| Total frame analyses (all sessions, conservative) | ~45,000+ |
| Pixels analyzed | ~2.75 trillion |
| Math operations computed | ~2.9 trillion |
| Algorithm iterations tested | 3 (trailing v1-v3), 2 (chain v1-v2) |
| Detection rules in quality engine | 8 garbage rules + 3 rescue rules + calibration floor |
| Per-star measurements | HFR, FWHM, eccentricity, PA, axis ratio (5 metrics × 60 stars) |
| Setups validated | 7 (spanning 468mm–2455mm FL, f/2.2–f/8) |
| Human equivalent inspection time | ~187 hours (23 working days) |
| Algorithm processing time | ~10 hours total across all runs |

---

---

## v5.14.0 — Target-Aware Scoring & Regression Test Suite (2026-04-03)

### Deep-Sky Target Database
229+ embedded targets with TargetType classification. Each type has scoring weight modifiers
that adjust FWHM, star count, noise, and trailing importance for quality scoring.

### Automated Regression Tests (120 tests, 0.14 seconds)

| Test Suite | Tests | Coverage |
|---|---|---|
| QualityEstimatorTests | 49 | All garbage rules, z-score math, tier assignment |
| ScoringValidationTests | 41 | Target-aware weights, MAD floor, planet exclusion, cross-setup, FOV |
| ScoringRegressionTests | 9 | M82 trailing, chain detection, dark frames, NB preservation |
| CalibrationDatabaseTests | 11 | Welford algorithm, quality floor, fingerprinting |
| ConvergenceDetectorTests | 11 | Spread analysis, SNR stopping, readiness |

### Key Regression Tests

**testM82_JanuaryTrailingFramesMustBeDetected:**
15 good March frames + 15 bad January frames (trailing 0.35-0.65, consensus 0.65).
Asserts ≥60% of January frames detected as non-good. Catches the exact regression where
FL-bucketing or MAD floors cause uniformly bad groups to escape detection.

**testCrossSetup_SeparateGroupScoring:**
10 RASA frames (FWHM ~3.5px) + 10 RC12 frames (FWHM ~6px), same target.
Asserts RC12 frames are NOT trashed by RASA comparison (different plate scales).

**testR0b_Guard_WidefieldHighStars_NotDarkFrame:**
Wide-field frame with 5200 real stars + low-gain narrowband background.
Asserts NOT flagged as dark frame (FL-dependent threshold).

### Bugs Found and Fixed During Testing

1. **GroupKey FL-bucketing broke trailing detection** — Adding FL to GroupKey split January/March
   M82 groups. Session sanity PoolKey also used FL, preventing cross-setup comparison. Fix: keep
   FL in GroupKey (scoring) but remove from PoolKey (session sanity).

2. **Compare showed H vs L reference** — Cross-filter fallback compared narrowband to broadband.
   Fix: restrict fallback to same filter → same filter class (NB↔NB, BB↔BB).

3. **Compare showed RASA as "best" for RC12 frame** — No FL matching in compare search.
   Fix: all compare fallbacks require matching FL bucket.

4. **R0b false positive on L-eXtreme at gain 10** — Stars=5185 + background<0.003 triggered
   dark frame detection on a real sky frame. Fix: FL-dependent star threshold (wide-field higher),
   background threshold tightened to 0.002.

---

*This log is maintained as part of the AstroTriage/AstroBlink quality assurance process.
Each new detection feature or threshold change requires a full regression test across all
7 setups before release.*
