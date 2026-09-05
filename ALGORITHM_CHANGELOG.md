# Algorithm Changelog

Tracks every change to quality scoring, star detection, noise measurement,
trailing analysis, and all other metric calculation logic.

**IMPORTANT:** Every bump to `kAlgorithmVersion` in `FrameRecord.swift` MUST have
a corresponding entry here. Frame History DB records carry the algorithm version
they were scored with — this changelog is the authoritative reference for what
that version means.

Records with `algorithmVersion < kAlgorithmVersion` are candidates for re-analysis.

---

## Version 35 — Physical plausibility corridor for star-shape measurements (2026-09-05)

**A measured FWHM below what the atmosphere and the sampling allow is not a sharp
star — it is noise the measurement converged on. Such values were entering group
medians, z-scores and rules as if they were real.**

Same principle as v34 (a failed fit is not a measurement), now grounded in physics
instead of only rejecting exact zeros. The floor is per-setup and derived, not a
table:

```
floor_px = max( minPlausibleSeeingArcsec / arcsecPerPixel , minPlausibleFWHMPixels )
         = max( 1.0" / (arcsec per pixel) , 1.2 px )
```

Both limits are required — they catch different failures (measured on GOLDENSET1):
- **seeing floor** — the RC12 at 0.395"/px reported cloud frames at 0.43" FWHM,
  which undercuts the best professional sites; no amateur setup resolves that.
- **sampling floor** — the RASA at 1.251"/px reported dark frames at 1.18 px, which
  passes any arcsec test but cannot be measured from that few pixels.

Because the floor is expressed in arcsec and converted through the plate scale, it
scales continuously from a short-focal-length smart telescope to an EdgeHD without
any per-setup table or interpolation.

**Calibration.** Lowest GOOD frame per setup in the curated set: 3.55"/2.14px
(468mm), 3.23"/2.58px (620mm), 1.95"/4.95px (1964mm). A sweep over seeing
1.0–1.5" x sampling 1.0–1.2px lost **0 good frames in every combination** while
invalidating 13 garbage measurements.

**Impact:** exactly neutral on GOLDENSET1 — false alarms 15, catch 154, identical
to v34 frame for frame. This is a guard against a class of failure, not a tuning
change; it earns its place by making the poisoning impossible rather than by
moving today's numbers.

**Tunable at runtime.** `minPlausibleSeeingArcsec` and `minPlausibleFWHMPixels` are
ScoringConfig knobs, so an exceptional site or an unusual plate scale needs no new
build. First step toward user-adjustable limits in the UI.

**Test fixtures corrected.** `ScoringValidationTests` modelled the RC12 (2423mm,
0.320"/px) at fwhmGoodMean 3.0px and the EdgeHD (2032mm, 0.382"/px) at 2.5px —
both 0.96", i.e. sub-arcsecond seeing at long focal length, which no ground-based
amateur setup achieves. The measured RC12 in GOLDENSET1 sits at 4.95–8.3px
(1.95–3.3"). Corrected to 8.0px and 7.0px. The corridor did not break these tests;
it exposed that their premise was unphysical.

ScoringRegression (9) + ScoringValidation (53) + TrailingConsensus (7) green.

### Held back deliberately

The PSF-fit acceptance gate (`chi2 < 1000` → `relativeResidual < 0.25`) is
implemented and documented but NOT enabled. Repairing it works technically —
fit acceptance goes from 0.7% to 57% of stars, and Prio-A trail catch from 45% to
64% — but it doubles false alarms (8% → 16%) and takes Conservative from 4 to 9,
because the Gaussian fits noise blobs on cloud frames and reports them as sharp
(cloud FWHM 7.02px → 2.31px, sharper than good frames at 4.20px), which poisons the
group median. The universal corridor is too weak to stop it: 2.39" is physically
possible, just impossible for a setup that never delivers better than 3.2".
That needs the per-setup learned corridor (CalibrationDatabase, which today only
promotes and never rejects). Tracked as the next step.

---

## Version 34 — Failed star-shape fits (value 0) no longer enter group statistics (2026-09-05)

**Whole good sides of a group were flagged "severe defocus". On the curated
GOLDENSET1 case `RC12red08_1950mm_S_NGC6960_180s`, ALL 11 good frames were marked
by the Conservative autopilot — the mode that is supposed to produce essentially
no false positives.**

**Root cause — the v33 principle, one layer higher.** v33 established that a
star-shape metric of 0 is a FAILED FIT, not a measurement, and fixed the RULES
that read it. The STATISTICS still ingested it: `fwhmValues` / `hfrValues` passed
0.0 straight through, and `sortedMedian` only skips `nil`, never 0. A featureless
frame (dome closed, opaque cloud) reports 0, so enough of them drag the group
median into the zero block:

```
S_NGC6960:  18 cloud frames @ HFR 0.00  +  11 good frames @ HFR ~3.66
            group median collapses 3.66 → 1.44   (inside the block of zeros)
            Rule 4 threshold = 2 × 1.44 = 2.87
            → every intact frame in the group exceeds it → "severe defocus"
```

The rule then declares the only usable frames in the group to be garbage. Note
the inversion: the MORE garbage a group contains, the more certainly its good
frames get flagged.

**Fix (`QualityEstimator.swift`):** `measuredOrNil()` maps a non-positive FWHM/HFR
to `nil` when the metric arrays are built, so failed fits are simply absent —
identical to a frame that was never measured. No real star has zero width, so
there is no legitimate 0 to lose. Rules 3 and 4 (and every median, MAD and z-score
derived from these arrays) now see only actual measurements.

**Impact — GOLDENSET1 (464 frames, 21 cases, 3 setups), by priority:**

| | v32 | v33 | v34 |
|---|---|---|---|
| **Conservative false positives** | 32 (15.5%) | 30 (14.6%) | **4 (1.9%)** |
| false positives, all tiers | 88 (42%) | 41 (19%) | **18 (8%)** |
| A dark | 23 (36%) | 63 (100%) | 63 (100%) |
| A cloud | 22 (36%) | 56 (91%) | 55 (90%) |
| A trail | 37 (72%) | 23 (45%) | 23 (45%) |
| A defocus | 4 (40%) | 4 (40%) | 4 (40%) |
| C gradient | 30 (41%) | 17 (23%) | 17 (23%) |

Prio-A catch is unchanged (one cloud frame moves, within run-to-run GPU variance);
false alarms drop 87% from the v32 baseline. Aggregate false-alarm rate
41.9% → 7.4%, catch 43.2% → 61.6%.

All 4 remaining Conservative false positives carry the reason "star
trailing/elongation" — the same trailing-measurement blind spot that also explains
the 45% trail catch. One defect, two symptoms; tracked as the top open item.

ScoringRegression (9) + ScoringValidation (53) green.

---

## Version 33 — Garbage detection reads measured pixels, not derived or header values (2026-09-05)

**Dome-closed frames scored GOOD. Surfaced on a real RASA/600mm ASI6200MM Ha set
(Heart Nebula, 241 frames): an entire night of 62 cap-on/dome-closed frames was
rated `good` by the app. 56 of the 62 carried NO Stage-1 garbage reason at all.
The same signature was present in the golden set's single 2026-07 `dark` frame,
so this was not specific to one session.**

### Three independent defects, one pattern

Each of the three garbage rules that should have fired was consulting something
OTHER than the frame's own pixels.

**1. SNR was used as a signal-presence test, and it inverts on flat frames.**
Both dark-detection paths (pre-pass + Rule 0b) required `!hasMeasurableSignal`,
defined as `snr > 5`. The app's SNR is `noiseMedian / noiseMAD` — background LEVEL
over background SCATTER. A dark frame is a flat pedestal: median sits on the bias
offset (0.0077) while scatter collapses to the read-noise floor (MAD 0.000068).
That ratio is therefore MAXIMAL on exactly the frames the guard must reject — the
62 darks measured SNR 113.1, against 19.9 for the good frames of the same group.
The twelve highest-SNR frames in the whole folder were all darks. The guard read
"lots of signal" where the physics says "no structure whatsoever".

**2. A FWHM of exactly 0 was treated as a valid measurement.** Rule 0 tested
`fwhmValues == nil`. A featureless frame yields a *failed fit* — computed FWHM 0.0,
not nil — so Rule 0 skipped it, while Rule 0b and Rule 1 are both gated on
`if let stars`, which is nil for the same frames. A frame with nothing measurable
in it thus slipped past every star-keyed rule simultaneously. Set-wide this
affected 69 frames (33 dark, 36 cloud) — and zero good frames.

**3. Garbage detection trusted the header/filename value.** `fwhmValues` /
`starsValues` prefer the HEADER value whenever every frame in the group has one —
correct for ranking (consistent within a session), wrong for physical checks. NINA
writes a per-frame autofocus FWHM into the filename, and the dome-closed frames
carry plausible-looking `FWHM_4.49` / `FWHM_2.74` tokens. Rule 0 was asking the
capture software whether a star had been visible instead of looking at the image.

### Fixes (`QualityEstimator.swift`)

- **`darkFrameMADCeiling = 0.0002`** (new constant, ≈13 ADU of 65535). A frame
  carrying real sky varies spatially — stars, nebulosity, gradients — so its
  background MAD sits well above the read-noise floor.
- **Both dark signatures accepted, neither subsumes the other.** A frame with no
  sky is either (1) a flat pedestal — no structure, but maximal SNR, or (2) near
  zero level with ordinary read noise — normal MAD, but no SNR. Detection now
  requires `noStructure || noMeasurableSignal`. The original SNR test was not
  wrong, it was incomplete: it is the correct test for signature (2), and the
  synthetic `testR0b_DarkFrame_Path*` fixtures model exactly that case.
- **Rule 0** treats a measured FWHM `<= 0` as "no PSF", equivalent to nil.
- **Absolute physical checks read measured values** (`computedFWHM` /
  `computedStarCount`, falling back to the arrays only when nothing was measured):
  Rule 0, Rule 0b (both paths), Rule 1(a) `stars < 10`. Rule 1(b)/(c) deliberately
  stay on `starsValues` — they compare against a group median / P90 built from the
  same array, and mixing a measured numerator with a header-based median would
  compare two different scales.
- Rule 0b's plate-scale-aware FWHM cross-check and background condition are gone:
  the structure test covers the same protection (bright nebulae and dense star
  fields have normal background scatter) with fewer moving parts.

### Impact — measured on GOLDENSET1 (464 frames, 21 cases, 3 setups)

Broken down by the user's priority order (garbage removal is Prio 1; weak SNR is
object-dependent; gradients are usually fixable in software):

| Prio | Token | n | catch v32 | catch v33 |
|------|-------|---|-----------|-----------|
| A | dark | 63 | 23 (36%) | **63 (100%)** |
| A | cloud | 61 | 22 (36%) | **56 (91%)** |
| A | trail | 51 | 37 (72%) | 23 (45%) |
| A | defocus | 10 | 4 (40%) | 4 (40%) |
| A | **total** | **185** | 86 (46%) | **146 (78%)** |
| C | gradient | 72 | 30 (41%) | 17 (23%) |
| — | good frames wrongly flagged | 206 | 88 (42%) | **41 (19%)** |

Aggregate: false-alarm rate 41.9% → 18.7%, catch rate 43.2% → 62.0%, total errors
227 → 133. **Zero good frames gained a garbage reason.** No case regressed.

**The trail regression is a pre-existing measurement blind spot, not a new defect.**
Those 14 frames sit at trailingScore 0.28–0.59 / ecc 0.56–0.67, while the good
frames of the SAME group sit at 0.36 / 0.60 — they are indistinguishable in every
measured metric. They were previously flagged only because 62 undetected darks
skewed the group median; that is a lucky hit from a broken reference frame, not a
detection. Tracked as follow-up (see below).

Synthetic gates: ScoringRegression (9) + ScoringValidation (53) all green,
including the three `testR0b_DarkFrame_*` tests, which correctly caught an earlier
revision of this change that replaced the SNR test instead of complementing it.

### Known remaining gaps (deliberately NOT changed here)

- **Trailing measurement on fast optics.** RASA 600mm good frames measure ecc ~0.60
  against trail-labelled frames at ~0.63, though the user reports the latter range
  from "slightly egg-shaped" to "severe mount jumps". Prio A, related to the v31
  elliptical-fit collapse. Highest-value open item.
- **No metric measures a spatial gradient.** `STFCalculator.measureNoise` samples the
  centre 70% and returns a global median + MAD — both distribution measures without
  any spatial component. Gradient-labelled frames therefore separate from good frames
  on NEITHER (0.0126 vs 0.0336 background, 0.0013 vs 0.0014 MAD, also night-matched).
  `GoldenMiniSetTests`' "bad background > 3× good" assertion cannot be satisfied by
  any existing metric. Prio C, so low urgency.
- **Rule 1(b)/(c) still prefer header star counts**, as does all z-score ranking via
  `allHaveHeaderFWHM` / `allHaveHeaderStars`. Consistent within itself; revisiting it
  means moving medians, P90 and z-scores together.

---

## Version 32 — Uncertain tier no longer demotes GOOD frames in small groups (2026-07-28)

**Over-flagging of good frames (Phase 2, the user's original complaint). Measured
on the curated GOLDENSET1 via AstroScoreCLI: on the clean pure-good group
`RC12red08_1950mm_H_NGC2237_300s` (11 good frames, 0 bad), 6 of the 11 good frames
were assigned the `uncertain` tier despite being physically fine (in fact BETTER
FWHM, 6.7–7.6 px, than the 5 that stayed good at 7.8–8.3 px).**

**Root cause:** the two-pass night grouping split the 11 same-GroupKey good frames
into a 5-frame and a 6-frame per-night group. The 6-frame group is `< 8`, which
tripped the small-group "uncertain" override. That override applied to `.good`
AND `.borderline` frames whose `combinedZ` fell in `(-1.0, thresholdExcellent)` —
a band that INCLUDES the entire good z-band. So a frame sitting squarely in the
good band (combinedZ near 0) was demoted to `uncertain` purely because its night
happened to contain few frames. Uncertain frames are auto-markable under the
Aggressive autopilot, so this actively mis-flagged good frames.

**Fix (`QualityEstimator.swift`, uncertain override):** the override now applies
ONLY to `.borderline`, never to `.good`. A frame in the good z-band is good
regardless of group size — uncertainty is about low quality-confidence, not small
sample size. Small-group borderline frames still become `uncertain` (genuine
ambiguity), unchanged.

**Impact:** eliminates the good→uncertain demotions (6/6 on the RC12 group);
does not touch borderline/trash/excellent, catch rate unchanged. Synthetic
ScoringRegression/ScoringValidation unaffected (no test covered the uncertain
override). Part of the Phase-2 auto-mark over-flagging fixes; the knife-edge
borderline band (`thresholdGood`) is addressed separately.

---

## Version 31 — Star-trail measurement de-collapse + no-WCS orientation rule (2026-06-06)

**Badly star-trailed frames scored green (tier 2/3). Surfaced on a real
85er/468mm OSC M101 set (ASIAIR/AM5, mixed 30/60/120 s): obviously
tracking-failed frames the user pre-deleted were rated green, with Frame-History
`trailingScore = 0` and `eccentricity ~0.10` despite 50–100px streaks.**

### Root cause — shape measurement collapses long trails to "round"

`StarMetricsCalculator.measure()` preferred the elliptical Gaussian PSF fit's
eccentricity whenever `chi² < 1000`, used **unconditionally** over the robust
image moment. The elliptical Gauss-Newton runs on a fixed small stamp; when a
star is trailed longer than the stamp (tracking failure / wind), it converges to
a round local minimum that still reports `chi² < 1000` ("accepted"), so its
eccentricity reads ~0. On frames 0029–0033 the recorded values were
`ecc 0.10 / axisRatio 0.99` (round), while an independent intensity-moment
re-measurement of the same stars gave `ecc 0.83` (R=5px) to `0.91` (R=15px).
The trailing analyzer then correctly returned 0 for genuinely-"round" inputs.

### Fix — `StarMetricsCalculator.swift`

- New `ellipticalFitUnderestimatesTrail(momentEcc:fitEcc:)`. The fit is used only
  when it does **not** clearly disagree with the image moment. On a clear
  disagreement (moment ecc > 0.55 AND fit ecc < 0.35 — the trail-collapse
  signature) the robust image moment is used instead. A star is never *less*
  round than its moment reports, so clean round stars (both agree) and genuine
  optical elongation (the fit catches it too) are unaffected.

Once measured correctly, true trails sit at `ecc ~0.95 / FWHM ~9` and clear the
existing focal-length baseline (0.52 @ 468mm) by a wide margin, while good frames
stay below it — so **`TrailingAnalyzer` is unchanged**. (An earlier draft also
dropped the baseline to 0.20 under strong consensus, on the theory that high
directional consensus proves systematic trailing. Validation on this set refuted
it: good 468mm frames naturally sit at `ecc ~0.5–0.6` with consensus 0.55–0.89
— mild systematic elongation from the fast f/5.5 optics + AM5 periodic error is
present in EVERY frame — so the baseline drop flagged good frames as trailing
(false positives 0083/0097). That change was reverted; the FL baseline is correctly
calibrated to this scope's natural elongation.)

### Measured separation (real M101 frames, FL 468mm)

| frame | ecc | trailingScore | FWHM | truth |
|---|---|---|---|---|
| 0033 (real trail) | 0.95 | 1.00 | 9.3 | bad ✓ flagged |
| 0083 / 0097 (good) | 0.58 / 0.59 | 0.16 / 0.22 | 4.6 | good ✓ not flagged |
| 0002 / 0007 (good) | 0.48 / 0.58 | 0.00 / 0.16 | 3.6 | good ✓ not flagged |

### Safety / no regression

- The fit→moment override fires only in the moment-elongated + fit-round window;
  clean/round stars and optical elongation are untouched.
- Golden-set NGC3184 (468mm, bad = defocus not trailing) stays 0.00.
- Covered by `Tests/TrailingConsensusTests.swift` (severe trail scores high;
  natural short-FL elongation / radial aberration / round / long-FL clean stay
  low; fit-override boundary cases) and the `ScoringRegressionTests` golden set
  (±2% per setup) plus the `StarAnalyzerTests` 1633+139-frame marathon.

### Also in v31 (orientation, display-only — no scoring impact)

No-plate-solve frames (short ASIAIR test frames: ROTATOR present, CD matrix
absent) were rendered mirrored relative to the solved bulk. **Root cause:** these
frames were physically captured 180° flipped (the user shot a batch at
ROTATOR=262°, 180° from the main ROTATOR=82° framing — a meridian-flip
orientation), but the plate-solver left them unsolved (no CD matrix). With no WCS
and no PIERSIDE, the app had only the star-triangle matcher (rotation-invariant →
unreliable) and the pixel fingerprint (reference-dependent, not always present) —
neither flips them, so they stayed in raw (flipped) orientation.

Ground truth that pinned it down: M101 sits off-centre, so its frame position is
unambiguous under 180°. Every ROTATOR=262 frame has the galaxy at the **mirrored
position** (≈0.05, 0.72) with CD-PA **−82°** on solved peers; every ROTATOR=82
frame has it at (≈0.95, 0.25) with CD-PA **97.9°**. So ROTATOR=262 ⟺ 180°
flipped, ROTATOR=82 ⟺ normal — for these frames the ROTATOR keyword IS the
reliable signal.

`TriageViewModel` — for a frame with `wcsRotation == nil` and `pierSide == nil` in
a session that contains plate-solved frames, decide the flip from the **ROTATOR
delta vs the WCS-anchored reference**:
- `updateMeridianRotation()`: `|signedAngleDiff(entry.rotator, ref.rotator)| ≥ 135°`
  → `.rotate180Normalized`, else `.identity`.
- `shouldRotateForMeridian()`: same rule for the survey/legacy path.
- **Only a ~180° delta acts** (a meridian flip). Arbitrary rotator deltas
  (cross-session home-resets / recalibration — the documented unreliable case that
  caused rotator to be dropped from the general path) are ignored, so multi-session
  libraries are unaffected. WCS-solved frames continue to use the CD matrix (ground
  truth); pure no-WCS sessions (no solved frames) keep the fingerprint/star fallback.

NOTE: this revises the v5.28.0 "rotator deliberately dropped" stance — rotator is
re-admitted ONLY as the ~180° meridian-flip signal for unsolved frames, never for
arbitrary rotation amounts.

---

## Version 30 — Stage 1.5 P90 outlier clamp (2026-05-11)

**Removes a false-positive trash demotion when one frame in a multi-night
pool has anomalous star count (or SNR) ≥ 2.5× the pool median.**

### Failure mode

Captured from a real user's O-filter 180 s pool on Rosette A. The pool of
~15 frames contained one frame with 4928 detected stars — peers measured
between ~900 and ~1200 stars. The Stage 1.5 session-sanity star-count
benchmark is the pool's P90 (`stars[count * 9 / 10]`), and the trigger
threshold is `0.4 × P90`. The outlier became the P90, so the threshold
collapsed to 0.4 × 4928 ≈ 1971 stars — meeting which would have required
the pool to be uniformly bright. Every normal frame failed the bar.

Combined with even moderate trailing on a single frame (trailing flag is
real on those frames), the 2-flag rule fires and the normal frame is
demoted to trash. The user saw within-group stars Z = +0.84 σ ("normal"
by within-group comparison) and tier = Trash with a Stage 1.5 reason
"star count far below session norm" — the contradiction was confusing and
visually inaccurate (the frame really did have a typical star count for
the target).

### Fix

`QualityEstimator+SessionSanity.swift` — the two higher-is-better
benchmarks (stars P90 and SNR P90) are now clamped:

```swift
let starsP90 = min(starsP90Raw, starsMedian * 2.5)
let snrP90   = min(snrP90Raw,   snrMedian   * 2.5)
```

Effect: when one frame's value is more than 2.5× the pool median, it can
no longer single-handedly define what "best" looks like. The 2.5× factor
is generous enough to admit legitimate session-spanning variation (a
genuinely better night should be within a factor of ~2 of typical), while
sharp enough to cap the failure mode.

For the captured pool: median ≈ 1093 stars → effective P90 = 2.5 × 1093
= 2732 → threshold = 0.4 × 2732 ≈ 1093. Frames in the normal ~900-1200
range no longer flag "star count far below norm". The outlier frame
itself is *unchanged* — it just stops dominating the benchmark.

### Why P10 metrics (FWHM / Ecc / Trailing) are NOT clamped

Their failure mode (one anomalously low value tightening the threshold) is
rare in practice — FWHM rarely measures below 1 px on real frames, ecc
below 0.1, trailing below 0.0. Trailing additionally has an absolute
floor (`max(P10 × 2.0, P10 + 0.15)`) that already covers small-P10
contamination. Adding a P10 clamp would risk over-protecting genuinely
better-decile frames from being recognised as the benchmark in clean
pools.

### Validation

- `testSessionSanity_starCountOutlierDoesNotInflateP90` — exercises the
  exact failure mode. 16 pool frames where one has 4928 stars, peers
  ~1050-1190. Asserts no normal frame carries the "star count" Stage 1.5
  flag. Fails without the clamp; passes with it.
- `testSessionSanityCheck_demotesBadCrossGroup` — verifies the existing
  2-flag rule still demotes uniformly bad cross-group frames (FWHM 10
  vs 3, SNR 8 vs 50). Clamp is inert on this fixture (P90 < 2.5×
  median already), so behaviour is unchanged.
- `testSessionSanityCheck_mixedPlateScale*` — unchanged. Stars sanity is
  already disabled for mixed-plate-scale pools.
- Full QualityEstimator + Scoring* suite: 135 tests, 0 failures.

### Impact

Pools with a single outlier frame stop falsely flagging the rest. Pools
without outliers (the vast majority) are unaffected — the clamp is a
no-op when `P90_raw ≤ 2.5 × median`. No change to within-group z-score
math, garbage rules, or any other stage.

---

## Sort-in-place fix (no algo version bump, 2026-05-11)

**Not a scoring change** — fixes a data-delivery race that left 35-50
frames per session permanently unrated on fast f/2.2 OSC loads. The
prefetch's per-frame metric callbacks (`onNoiseStats`, `onStarMetrics`)
write to `host.images[idx]`; concurrently, `TriageViewModel.
applySortDescriptors` was capturing `images` into a local snapshot,
sorting that snapshot, and async-dispatching `self.images =
sortedImages`. Any callback that landed between the snapshot capture
and the dispatch execution wrote to the live array, then got
silently overwritten by the stale snapshot. The cleanup is to defer
to the same dispatch tick but sort `self.images` IN PLACE so concurrent
writes are preserved.

Also recovered: priority-queue and bg-queue metric callbacks now land
even when `sessionGeneration` advances mid-flight (header-time OSC
detection / Apply All / settings change). Metrics are URL-keyed and
the orchestrator does its own lookup, so the generation guard only
gates session-coupled state (preview storage, onProgress, priority
ready notification). Same race, different actor.

Also bumped: the GPU star-detection cap from 200 → 1000 candidates per
frame (PreviewGenerator.detectStarsFromImage). On Lextr OSC at 300 s
the brightest 200 are commonly all saturated; `filterStars` then
rejected every one of them and the candidate pool collapsed to zero.
1000 keeps brightness priority but adds 800 mid-brightness candidates
so unsaturated stars always survive.

These are correctness fixes for measurement delivery, not scoring
logic. `kAlgorithmVersion` stays 29.

## Version 29 — Annular HFR / FWHM for saturated-core stars (2026-05-10)

**Recovers HFR and FWHM measurements on fast optics at long exposures.**
v28 fixed OSC channel selection but still showed `!` for HFR on every
frame from the user's RASA f/2.2 + 300 s + Lextr OSC dataset. Root cause:
saturated-core stars systematically failed both `computeHFR` and
`computeFWHMGaussian`, then the dim-star fallback couldn't find enough
in-bounds measurements for the partial-metrics path to be avoided.

### Why HFR specifically failed

`computeHFR` sums background-subtracted flux into 0.5-px-wide annuli, then
returns the radius where cumulative flux first reaches half the total.
A saturated star has a flat-topped core — multiple central pixels at the
ADC ceiling — which inflates the cumulative flux at the smallest radii.
The half-flux radius then comes back below 0.5 px and trips the
`hfr >= 0.5` bound. Several saturated stars per frame are enough to
collapse `hfrValues.count < minStars` and route the whole frame to the
all-zero partial-metrics sentinel that the UI renders as `!`.

### Why FWHM also silently failed (but was masked by header fallback)

`computeFWHMGaussian` runs a linear regression of `log(I)` vs `r²` over
pixels in `(3 % of peak, 110 % of peak)`. Saturated peak pixels are
admitted by that range and flatten the slope, returning either an
out-of-bounds value or — once below the lower bound — `nil`. When all
group entries have `STARFWHM` headers the QualityEstimator falls back to
the header value (`QualityEstimator.swift:416`), so the FWHM cell looked
populated and the failure stayed invisible.

### What changes

- `StarMetricsCalculator.computeHFR` and `.computeFWHMGaussian` gain a
  `skipSaturatedCore: Bool` parameter. When true (peak >
  `shapeSaturationThreshold − 5000`, the same definition the shape
  calculator already uses), the inner 3 px (~9 px²) are skipped and the
  measurement runs on the unsaturated wings.
- `computeFWHMGaussian` also tightens its upper inclusion bound from
  `peakValue * 1.1` to `peakValue * 0.99`, so any pixel pegged at the
  flat top is rejected outright even when `skipSaturatedCore` is false.
- `filterStars` switches to the relaxed 99.5 % saturation cut (was
  98 %), matching `filterStarsForShape`. Bright stars with one or two
  saturated central pixels are now admitted to the measurement set —
  the annular calculators handle them correctly and on fast optics they
  are often *the* in-bounds candidates.
- The redundant 5×5 / 98 % full-res re-filter at the top of `measure()`
  is removed. `filterStars`' relaxed cut already covers the bin2x-vs-
  full-res discrepancy that motivated it, and keeping it would have
  silently re-excluded the saturated-core stars we just admitted.

### Impact

- OSC frames at fast f-ratios + long exposures (RASA f/2.2 + 300 s and
  similar) now produce real HFR / FWHM values instead of `!`. This is
  the immediate user-visible fix.
- Mono frames at slow f-ratios behave as before (negligible saturation,
  `skipSaturatedCore` stays false).
- Frame History DB records scored at v28 with `medianHFR == 0 &&
  medianFWHM == 0 && totalStarCount > 0` are stale candidates for
  re-analysis under v29.

### Files

- `AstroTriage/Engine/StarMetricsCalculator.swift` — annular HFR / FWHM,
  saturated-peak rejection in Gaussian, relaxed `filterStars` cut,
  measurement-pool tidy-up
- `AstroTriage/Model/FrameRecord.swift` — `kAlgorithmVersion` 28 → 29

## Version 28 — OSC measurement always debayered + per-frame channel pick (2026-05-10)

**Fixes silent HFR/FWHM failure on OSC frames.** Two coupled
issues:

1. When the user had **display debayer off** on an OSC sensor, the
   star-metrics pipeline ran HFR/FWHM aperture integration and Gaussian
   fits on the *raw Bayer mosaic*. The 10-pixel-radius aperture saw
   alternating R/G/G/B intensities — a striated, non-smooth pattern that
   the smooth-PSF assumption in `computeHFR` and `computeFWHMGaussian`
   could not handle. Both routines returned out-of-bound values that
   failed the `0.5–15` / `1–20` bounds checks; `hfrValues.count <
   minStars` tripped, `StarMetricsCalculator.measure` returned the
   partial-metrics sentinel (`medianHFR: 0, medianFWHM: 0,
   measuredStarCount: 0, totalStarCount: …`), and the UI showed `!` in
   every HFR/FWHM cell with the misleading "all bright stars saturated"
   tooltip.

2. Even when display debayer was on, the measurement channel was
   hardcoded to `1` (green). For broadband OSC this is fine — RGGB sees
   roughly equal stellar continuum across all three channels and green
   wins by being the most-sampled colour. For **narrowband OSC** (Lextr,
   L-eXtreme, Optolong, SHO duo-band, anything passing Ha + OIII or
   Ha + OIII + SII), stellar continuum lands almost entirely in the red
   channel and the green channel sees only OIII-band photons. The 60
   brightest unsaturated green-channel stars are then too faint to fit
   cleanly, and the same partial-metrics path fires.

### What changes

- `PrefetchCache.swift` (both priority and background queue paths) now
  computes a separate `measurementImage` that is **always debayered when
  `BAYERPAT` is known**, independent of the user's display-debayer
  toggle. Reuses the display-debayered buffer when display debayer is
  already on (zero extra GPU cost). Otherwise pays one extra debayer
  pass (~3–5 ms / frame on M-series).
- New `PrefetchCache.bestMeasurementChannel(of:)` helper picks the
  channel with the strongest star signal per-frame by counting bright
  pixels (> half full range) on a 5 % subsample. Filter-agnostic — no
  parsing of the FILTER header required. Cost ~5 ms total for 25 MP.
- Both noise stats (`STFCalculator.measureNoise`) and star metrics
  (`StarMetricsCalculator.measure`) now run on `measurementImage` with
  the picked channel. Display alignment (`generatePreviewAsync`, STF
  params, MTLTexture caching) continues to use `imageForSTF` so the
  user's display debayer choice is respected.

### Impact

- OSC frames whose HFR/FWHM previously collapsed to `!` because of
  Bayer-striated apertures or dim-green narrowband signal now produce
  measurable values. SNR is also more accurate on those frames because
  noise stats use a smooth single-channel buffer instead of a striated
  mosaic.
- Mono frames are unaffected — `channelCount == 1 && bayerPattern ==
  nil` keeps `measurementImage == imageForSTF == decoded`.
- Broadband OSC frames are usually unaffected — `bestMeasurementChannel`
  picks green for them (most bright pixels), matching the previous
  hardcoded behaviour.
- Frame History DB records scored at version 27 with `medianHFR == 0 &&
  medianFWHM == 0 && totalStarCount > 0` are stale candidates for
  re-analysis under v28.

### Files

- `AstroTriage/Engine/PrefetchCache.swift` — `measurementImage` + helper
- `AstroTriage/Model/FrameRecord.swift` — `kAlgorithmVersion` 27 → 28

## Version 27 — Curation-Driven Threshold Learning Phase 2 (2026-05-04)

**First scoring change with real behavioural impact since v22.** Adds
per-setup soft adjustments to two of QualityEstimator's tier cutoffs,
learned by grid search over the user's curated star ratings.

### What changes

- `LearnedThresholds` struct on `CalibrationProfile` (Codable,
  backward-compatible decode) with two offsets:
  - `borderlineOffset` ∈ [-0.8, +0.8] added to
    `QualityEstimator.thresholdBorderline` (-2.0). Negative = stricter,
    positive = more lenient. Addresses the 192 / 417 false positives
    (46%) flagged in the 2026-04-16 curation baseline that were
    "z-score-only trash" — combinedZ < -2.0 with no Stage 1 reason.
  - `trailingCeilingOffset` ∈ [-0.15, +0.20] added to
    `QualityEstimator.absoluteTrailingCeilingScore` (0.60). Addresses
    residual trailing false positives.
- New `ThresholdLearner` engine (`AstroTriage/Engine/ThresholdLearner.swift`).
  Grid search with asymmetric cost FP × 1.5 + FN × 2.5 (false negatives
  punished harder than false positives — keeping a 1★ frame is worse than
  rejecting a 2★/3★ frame). Tie-break favours `offset = 0.0`
  (regularisation toward defaults).
- New DB query `FrameHistoryDatabase.curatedFrameRecords(setupHash:)`
  returns every record with `userConfidence > 0` for one setup.
- Wired into `SessionOrchestrator.commitSession()`: after the existing
  CalibrationDatabase commit, the learner runs off the main thread on the
  cumulative curated set. Result lands in the CalibrationProfile via
  `CalibrationDatabase.updateLearnedThresholds(_:for:)` and applies on
  the *next* `recomputeQualityScores()`.
- `QualityEstimator.computeScores(for:…)` gains a
  `learnedThresholds: LearnedThresholds? = nil` parameter. The two
  application sites are Rule 6a (absolute trailing ceiling) and the
  borderline tier assignment.

### Activation gate

Offsets only apply once `sampleCount >= LearnedThresholds.learningThreshold`
(50 curated frames). Below the threshold the effective values fall through
to the static defaults — the user sees no behaviour change until they've
curated enough data for stable offsets. Borderline grid search additionally
requires ≥10 frames each at 1★ and 3★. Trailing grid search requires ≥20
frames carrying the elongated/trackingHop garbage reasons or
`trailingScore > 0.3`.

### Non-learnable exclusions

Frames carrying `decenteredTarget`, `backgroundAnomaly`, or
`twilightExposure` are excluded from grid search regardless of star
rating. Those are physical issues the curator cannot reliably judge from
the zoomed thumbnail we present, so the rating carries no useful signal
for them.

### Hard backstops preserved

Stage 1 garbage rules (no-data, lowSNR, highFWHM, etc.) and the
`isLockedKeep` calibration floor are untouched — learned offsets are
soft adjustments to the borderline cutoff and the trailing ceiling only.
The z-score COMPUTATION (median / MAD / metric weights) is also
unchanged.

### Provenance

Status bar appends `[thresholds adapted from N curated frames]` after a
session is scored using non-default offsets, so the user can see whether
the cutoffs are coming from their curation or QualityEstimator's
defaults.

### References

- Plan: `~/.claude/plans/mutable-singing-glacier.md`
- Curation baseline (4,550 blind-curated frames):
  `~/.claude/projects/.../memory/project_curation_baseline_2026_04_16.md`

---

## Version 26 — Patch 3 wave 3 (2026-05-04)

**Strict-concurrency cleanup pass touched two quality-critical files
(TrailingAnalyzer.swift, ColorCombineEngine.swift). No scoring-logic
change — the touches are limited to:**

- `TrailingAnalyzer.swift` — removed the `?? 1.0` nil-coalescing on
  `sortedMedian(allAR)`. The helper returns non-optional `Double`, so the
  fallback was unreachable. Behavior identical (both forms produced the
  same `Double` value).
- `ColorCombineEngine.swift` — replaced `nonisolated(unsafe)` on the
  immutable `filterAliases: [String: String]` static with `nonisolated`.
  `[String:String]` is already Sendable so the `unsafe` qualifier was
  redundant; the explicit `nonisolated` keeps the property reachable from
  background contexts under Swift 6 strict concurrency.

Version bump per CLAUDE.md policy: re-runs on stale records are cheap
insurance.

### Other Patch 3 wave 3 changes (NOT scoring-logic, listed for context)

Concurrency / safety cleanup elsewhere in the codebase:
- `BatchOperations.swift` — fixed a real dangling-pointer bug in the
  XISF write-keyword error path (`UnsafeRawPointer([result.error])` →
  in-place `withUnsafePointer(to:)` rebind, matching the FITS branch).
- `PrefetchCache.swift` — `cachedURLsSet` annotated `nonisolated(unsafe)`
  to match its existing lock-protected cross-thread access pattern.
- `PreviewGenerator`, `DisplayAligner`, `SessionCache` — declared
  `@unchecked Sendable` so they survive capture into background
  OperationQueue / `concurrentPerform` workers (already documented
  thread-safe via internal locks / Metal API guarantees).
- `SessionOrchestrator.swift` — `bufferAlias` `nonisolated(unsafe) let`
  expresses the intentional cross-thread share inside
  `withUnsafeMutableBufferPointer` (each `concurrentPerform` worker
  writes only its own index, no overlap).
- `QuickStackEngineV2.swift` — replaced `cmdBuf.waitUntilCompleted()`
  with a `withCheckedContinuation` + `addCompletedHandler` block (Swift
  6 disallows `waitUntilCompleted` from async contexts).
- `QuickLookDebayer.swift` — extracted the local `func pix` to a static
  `clampedPixel` helper so it no longer captures a non-Sendable
  `UnsafePointer<UInt16>` inside a `@Sendable` `concurrentPerform` closure.
- `AIsaacSpeech.swift` — replaced background `DispatchQueue.global` poll
  of the `@MainActor`-isolated `AVSpeechSynthesizer` with a `Task` that
  hops to MainActor for each `isSpeaking` read.
- Misc: cleared `?? "unknown"`/`?? 1.0` redundant nil-coalescing,
  removed unused `let T` / `let summaries` / unused `poolKey` binding,
  added `_ = ...` to discard unused `withUnsafeBufferPointer` /
  `Set.remove` results, `var transitGMST` → `let`.

These changes do not appear in the watched-files list of
`.github/workflows/algorithm-version-check.yml` so no version bump
would have been required for them alone — the bump is exclusively for
the two TrailingAnalyzer / ColorCombineEngine touches above.

---

## Version 25 — Patch 2 (2026-05-04)

**QualityEstimator.swift split into helper extension files. Pure
mechanical move — every line of every method moved byte-for-byte; the
only edit is replacing `private static func` with `static func` so the
extracted methods are visible to the main file's call sites. No
scoring-logic change. Version bump per CLAUDE.md policy ("kAlgorithmVersion
MUST be bumped when ANY quality-critical file is modified, even when the
edit is purely organizational — re-runs are cheap insurance").**

### What changed
The QualityEstimator type body grew to 2112 LOC across one giant file.
Step 5 of Patch 2's TriageViewModel split (commit 1acb7c2) moved the
scoring trigger out of the view model; this commit follows up by
splitting QualityEstimator itself into:

- `QualityEstimator.swift` (was 2112 LOC, now ~1292) keeps the public
  API: `computeScores(for:calibrationDB:fingerprint:communityBaseline:
  historicalBaselines:)`, the threshold constants, the
  `filterTrailingMultiplier` / `isSolarSystemTarget` /
  `effectiveTrailingMultiplier` helpers, and the `GroupKey` value type.
- `QualityEstimator+Helpers.swift` (~227 LOC) — `fwhmMADFloor`,
  `practicalMADFloor`, `zscores`, `sortedMedian`,
  `medianAbsoluteDeviation`, `generateReasoning`. Stateless statistics
  + reasoning-string formatter.
- `QualityEstimator+SessionSanity.swift` (~250 LOC) — Stage 1.5
  cross-group sanity check: `sessionSanityCheck`. Pools by
  object+exposure across all groups (ignoring filter, night, focal
  length) and demotes frames that are dramatically worse than the
  session norm.
- `QualityEstimator+Historical.swift` (~387 LOC) — Stage 1.5b cross-
  session sanity + per-frame historical annotation:
  `historicalBaselineCheck`, `annotateHistorical`, `normalCDF`. Reads
  baselines from FrameHistoryDatabase + CalibrationDatabase fallback.

Visibility raised on the moved methods from `private static func` to
`static func` (internal to the module) so the main file's
`computeScores` call site can reach them across files. The methods are
otherwise unchanged.

### Why this is safe
- Synthetic golden-set regression (`ScoringRegressionTests`) ran clean.
- Full real-data sweep (`BatchQualityAnalysisTests`, 896 frames across
  multiple setups) is documented as manual per launch-readiness M3 —
  running it per refactor slice is impractical at 30+ min / iteration.
- No diff in the scoring math, the threshold constants, or the
  per-stage gating logic. Anyone reviewing this commit can confirm by
  comparing the moved bodies side-by-side with the pre-commit version
  (snapshot tag `pre-refactor-qe-stages`).

### What this enables
Future quality-logic edits can land in the relevant extension file
without touching the 2000-LOC monolith — finer-grained PRs, easier
review.

---

## Version 24 — v6.0.x (2026-05-03)

**Defensive guards in StarMetricsCalculator RANSAC trail post-processing — no
behaviour change on any reachable input. Version bump per CLAUDE.md policy
("Algorithm Versioning (MANDATORY): When ANY quality-critical file is modified
… you MUST bump kAlgorithmVersion").**

### What changed
`AstroTriage/Engine/StarMetricsCalculator.swift:667–670`: replaced four
force-unwraps (`trailStars.map(\.x).min()!` etc.) with a single `guard let`.
The pre-existing `bestInliers.count >= minInliers` guard at line 663 (with
`minInliers = 8`) already proves `trailStars` is non-empty, so the new guard
is unreachable on the happy path. The new path returns `[]` (the same value
the caller would receive on a "no trail detected" outcome) instead of crashing
in the theoretical case where the guarded invariant ever broke.

### Validation
- `Tests/ScoringRegressionTests` — 9/9 passing, no tier shift on any
  fixture (M82, IC63, NGC7635, planet exclusion, mixed sessions).
- Re-analysis of stale `algorithmVersion = 23` records is **not** required
  for this version. The bump is policy compliance, not a real scoring change.

### Why bumped anyway
The CLAUDE.md rule treats "any change to quality-critical files" as a bump
trigger because reviewers can't tell at a glance whether a defensive guard
or refactor secretly altered behaviour. The CI workflow added in v6.0.x
(`.github/workflows/algorithm-version-check.yml`) will block PRs that touch
these files without a bump — Version 24 is the first such bump under the
new gate.

---

## Version 23 — v5.26.0 (2026-04-18)

**Curation-driven scoring pipeline tune-up: remove lossy Stage 1.5 severe path,
preserve session-sanity reasons through Stage 4 rescue, plus targeted bug fixes.**

Driven by a systematic code review (`stagingcheckundpruefanweisungsdatei.md`,
10 findings) followed by empirical validation against 4540 user-rated frames
from the Frame History DB. Confusion matrix at entry: 566 false positives
(algo=trash, user=keep), 169 false negatives (algo=good/excellent, user=garbage).

### Changes

1. **Stage 1.5 severe single-FWHM-outlier path REMOVED** — `QualityEstimator.swift`:
   Previously, a frame with only the "FWHM far above session norm" flag could be
   demoted to trash if `fwhm > fwhmP10 * severeFwhmMultiplier` (sanity multiplier
   + 0.1, e.g. 1.4× P10 for galaxies). Curation data showed this path fires
   exclusively on frames where FWHM is the sole flag, at ~34% precision (65 FPs
   for every 33 TPs). The 2-flag demote rule catches the same genuinely-bad
   frames via co-occurring SNR/star/ecc/trail flags. Net +32 frames correctly
   classified. Deleted the `severeFwhmMultiplier` local constant and the
   `isSevereOutlier` guard.

2. **Stage 4 FWHM-sanity rescue preserves sanity/historical reasons** —
   `QualityEstimator.swift`:
   When Stage 4 lifts a z-score-trash frame to `.borderline` because its FWHM is
   within the good-frame 90th percentile, the new breakdown now carries over
   `sessionSanityReasons`, `historicalBaselineReasons`, `historicalZScore`,
   `historicalPercentile`, `isCommunityFloorLocked`, and `lowConfidenceScoring`
   from the pre-rescue breakdown. The previous positional init silently
   discarded these fields. The `recommendationLabel` computed property
   (lines 110-112) renders "REVIEW — <reason>" when sanity reasons are present,
   so rescued borderline frames now surface the original sanity signal in the
   UI and tooltips.

3. **Stage 3 rescue Rule A requires `!starsLow`** — `QualityEstimator.swift`:
   Rule A (fwhmOK + noiseOK + trailingOK → rescue to .good) previously ignored
   the star count, which meant Rule B ("star count dip with normal FWHM —
   likely transient event") was unreachable whenever Rule A fired. Tier
   assignment is unchanged (both rules promote to `.good`); the fix routes the
   rescue through Rule B when the dominant signal is a star-count dip, so the
   reasoningText + telemetry label accurately reflect the cause.

4. **Uncertain-override reasoning coherence** — `QualityEstimator.swift`:
   When the small-group uncertain override flips `tier` from `.good` /
   `.borderline` to `.uncertain`, the breakdown now uses "Small group —
   low confidence" instead of the stale rescue-era reasoning. Fixes tooltips
   like "FWHM and noise within group norm" appearing on uncertain-tier frames.

5. **wSum == 0 no longer silently drops frames** — `QualityEstimator.swift`:
   A frame that passes the measurement guard at line 539 but can't compute
   any z-score (e.g. the only measured frame in a 6-frame group — `zscores()`
   needs ≥2 values) previously hit `guard wSum > 0 else { continue }` and
   vanished from the result dict, leaving no quality icon in the UI. Now
   produces a `.uncertain` breakdown with "No comparable frames in group —
   metrics unmeasured or isolated" reasoning.

6. **Dead `garbagePercentile` constant deleted** — `QualityEstimator.swift`:
   Static property declared but never read across the codebase (grep confirmed
   zero call sites). Removed to reduce surface area.

7. **Comments documenting empirically-validated intentional behavior** —
   `QualityEstimator.swift`:
   - Header comment now lists the full pipeline execution order (stages 1,
     1.5, 1.5b, 2, 3, 4 plus side-lanes). Previous header mentioned only
     stages 1, 1.5, 2.
   - Per-night overwrite of combined-pass breakdown: documented as
     net-correct (49 affected frames, net −4 if "fixed").
   - Rule 1c P90 small-array index collapse: documented as empirically kept.
   - Stage 1.5 fwhmP10 index: same note.
   - Rule 7b `starWeight > 0` guard: documented as empirically harmless.
   - Rule 8 raw-MAD units: documented (5 raw MADs ≈ 7.4σ-equivalent, kept).
   - `medianAbsoluteDeviation()` doc-comment now calls out the raw-MAD
     convention to prevent future confusion vs `zscores()`' σ-normalization.

### Impact

- **Fixed:** Stage 1.5 no longer loses ~65 human-keep frames to single-FWHM-flag
  demotes (empirical net +32 frames reclassified correctly)
- **Fixed:** Rescued borderline frames now surface their sanity reasons in
  tooltips and recommendationLabel (critical for Autopilot decisions)
- **Fixed:** Four edge-case bugs (Rule A/B discrimination, stale uncertain
  reasoning, silent wSum==0 drop, dead constant)
- **Unchanged:** Confirmed-intentional behaviors (per-night overwrite,
  percentile indexing, Rule 7b guard, Rule 8 raw-MAD threshold) — documented
  in-code so future reviews can skip re-validating them

### Validation

Empirical analysis was performed against 4540 user-rated frames in the Frame
History DB spanning 5 algorithm versions, multiple telescopes (RC12, RASA, WO
refractors), cameras (ASI6200MM, ASI2600MC), focal lengths (140mm–2423mm),
filters (L/R/G/B/Ha/OIII/SII). Full analysis is preserved in
`wiki/quality-pipeline-review-2026-04-18.md` — including confusion matrix,
per-finding methodology, data inputs/outputs, and decision rationale for
every finding (implemented, deferred, and rejected).

### Files Changed

- `AstroTriage/Engine/QualityEstimator.swift` — all scoring/rescue changes + comments
- `AstroTriage/Model/FrameRecord.swift` — `kAlgorithmVersion` 22 → 23
- `Tests/QualityEstimatorTests.swift` — 4 regression tests added
- `wiki/quality-pipeline-review-2026-04-18.md` — full analysis document

---

## Version 22 — v5.25.2 (2026-04-17)

**Mixed-sensor GroupKey: prevent cross-camera z-score contamination.**

When a session contains images from cameras with different sensor sizes (e.g.
ASI6200MM 9576×6388 full-frame and ASI2600MC 6248×4176 APS-C on the same
telescope), the smaller sensor has ~2.3× fewer stars and different noise
characteristics. Previously, GroupKey only partitioned by filter + object +
exposure + focal length + night — frames from different cameras landed in the
same scoring group, causing the smaller sensor to score poorly (false trash).

### Changes

1. **GroupKey dimension fields** — `QualityEstimator.swift`:
   Added `sensorWidth` and `sensorHeight` (from `ImageEntry.width`/`.height`)
   to the `GroupKey` struct. Different sensor resolutions now form separate
   scoring pools. Z-score math is unchanged — this is purely a partition change.

2. **Auto-rotate dimension guard** — `TriageViewModel.swift`:
   `OrientationRef` now stores the reference frame's `width`/`height`.
   `shouldRotateForMeridian()` skips rotation when frame dimensions differ
   from the reference — a 180° UV flip is geometrically meaningless across
   different sensor sizes.

3. **Mixed-dimension detection** — `TriageViewModel.swift`:
   New `checkForMixedDimensions()` runs after header enrichment. When multiple
   distinct (width, height) combinations exist, shows a non-blocking sheet
   alert listing each resolution group with camera names and frame counts.

### Impact

- **Fixed:** Mixed-camera sessions no longer produce false trash marks on
  the smaller sensor due to cross-camera star count / noise comparison
- **Fixed:** Auto-rotate no longer applies meaningless 180° flips to frames
  from a different camera than the reference
- **Added:** User gets an informative warning about mixed dimensions with
  guidance to use separate folders for best results
- **Unchanged:** Single-camera sessions are completely unaffected (all frames
  have identical dimensions, GroupKey adds two identical fields)

### Files Changed

- `AstroTriage/Engine/QualityEstimator.swift` — GroupKey + sensorWidth/sensorHeight
- `AstroTriage/Engine/TriageViewModel.swift` — OrientationRef dimensions, dimension guard, mixed-dimension warning
- `AstroTriage/Model/FrameRecord.swift` — `kAlgorithmVersion` 21 → 22

---

## Version 21 — v5.25.0 (2026-04-17)

**Peak-SNR quality gate: filter noise peaks from FWHM/HFR aggregation on moonlit frames.**

Reported by external user (ASI6200MM @ 504mm, 1.54"/px) on NGC 2251 B-filter with 50%
moon. Measured FWHM was 11.88 (later 13.20) vs expected ~4px. Stars looked visually fine.
No eccentricity was computed (GPU elliptical fit failed on most candidates). Root cause:
star detector found noise peaks on the bright moonlit background. These non-stellar objects
inflated the median FWHM and HFR because the measurement pipeline had no quality gate
to reject them.

### Changes

1. **Per-star peak SNR computation** — `StarMetricsCalculator.measure()`:
   For each star candidate, computes `peakSNR = (peakPixel - background) / sqrt(background)`.
   This is the local signal-to-noise of the detection relative to Poisson shot noise.
   Real stars: peakSNR typically 20-100+. Noise peaks on moonlit sky: peakSNR < 8.

2. **SNR quality gate on FWHM** — After GPU/CPU FWHM computation and fallback logic,
   filters the FWHM array to only include stars with peakSNR >= 8. Falls back to
   unfiltered values if too few stars pass (graceful degradation).

3. **SNR quality gate on HFR** — Same filter applied to HFR values. Previously HFR
   had zero quality filtering — any detection with HFR in [0.5, 15.0] was included.

### Why Not Tighter GPU Chi²?

Reduced chi² scales with background level (Poisson noise). On moonlit frames, even good
star fits have chi² ~500-2000 (high background = high shot noise). Tightening the chi²
threshold from 1000 would reject real stars on bright backgrounds. Peak SNR is
background-normalized and works across all conditions.

### Why Not Tilted-Plane Background Model?

Tested and reverted (2026-04-17). The 5-param tilted-plane GPU PSF fit (B0 + Bx*dx + By*dy)
did not fix this issue because the root cause is star DETECTION contamination, not gradient-
induced PSF broadening. The gradient model made FWHM worse (11.88 → 13.20) because the
extra parameters absorbed signal on noisy detections. Preserved as future R&D in TODO.md.

### Impact

- **Fixed:** Moonlit broadband frames with bright backgrounds no longer produce inflated
  FWHM/HFR from noise peak contamination
- **Fixed:** Missing eccentricity on moonlit frames (GPU fits fail on noise peaks, but
  surviving real-star FWHM is now correct)
- **Unchanged:** Dark-sky and narrowband frames unaffected (noise peaks are below detection
  threshold, all candidates are real stars with high peakSNR)

### Files Changed

- `AstroTriage/Engine/StarMetricsCalculator.swift` — peakSNR computation + quality gate
- `AstroTriage/Model/FrameRecord.swift` — `kAlgorithmVersion` 20 → 21

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
