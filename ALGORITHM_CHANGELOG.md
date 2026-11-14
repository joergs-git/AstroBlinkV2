# Algorithm Changelog

Tracks every change to quality scoring, star detection, noise measurement,
trailing analysis, and all other metric calculation logic.

**IMPORTANT:** Every bump to `kAlgorithmVersion` in `FrameRecord.swift` MUST have
a corresponding entry here. Frame History DB records carry the algorithm version
they were scored with — this changelog is the authoritative reference for what
that version means.

Records with `algorithmVersion < kAlgorithmVersion` are candidates for re-analysis.

---

## Version 46 — A brighter sky alone is not a defect (2026-11-14)

**User report (2026-11-14), same RC12 Pleiades session as v45 (753 frames):** "why is this frame
marked red — and some others too?" The frames that really are red: the first eight B frames of
2026-11-13 (21:39–22:37), verdict "abnormal background (clouds/gradient)".

### What was wrong

Rule 8 flags a frame whose background lies more than 5 raw MADs above the group median. Since v37
the MAD is floored at 2 % of the group's background, so on a stable session the rule fires from
roughly **+10–20 %** on. The eight frames measure 1015–1132 ADU against a group median of 853
(+19–33 %), declining smoothly as the object rises; their star counts are 2949–4254 against a
group median near 3300, FWHM normal. The next frame, at 1008 ADU, is Excellent — a knife-edge of
7 ADU between Stage 1 garbage and the top tier. Conservative auto-mark would have pre-deleted them.

Measured over the session's 54 background verdicts (ratio to the filter's median background, star
count relative to the filter's median):

| background ratio | frames | stars / median |
|---|---|---|
| 1.0–1.5 | 19 | 1.23–1.57 |
| 1.5–2.0 | 8 | 1.17 |
| 2.0–3.0 | 12 | 0.52 |
| ≥ 3.0 | 15 | 0.10 |

Below 2× the sky is brighter but transparency is intact (more stars, not fewer — moon-free, low
object or thin sky glow); from 2× on the stars disappear: that is cloud. The rule measured
"different", not "defective" — the same family as v33–v37.

### The fix

`deviation > threshold` AND ( background ≥ `backgroundAnomalyMinRatio` (2.0) × group median
OR star count < `backgroundAnomalyStarDropFactor` (0.8) × group median ). Both are ScoringConfig
knobs. A frame without any star measurement counts as "stars lost" (saturated twilight frames that
form a group of their own keep the reason); when no frame of the group has a star count the rule
works exactly as before. Only positive deviations, moon relaxation and MAD floor are unchanged.

### Measured

Session (v45 CLI vs v46 CLI, 753 frames): background verdicts **54 → 35**; no other garbage reason
changed on any frame. The 19 released frames: background 1.17–1.86× (median 1.31), stars 1.11–1.60×
the median → 17 Good, 2 Excellent, none picked up by session sanity. The 35 kept: background median
2.85×, stars median 0.39×. Tiers: trash 111 → 88, borderline 49 → 53, good 507 → 524,
excellent 86 → 88.

QUALITYCHECKMINI (104 frames): false alarms 12/72 → **11/72** (a good-labelled M82 frame was
"abnormal background"), catch 24/32 → 24/32; the seven saturated twilight frames keep their
background reason.

**Not measured:** GOLDENSET1 (user decision for this release series). Direction of any effect:
fewer background verdicts on frames between 1.1× and 2× the group background whose star count is
at least 80 % of the group's — by the priority list (gradients/brightness = class C) not a loss.

### Known limits

- A uniform thin haze that brightens the sky by less than 2× and dims stars by less than 20 % is
  no longer Stage 1 garbage; it remains visible in Sky Bg and in the z-scores (star count/PSF flux).
- The 2.0 / 0.8 limits come from ONE session plus one mini-set frame. They are knobs; re-derive
  on GOLDENSET1 before the next change to this rule.

### Tests

`QualityEstimatorTests.testV46_ModeratelyBrighterSkyWithAllStarsIsNotGarbage`,
`testV46_ModeratelyBrighterSkyWithLostStarsIsGarbage`,
`testV46_DoubledBackgroundIsGarbageEvenWithAllStars`. Scoring suites: 165 tests green.

---

## Version 45 — "Far above session norm" is measured against the session, and a soft frame is not Excellent (2026-11-14)

**User report (2026-11-14), live RC12 session (1964 mm, ASI6200MM, 0.395"/px, L/R/G/B 180 s,
"NGC 1432", 753 frames, six nights):** Compare shows B #0167 ("REVIEW — FWHM far above session norm,
trailing far above session norm") next to its "Best" B #0166, and "I cannot see that the right side
has a worse FWHM". Measured with AstroScoreCLI on the original files before anything was changed.

### What was wrong

The two frames are near-identical: FWHM 9.47 vs 9.70 px (2.5 %), eccentricity 0.37 vs 0.44. Both are
soft for this session (pool P10 6.85 px, median 7.78 px). They landed in opposite tiers
(Excellent / Trash) through two ranking defects:

1. **The trailing flag of session sanity was anchored on the best decile alone:**
   `trail > max(P10 × 2, P10 + 0.15)`. `trailingScore` is 0 whenever the direction consensus is not
   reached, so the best decile is 0 on practically every session and the threshold collapses to 0.15.
   On this session the pool measures P10 0.000, **median 0.246**, P75 0.349, P90 0.437:
   **442 of 667 non-garbage frames (66 %) exceeded the "far above session norm" threshold** — the
   median frame included. With the 2-flag rule any frame that was also soft (FWHM > 1.3 × P10) was
   demoted to trash; a neighbour whose consensus happened to stay below the gate (trailing 0.00)
   was not. The comment in the code said the `+0.15` floor "already mitigates" a low P10 — it does
   not when the P10 is exactly 0.
2. **Excellent despite clearly softer stars:** #0166 has zFWHM +1.87 (84th FWHM percentile of the B
   frames) and was rated Excellent (z 0.94) because star count (z +3) and a trailing score of 0.00
   (z −3 on a "lower is better" metric) outweighed it. As "Excellent" it was also offered as the
   reference in Compare.

### The fix

1. `trail > max(P10 × 2, P10 + 0.15, median + sessionTrailingMedianMargin)` with the margin 0.15
   (ScoringConfig knob). The best-decile terms stay, so nothing is flagged that was not flagged
   before; the flag is now additionally required to sit clearly above the pool's typical frame.
2. Excellent guard: a frame whose sharpness z-score (FWHM, HFR as fallback — the same value that
   enters the combined z) exceeds `excellentMaxSharpnessZ` (1.0, ScoringConfig knob) is capped at
   Good. Excellent → Good only; the combined z-score is unchanged; never below Good, so auto-mark at
   every level is unaffected by the guard.

Not a scoring change, same release: Compare's "Best" is chosen by tier first and z-score inside the
tier (`ImageEntry.isWorseCompareReference`) — session sanity and the guard change the tier without
touching z, so a demoted frame could still carry the group's highest z.

### Measured

Reporting session (753 frames, baseline CLI built from the untouched tree vs v45 CLI; measurement
identical, max FWHM drift between runs 0.06 px, trailing 0.000):

| | v44 | v45 |
|---|---|---|
| frames above the trailing-flag threshold | 442 / 667 (66 %) | 108 / 667 (16 %) |
| session-sanity flagged frames | 70 | 36 |
| trash | 127 | 111 |
| borderline | 56 | 49 |
| good | 483 | 507 |
| excellent | 87 | 86 |
| Stage 1 garbage verdicts changed | – | 0 |

- The 16 frames released from trash (9 → borderline, 7 → good): FWHM 8.8–11.4 px (median 9.66),
  trailing score median 0.26 / max 0.36, eccentricity median 0.43 / max 0.48 — soft frames with the
  session's ordinary trailing score. 25 frames stay session-sanity trash (trailing median 0.44).
- Excellent → Good: 3 frames (B, FWHM 9.29 / 9.47 / 9.66 px, zFWHM 1.18–1.87).
- #0166 Excellent → Good, #0167 Trash → Good.

QUALITYCHECKMINI (104 frames, 6 cases): false alarms 12/72 → 12/72, catch 24/32 → 24/32; one bad
frame (140 mm M81, bad star form) Trash → Borderline — still caught.

**Not measured:** the full GOLDENSET1 (user decision — no complete golden-set run for this change).
The trailing change can only remove session-sanity flags and the guard only moves Excellent → Good,
so the direction of any effect there is known: possibly fewer session-sanity catches among frames
whose trailing score is within 0.15 of their pool's median, no new false alarms.

### Known limits

- A pool in which more than half of the frames are trailed raises its own median and silences the
  flag. Real trails are Stage 1's job (Rules 5/6a, absolute); session sanity is a relative check.
- The FWHM flag is still anchored on the best decile alone (1.3 × P10 = 8.9 px here, 14 % above the
  pool median). It is one flag and cannot demote on its own.
- A trailing score of 0.00 still earns the full z bonus in the combined score (the consensus gate is
  a step, not a ramp). The guard removes the visible consequence; the step itself is unchanged.

### Tests

`QualityEstimatorTests.testV45_trailingFlagNeedsMarginAboveSessionMedian`,
`testV45_softFrameCannotBeExcellent`. Scoring suites: 150 tests green.

---

## Version 44 — The concentration test is measured in units of the frame's own star size (2026-11-06)

**User report (2026-11-05), live RC12 session (1964 mm, ASI6200MM, 0.395"/px, L/R/G/B 180 s,
"NGC 1432" = the Pleiades):** frame L #0018 is trashed for "star trailing/elongation" although its
stars are round; "the big stars produce long spikes through the RC, and in between many small rays —
those are taken for star trails". Measured on the original files before anything was changed.

### What was wrong

`StarMetricsCalculator.computeShape` rejects diffuse nebulosity with a concentration test: the peak
must be at least 2.0 × the mean of the positive pixels inside an aperture. That aperture was a
**fixed 5 px radius**. For a Gaussian the ratio depends only on radius / FWHM: it falls below 2.0
as soon as FWHM exceeds R / 0.76 = **6.6 px**. A 5 px radius is 2" on this RC and 10" on a 468 mm
refractor — a threshold on a quantity without physical meaning, the same family as v33–v36.

The existing escape for bloated stars (gradient rescue for PE arcs) only opens at median FWHM ≥ 8 px.
Between 6.6 and 8 px there was a **dead band**: every real star was discarded as "nebulosity". The
brightness-ordered top-60 pass then yielded fewer than 12 shapes, the v40 rescue pass scanned up to
600 further candidates — and the only ones that still passed the test were noise peaks on the steep
halo flanks and fine diffraction rays of saturated stars (a slope is "concentrated" on a 5 px scale).
Those measure eccentricity 0.6–0.9 pointing at the bright star.

Measured on the reported frame (FWHM 7.87 px = 3.1", NINA header 3.15"):
- 57 of the 60 measured "stars" sit 2.7–4.1 saturated radii from five saturated Pleiads; their
  median eccentricity is 0.75, the position angle is radial (median 7° off the direction to the
  bright star), and their amplitude is 0.1–0.6 × the halo pedestal they sit on. The three real stars
  in the sample measure 0.37–0.45. A crop mosaic of the sample shows halo flanks and rays, no stars.
- Emulating the test on 105 clean, unsaturated field stars: **2 of 105 pass at R = 5 px**
  (median ratio 1.78) against **57 of 57 halo detections** (2.26). At R = 10 px (1.25 × FWHM)
  105 of 105 real stars pass (median 4.33, p10 3.74) and the halo detections fall to 1.81.
- Direction consensus was 12 %, so Rule 6a never applied; Rule 5 (eccentricity above 2 × the FL
  baseline, 0.51 at 1964 mm, no consensus requirement) produced the garbage reason.

Session (244 frames, two nights): **36 frames flagged "star trailing/elongation", 35 of them with
FWHM 7.23–7.94 px and eccentricity 0.56–0.76** at a direction consensus of 0.10–0.53 — the band,
exactly; the unflagged frames measured a median of 0.40. How many halo candidates reach the sample
depends on the seeing of the individual frame (0–57 of 60 on eight consecutive frames), which is
why neighbours flipped between good and trash.

### The fix

The concentration aperture is `max(5 px, round(1.25 × median FWHM))`, capped at the shape aperture,
**for frames below the gradient-rescue threshold (median FWHM < 8 px)**. At 1.25 × FWHM a point
source gives a ratio of ~4.4 at any sampling. Frames with FWHM < 4.4 px keep the 5 px radius and
are measured exactly as before; frames from 8 px on keep the 5 px test + gradient rescue. The 8 px
literal is now the named constant `gradientRescueMinFWHM`, shared by both sites.

Scaling at ALL star sizes was measured first and rejected: over a 12 px aperture the "mean of the
positive pixels" is dominated by noise, so diffuse non-stars pass too and dilute the direction
consensus. On the M82 tracking-hop regression case (2423 mm, FWHM 9.6 px) a confirmed hop frame fell
from trailing 0.73 / consensus 0.77 to 0.35 / 0.59 and lost its garbage reason (mini-set catch
25 → 23). With the scope limited to the dead band that frame measures bit-identically.

### Results

**Reported session** (same 244 frames, v43 → v44): "star trailing/elongation" 36 → 3; frames with any
defect reason 44 → 11; good + excellent 135 → 193; trash 61 → 27. All 35 band frames are cleared
(31 good, 3 excellent, 1 borderline; eccentricity now 0.34–0.51, median 0.39, measured on real
stars — median direction consensus 0.81). The 119 frames with FWHM ≥ 8 px measure bit-identically. Remaining three:
L #0001 (first frame of night 1, flagged before as well: ecc 0.51, consensus 0.84) and two frames
of night 2 that were borderline and are now flagged by Rule 5 at eccentricity 0.526 / 0.531 with
trailingZ 1.005 / 1.053 — see "Known edge" below.

**GOLDENSET1** (971 frames / 25 cases; headline numbers on the 17 curated cases):

| | v43 | v44 |
|---|---|---|
| curated good frames below Good | 19 / 203 | **16 / 203** |
| … of those with a defect reason (Conservative) | 4 | **6** |
| catch, all tiers | 160 / 250 | 160 / 250 |
| cloud / dark / defocus / gradient / lowsnr / trail | 51 / 62 / 2 / 20 / 1 / 24 | identical |
| uncurated C 9 + IC 5070 below Good / with reason | 133 / 39 | 133 / 39 |

9 of 971 tiers change, all in RC12 cases with FWHM 6.2–8.1 px; RASA and the 450/468 mm cases are
untouched. Five good frames are promoted (two uncertain, two borderline, one trash → good).
**Three good-labelled frames gain a "star trailing/elongation" reason, one loses it** — all four sit
on the absolute trailing ceiling of Rule 6a (0.60): B_NGC6960 #0002 0.56 → 0.64, H_NGC2237 #0019
0.57 → 0.61, H_NGC6888 #0121 0.21 → 0.68 (its consensus rose 0.57 → 0.90 once real stars were
measured; it was trash by ranking before), H_NGC6960 #0000 0.60 → 0.55. Their eccentricity is
0.55–0.59 with 90–100 % direction consensus: genuinely oval stars (axis ratio ~0.82) that the user
accepts on this scope. All four Conservative false positives of v43 were of this kind (RC12 H-alpha
frames in the band, trailing 0.60–0.72, consensus 0.75–1.0); v44 has six (five H-alpha, one B;
eccentricity 0.55–0.67, trailing 0.61–0.85, consensus 0.86–0.93). On complete star samples the two
NGC 6888 frames that were flagged before measure MORE oval than v43 reported (0.61 → 0.67,
0.56 → 0.63), not less.

**Golden mini-set** (104 frames): false alarms 12 → 12, catch 25 → 24. The one move is a hop frame
without a defect reason in either version (ecc 0.71, consensus 0.47, measured bit-identically): it
was borderline only through the session-sanity flag "trailing far above session norm", and that
norm rose because the good frames of the case — FWHM 6.4–7.1 px, partly in the dead band — now
report their real trailing score (0.18–0.38 at 50–100 % consensus instead of 0.00 from an
incomplete sample). One good frame of that case (FWHM 7.69 px) had measured eccentricity 0.69 from the same
halo mechanism and now measures 0.37.

**Tests:** `Tests/OversampledStarShapeTests.swift` — synthetic frame with round Gaussian stars of
FWHM 7.3 px next to a saturated star with a power-law halo and thin rays. Negative control with the
scaling disabled reproduces the report: eccentricity 0.82, 0 % of the sample on a real star,
trailing score 0.38. With the fix: round, ≥ 90 % of the sample on real stars. Targeted suites
(ScoringRegression 9, ScoringValidation 53, QualityEstimator 83, HotPixelRejection 3,
GoldenMiniSet with its known strict expected failure on the hop case) green — 151 tests.

### Known edge (not changed here)

With complete star samples the RC12 at 1964 mm measures a typical eccentricity of 0.37–0.47 with
70–100 % direction consensus on good frames (every RC12 case of GOLDENSET1 and both nights of the
reported session), against an FL baseline of 0.255. The elongation rules therefore have a thin
margin on this scope: Rule 5 fires for luminance at eccentricity 0.51 (2 × baseline — at 468 mm the
same rule cannot fire at all, its threshold is 1.04), Rule 6a at eccentricity ~0.55 with consensus.
The two newly flagged session frames (0.526 / 0.531) have good-tier neighbours at 0.48–0.51. That
is a calibration question of the long-focal-length baseline / the relative form of Rule 5, to be
decided on labelled data — the per-setup learned corridor already on the list — not a measurement
defect.

### Rig

`AstroScoreCLI --stars-csv <path>` writes one row per measured star (position, eccentricity, PA,
axis ratio): the shape sample behind eccentricity / trailingScore / consensus. Plotting it over the
frame is what showed the sample sitting in the halos; a frame-level number cannot.

### Not changed

Detection, the saturation and crowding filters, the gradient rescue, apertures for HFR / FWHM /
moments, TrailingAnalyzer, every rule and threshold in QualityEstimator. Frame History records of
oversampled broadband sessions (median FWHM 6.6–8 px) scored before v44 may carry a spurious
"star trailing/elongation" reason and an eccentricity of 0.7–0.76; they are candidates for
re-analysis.

---

## Version 43 — The frame's position is its image center; a flat pedestal is a dark only without stars (2026-11-02)

**User reports (2026-11-02), one ASIAIR session (85 mm / 468 mm, ASI2600MC, 60 s H-alpha, "C 9",
392 frames):** (1) "consecutive frames land in F1 and F2 although only a slight rotation is visible;
a rotation must never make a separate object", and (2) "with H-alpha on an OSC the detection says no
stars, only noise peaks — that is simply wrong", confirmed on a second session ("IC 5070", 115
frames). Both were measured on the original files before anything was changed.

### Part 1 — CRVAL is the sky position of the reference pixel, not of the frame

**What was wrong.** Four consumers read `CRVAL1/2` as "where the frame points": the Field column,
Rule 1b (decentered target), Auto Rotate's WCS transform and the re-solve comparison. CRVAL is the
sky position of the reference pixel `CRPIX1/2`. NINA, ASTAP and PixInsight put that pixel at the
image center, so the shortcut was invisible on the data these features were built with. ZWO ASIAIR
(astrometry.net-style SIP solutions) puts it anywhere in the frame: on this session the true image
centers of 391 solved frames agreed to **0.037°** (0.024° p90) while their CRVALs scattered up to
**1.44°** (1.27° p90) — two consecutive frames one minute apart, camera untouched, carried CRVALs
1.71° apart. The field tolerance for this optic is 0.6 × 2.88° = 1.73°, so the Field column
split one pointing into F1 (252) / F2 (139) frame by frame; Rule 1b (offset > 30% of the field from
the median CRVAL) flagged 88 frames "target shifted off sensor (mount recenter)" for a mount that
never moved; Auto Rotate composed the CD matrices directly and shifted by the planar CRVAL
difference — but the CD matrix of a tangent plane 3.8° further east in RA at Dec +63° is rotated
against the reference by ΔRA·sin δ = 3.4° (meridian convergence), so frames blinked with a spurious
relative rotation of up to 3.4° and **17 px median / 92 px p90 / 103 px maximum** offset at the image
center although they were pixel-identical to 2 px. That is the "slight rotation" of the report.
The re-solve comparison compared CRVAL to CRVAL and CD rotation to CD rotation and reported the same
1.7° / 3.4° as a disagreement on every ASIAIR frame.

**The fix.** `Engine/WCSProjection.swift` (GUI-free, in the CLI source closure): `TangentPlaneWCS`
with the exact gnomonic inverse (`sky(atPixelX:y:)`), forward (`pixel(ofRA:dec:)`) and the local
north direction (`northAngle(atPixelX:y:)`), plus `WCSProjection.frameCenter(of:)` — the image
center projected through the solution, CRVAL only without a full WCS. Verified against astropy on
all 391 files: 0.0000" without SIP, ≤ 9.8" with the SIP terms the helper ignores.
- Field column / stacking gate: `FieldGrouping.skyCenter` reads `frameCenter`.
- Rule 1b: centers via `frameCenter`; with a full WCS the group's median center is projected
  onto the frame's own pixel grid and must land inside the sensor — per axis, the user's
  criterion ("even a 40% offset is the same image as long as the center still lies in the other
  frame"). Without a full WCS: great-circle offset ≤ 0.5 × the larger field edge
  (`decenteredCenterOffsetFraction`, was 0.3 of the field from the median CRVAL).
- Auto Rotate: `DisplayAligner.transformFromWCS` linearises the exact composition frame → sky →
  reference at the frame's image center from three mapped points (center + 1000 px in x and y).
  Exact at the center; corner residual median 0.36 px, max 6 px on this 2.9° field (was 17–103 px
  at the center). The reference frame is now the one nearest the median image center.
- Re-solve comparison: the stored solution is evaluated at the fresh solution's reference pixel
  (common pixel), rotation = local north angle there under both solutions. The two real headers:
  0.08' and 0.03° (were 103' and 3.3°). `WCSSolution(existingOn:)` now requires CRPIX.

**Measured — GOLDENSET1 (464 frames, 17 scored cases), rig with the parity fixes below:** exactly
neutral — 0 tier changes, 0 reason changes (no golden-set frame has an off-center reference pixel
far enough to matter). C 9: "target shifted off sensor" 88 → 0; the Field column shows one field.

### Part 2 — A flat pedestal with a stellar population is a faint sky, not a dark

**What was wrong.** Since v41 a background MAD below `darkFrameMADCeiling` (0.0001 ≈ 6.5 ADU) was a
dark on its own (pre-pass `noStructure` and Rule 0b(c)). The v36 comment had written down the
risk: "an absolute photometric threshold … could be wrong again for a sensor or exposure regime
quieter than anything measured so far." That regime is 60 s H-alpha through an ASI2600MC at gain
100 on an f/5.5 refractor: the sky sits ~8 ADU above the offset pedestal, so the background MAD is
**0.000068 — byte-identical to the RASA dome-closed darks** that calibrated the ceiling (same
camera family, offset 50, read noise). The MAD describes the background; a sky fainter than the
read noise is flat too. Result in the app: 337 of 392 C 9 frames and 85 of 115 IC 5070 frames
"noise peaks, not real stars (dome/cap)" with 1600–4600 measured stars each and the nebula plainly
visible. Conservative auto-mark would have pre-deleted them.

**The fix.** `hasStellarPopulation`: a pedestal frame is NOT a dark when it carries a measured star
count of at least `pedestalSkyStarsPerMegapixel` (20) per megapixel of sensor, its measured FWHM
lies inside the physical corridor (a failed fit proves nothing), and — when the GPU fit ran — the
median scale-free residual of the circular Gaussian fit (`relResidualCirc`) is below
`pedestalSkyMaxFitResidual` (0.17): the detections must be PSF-shaped. Applied to the pre-pass
`noStructure`, Rule 0b(a)/(b)'s `noStructure` and Rule 0b(c). Both limits are ScoringConfig knobs.

Why those two numbers (every pedestal frame of the three data sets, parity rig):

| population | frames | measured stars | stars / megapixel | fit residual | ecc |
|---|---|---|---|---|---|
| GOLDENSET1 darks (ASI6200MM, −10 °C, 61 MP) | 63 | 131–256 | **2.1–4.2** | **0.23–0.28** | 0.69–0.83 |
| GOLDENSET1 real frames on a pedestal (ASIAIR OSC, 26 MP) | 23 | 2051–3356 | 79–129 | 0.034–0.10 | 0.12–0.47 |
| C 9 (ASI2600MC, 0 °C, 26 MP) | 337 | 1862–4640 | **71–145** | 0.019–0.12 | 0.32–0.88 |
| IC 5070 (same camera) | 85 | 1645–3311 | **63–91** | 0.048–0.065 | 0.23–0.41 |

The density floor sits 5× above the warmest dark and 3× below the faintest real frame; the residual
limit 1.4× from either side. The residual is the physical backstop: warm-pixel clusters are not
Gaussians, however many a hot sensor produces. Per megapixel because the defect count and — for one
sensor — the star count both scale with the pixel count.

**Measured — GOLDENSET1, parity rig, v42 logic → v43:**

| | parity rig (= app before) | v43 |
|---|---|---|
| darks flagged dome/cap | 62 / 62 scorable (1 dark sits in a 4-frame unscored group) | **62 / 62** |
| good frames wrongly flagged (false alarms) | 21 / 203 (10.3%) | **19 / 203 (9.4%)** |
| bad frames caught | 168 / 250 (67.2%) | 160 / 250 (64.0%) |

Every change is in the two ASIAIR OSC cases: `ZWO-AM5_450mm_EXTR_NGC4477_180s` loses both false
alarms (2/12 → 0/12); `ZWO-AM5_450mm_EXTR_NGC4477_60s` catch by token: trail 16/16 → 9/16, cloud
2/8 → 1/8. Those 18 frames had "dome/cap" as their ONLY reason — the pedestal rule, not a trailing
or cloud rule, had caught them; their measured eccentricity (0.12–0.47) sits below the 468 mm
baseline (0.52), so the trailing rules see round stars. An accidental catch is not a catch (lesson
2026-09-09); the frames are now reported honestly as uncaught and belong to the open borderline /
mild-trailing work. **C 9:** dome/cap 337 → 0, trash 347 → 87 (38 trailing, the rest z-score).
**IC 5070:** dome/cap 85 → 0, trash 85 → 0 (21 excellent, 84 good, 10 borderline).

### Scoring rig corrections (no algorithm change; reference numbers re-based)

Found while measuring, all three rig/app parity gaps (no. 4–6 after `c825482`, `fc05188`, v42):
- `ScoringRunner.buildEntry` measured on the raw CFA mosaic — no debayer, no per-frame channel
  pick. On an H-alpha OSC frame the v41 extent gate then rejects every checkerboard "star": the rig
  reported "no signal" on 99 C 9 frames the app measured 3400 stars on, and half the app's count on
  the rest. It now debayers when BAYERPAT is known and picks the channel exactly like PrefetchCache
  (`bestMeasurementChannel` moved to STFCalculator, inside the CLI closure).
- `MetadataExtractor` — the rig's only header path — never set `focalLength`, `pixelSizeMicrons`
  or `solvedRA/Dec`, so every FL-dependent rule (apertures, seeing floor, trailing baseline, dark
  star threshold, Rule 1b) ran as "optics unknown" in the rig and Rule 1b never ran at all.

Old rig → parity rig, same v42 logic: false alarms 18 → 21, catch 169 → 168, 29 tier moves, all in
the five `ZWO-AM5_450mm_*` (ASIAIR OSC) cases, whose median star counts rise 3–7× (e.g. EXTR 60 s
386 → 2731). The v42 entry's numbers (18 / 169) were measured with the old rig; the GOLDENSET1
reference from here on is **false alarms 21/203, catch 168/250 at v42 logic** and 19/203, 160/250 at
v43. Parity check used: frame 0008 of C 9 measures 3411 stars / FWHM 5.34 / HFR 2.58 / SNR 114.7
in the app Inspector and in the rig.

### Not changed

`darkFrameMADCeiling` (0.0001), Rule 0 (no PSF), Rule 1, the trailing rules, all tier cutoffs.
Frame History records, community baselines and SSWEIGHT exports made before v43 keep their stored
values; records of ASIAIR OSC narrowband sessions scored by v41/v42 may carry the spurious
"dome/cap" and "shifted off sensor" reasons and are candidates for re-analysis.

---

### GOLDENSET1 composition after this release (2026-11-02 evening)

The two sessions of the reports were copied into the set as eight UNCURATED cases (507 frames, every
frame in `good/` because the user has not culled them; manifest `golden_export_20261102_221649.json`
records `labelSource` and the v43 tier/reasons per frame): `ZWO-AM5_468mm_{EXTR,H,L}_C9_60s`,
`ZWO-AM5_468mm_{EXTR,L}_C9_180s`, `ZWO-AM5_468mm_{EXTR,H,L}_IC5070_60s`. The set is now 971 frames /
25 cases. The 17 curated cases are unchanged by the addition (false alarms 19/203, catch 160/250 at
v43 — each case scores on its own). In the new cases v43 flags no dome/cap and no decentered frame;
it trashes 91 of the 392 C 9 frames (38 for trailing, the rest by z-score) and none of IC 5070.
**Those 91 need the user's eyes (Golden Set ▸ labels in-app) before they count as anything** —
until then the headline numbers are reported for the 17 curated cases only.

---

## Version 42 — Dual-band filters are narrowband; one filter table for app and rig (2026-11-01)

**User request (2026-11-01): "Extr must be rated as narrowband with a duo bandwidth. Logical."**

### What was wrong

`QualityEstimator.filterTrailingMultiplier` knew five narrowband names (Ha, OIII, SII, Hbeta,
NII). Everything else that was not L/R/G/B fell into the "unknown / exotic" default of × 0.7.
An Optolong L-eXtreme ("Extr", "Lextr"), L-eNhance, L-Ultimate, Antlia ALP-T, IDAS NBZ or an
L-Quad is a nebula filter: it passes two (or four) emission lines, its stars are Ha + OIII
stars, and its science target is diffuse emission — exactly the physics behind the narrowband
leniency (slight trailing barely affects diffuse emission; 300-600 s exposures are expensive).
Those frames were penalised for trailing more than twice as hard as an Ha frame of the same
night. The star-count weight was already right (0.5 for everything non-broadband).

A second defect surfaced while measuring: `Sources/AstroScoreCLI/CLIStubs.swift` stubbed
`ColorCombineEngine.canonicalFilterName` as the identity, so the headless rig never mapped
"H" → Ha, "O" → OIII, "S" → SII. GOLDENSET1 names its filters exactly like that. The rig has
therefore scored every narrowband case with the × 0.7 "unknown" multiplier while the app used
× 0.3 — the third rig/app parity bug (after `c825482` and `fc05188`).

### The fix

- `Engine/FilterClasses.swift` (GUI-free, in the CLI source closure) is the one home of the
  alias table (moved from ColorCombineEngine), the narrowband set, the dual-/multi-band
  classes (`Lextr`, `Lenh`, `Lult`, `Duo`, `Quad`) and `isNarrowbandLike(_:)`.
- `filterTrailingMultiplier` returns 0.3 for anything `isNarrowbandLike`; it classifies the
  name itself, so a raw alias ("H", "L-eXtreme") can no longer be scored differently by two
  code paths. `QualityEstimator` canonicalises through `FilterClasses` directly.
- ColorCombineEngine, the CLI stub, `FrameHistoryModel.normalizeFilterForChart`, the Metrics
  "Narrowband" scope and the navigation fallback ("same filter class") all delegate to it.

### Measured on GOLDENSET1 (464 frames, 17 scored cases)

Baseline = `main` CLI with the identity stub (narrowband cases scored × 0.7 in the rig, × 0.3 in the
app); v42 = shared table (rig = app) + dual-band as narrowband.

| | baseline | v42 |
|---|---|---|
| good frames wrongly flagged (false alarms) | 18 / 203 (8.9%) | **18 / 203 (8.9%)** |
| bad frames caught | 170 / 250 (68.0%) | 169 / 250 (67.6%) |

Per case, only three of 17 moved:

| case | false alarms | catch | what moved |
|---|---|---|---|
| ZWO-AM5_450mm_EXTR_NGC4477_60s (the dual-band case) | 1/3 → 1/3 | 11/24 → **12/24** | 6 bad frames borderline → trash, 1 bad good → borderline, 1 bad excellent → good; 1 good frame good → excellent |
| RASA_600mm_H_IC1805_300s | 5/55 → 5/55 | 81/118 → 80/118 | 1 bad frame (trailing 0.50, z −0.52 → −0.49) borderline → good |
| RASA_600mm_O_NGC7635_300s | 0/0 | 5/10 → 4/10 | 1 bad frame (trailing 0.46) borderline → good |

The two H/OIII losses are the rig catching up with the app: those frames were always scored with the
narrowband multiplier in the app. For the app the net effect of v42 is the EXTR row — more decisive
on the dual-band case, nothing lost elsewhere. Run-to-run GPU variance on this set is ±1-2 frames
at tier boundaries, so the single-frame moves are within noise; the six borderline → trash moves
are not.

### Not changed

Star-count weight (0.5 for non-broadband) and `broadbandCanonical` (L/R/G/B) are untouched.
Garbage rules key on `filterTrailingMultiplier` only through the trailing paths. Community
baselines, Frame History records and SSWEIGHT exports made before v42 keep their stored values.

---

## Version 41 — Sensor defects are not stars: two-axis extent gate on unbinned data (2026-09-09)

**User request: "Isolated hot pixels without neighbours must never be counted as stars."
This is the common root of three bugs already fixed one at a time (v38 P90 inflation, v39/v40
shape sample crowded out, `fc05188` empty frames with a fabricated count).**

### What was wrong

Neither star detector required a detection to have any spatial extent. The GPU kernel tests
"above threshold" and "3x3 local maximum"; the CPU fallback adds a sharpness test that a hot
pixel passes better than any star. On the ASI6200 the brightest "detections" of a narrowband
frame were sensor defects: live RC12 SII frames reported 10000-25000 stars where the same
frames carry ~2500 real ones.

### Two placements tried and rejected (v40 session, stashed)

1. In the kernel on the BINNED grid — 2x2 averaging smears a hot pixel into its neighbours,
   so noise passes: 11 cloud frames went from "no signal" to 857 stars.
2. Full-res after detection — correct, but only reaches the capped list of 1000 while the
   count comes from a GPU atomic over ~20000 candidates.

### The fix: extent test inside the kernel, reading the UNBINNED buffer

Detection stays on the binned grid; every candidate that passed threshold + local maximum
then locates its true peak in the 4x4 full-resolution block and checks that peak's direct
neighbours. `detect_stars_binned` takes the full-res buffer as buffer(10); the CPU fallback
(`StarDetector.hasStellarExtent`) does the same around its subsampled position. Cost is
bounded by candidate count, not image size (20 extra reads per candidate).

**The gate requires extent in BOTH image axes**: the brighter vertical neighbour (N or S)
AND the brighter horizontal neighbour (E or W) must each carry ≥ 25% of the peak's amplitude
above background. A first version accepted ANY one bright neighbour — and on this sensor
that is not enough: hot pixels come in adjacent PAIRS and short straight chains. Measured on
a good RC12 OIII frame (crop mosaics of the 32 brightest survivors): with the one-neighbour
test roughly half were 2-3 px clusters; with the two-axis test 29 of 32 are stars. Light from
a star spreads in two dimensions — even an undersampled star (FWHM 1.3 px) centred on a pixel
integrates ~28% of its peak into each direct neighbour — while defects extend along one axis.

| candidates > 5000 ADU | any neighbour | both axes |
|---|---|---|
| RASA dark frame (should be 0) | 6.9% pass | **0.0%** |
| RASA good frame | 98.1% | 98.0% |
| RC12 good OIII frame | 55% | 52% |

A neighbour-SUM test (8 neighbours ≥ 1x peak) separates similarly but has only a 44% margin
for undersampled stars and no golden case to validate it against — rejected in favour of the
simpler two-axis rule.

### The dark rule was riding on the phantoms

With the phantoms gone, **62 dome-closed RASA frames scored GOOD**: both dark paths (Rule 0b,
pre-pass) key on a star count — ≥10000, or an FL-scaled threshold that clamps to 10000 at
620 mm — and those counts had been 18000 hot pixels. The physical signature was already in
the code as a co-condition: a flat pedestal (`noiseMAD < darkFrameMADCeiling`, calibrated in
v36: darks at 0.000068, lowest good frame anywhere 0.000114). It is now sufficient on its
own, in the pre-pass and as Rule 0b(c). Star-count paths stay for the second signature
(near-zero level with ordinary read noise).

### What the golden set had been catching by accident

18 hazy RC12 OIII frames of 2026-09-01 were flagged "no signal detected" — the shape
measurement had FAILED on them (hot pixels + few real stars), and a failed measurement read
as a defect happened to be right. They now measure: 38-370 real stars against 800-3300 on
the same night, FWHM 9-10 px against 6-7. They are caught as "zero/near-zero stars" — a
measured verdict instead of an accidental one. The four "egg-shaped" frames from the v39
report belong to this set: their eccentricity 0.86-0.91 was measured on hot-pixel CHAINS
(vertical 4-6 px streaks); the real stars on them measure ecc ~0.4. They are caught by the
star count (46-142 stars).

### Impact — GOLDENSET1 (464 frames), v40 → v41

| | v40 | v41 |
|---|---|---|
| Conservative false positives | 4 | **4** |
| bad frames caught (garbage reason) | 147 | **158** |
| good frames below Good, any tier | 29 | **21** |
| frames reporting > 10000 stars | 30 | **0** |
| frames without eccentricity | 70 | **3** (empty ZWO frames, now "no signal") |
| star count on good frames, RASA | 4409 | 4345 (-1.5%) |
| star count on good frames, RC12 broadband | 4232 | 3818 (-10%) |
| star count on good frames, RC12 narrowband | 1824-3025 | 1065-1786 (phantoms removed) |

No bad frame lost its catch. Live check on the two hot-pixel nights (2026-09-01 hazy,
2026-09-05 unculled): catch 12 → 17 of 19 PRE-DELETE frames; the 09-05 night gains six
elongation hits with consensus 0.83-1.00 — crop mosaics show every star trailed diagonally
in the same direction, some doubled. The user had not culled that night yet.

**OSC caveat:** detection runs on the bilinear-debayered green channel, where a hot pixel
becomes a "+" of four interpolated neighbours at exactly 25% — the gate catches about half
of them (ZWO 60 s frames: 1902 → 490 counted, the rejects are all "+" spikes, the survivors
still include some). A clean OSC fix needs a CFA-domain test before debayer.

**Performance:** faster, not slower. AstroScoreCLI on GOLDENSET1 (464 frames, local SSD,
two back-to-back runs each): v40 127.5 s / 127.3 s → v41 96.6 s / 96.5 s (−24%, 0.275 →
0.208 s per frame). The gate costs 20 reads per candidate, but ~18000 phantom candidates per
hot-pixel frame no longer reach the PSF fits, the shape rescue, or the >5000-candidate
threshold re-dispatch.

ScoringRegression + ScoringValidation + TrailingConsensus green; new `HotPixelRejectionTests`
(synthetic stars + single / pair / chain defects, CPU and GPU paths, undersampled worst case).

---

## Version 40 — Shape rescue must reach a usable sample, not just a median (2026-09-08)

**Follow-up to v39, from the same live session. A frame measuring eccentricity 0.98 —
essentially a line — scored good and survived even Aggressive, because its trailingScore
and consensus were 0.**

v39's rescue triggers when fewer than 3 shapes were measured, since 3 is what a median
needs. But `TrailingAnalyzer` needs `minStarsForConsensus` (5) **elongated** stars before
it will compute direction statistics; with only 3-4 samples that is rarely reached, so it
returns trailingScore 0 and consensus 0. A frame landing in that gap gets a valid
eccentricity and no trailing analysis at all — and every elongation rule keys off trailing,
so nothing fires.

Seven frames of one live RC12 night sat in exactly that gap, eccentricity 0.64-0.98 with
trailingScore 0, all of them hot-pixel frames with >10000 detections.

**Fix:** the rescue now aims for 12 measured shapes rather than 3. The threshold is derived
from what the consumer needs, not from what a median needs.

**Impact — GOLDENSET1 (464 frames), v39 → v40:**

| | v39 | v40 |
|---|---|---|
| Conservative false positives | 4 | **4** |
| A total | 145 | **146** |
| A cloud | 54 | **55** |
| false alarms, all tiers | 24 | 29 |

The 5 additional soft-tier flags carry no defect reason — pure z-score movement from frames
that now contribute real eccentricity to their group. Conservative is untouched.

Live: the reported frame now measures trailingScore 0.64 / consensus 0.51 and is correctly
flagged; all 7 frames of that night with measured eccentricity but zero trailing are fixed.

ScoringRegression (9) + ScoringValidation (53) + TrailingConsensus (7) green.

---

## Version 39 — Shape rescue when hot pixels crowd out the star sample (2026-09-08)

**Live report: three RC12 frames with obviously egg-shaped stars scored as good. Their
eccentricity, trailing score and consensus were all nil — the shape had never been
measured at all.**

### Why the measurement never happened

Shape measurement takes the 60 brightest detections. On a sensor with hot pixels the
brightest "detections" ARE the hot pixels: single-pixel spikes whose second moments are
degenerate, so they either fail `computeShape` or fall below `streakAxisRatioThreshold`
and are discarded as satellite streaks. Fewer than the 3 measurements needed for a median
remain, `medianEccentricity` returns nil — and with it trailingScore and consensus — so
all four elongation rules have nothing to test and a visibly trailed frame looks flawless.

Measured on a live RC12 night: **12 of 21 OIII frames had no eccentricity at all**, 8 of
them with >10000 detections. Once real stars are reached the reported frames measure
eccentricity 0.86 / 0.90 / 0.90 with trailing 0.62–1.00.

**Fix:** a rescue pass scans deeper into the brightness-ordered candidate list, but ONLY
when the normal pass produced fewer than 3 measurements — a frame that already worked
keeps exactly the same star sample and the same result. It collects a full sample rather
than the bare minimum (see below).

### Two rejected attempts, recorded because both looked reasonable

1. **Widen the candidate pool for every frame.** Costs 6 additional Conservative false
   positives: on healthy frames the extra candidates are dimmer stars that shift the
   eccentricity median.
2. **Rescue, but stop at the 3 measurements needed for a median.** Same 6 false positives
   AND the reported frames still went undetected: 3 stars give a median but no usable
   direction statistics, so TrailingAnalyzer returned trailingScore 0 / consensus 0, the
   elongation rules stayed silent, while the now-non-nil eccentricity unblocked Rule 9's
   cross-check. Half a measurement is worse than none.

### Rule 9 cross-check now requires direction, not amount

With shapes finally measured, four GOOD RC12 narrowband frames were flagged as tracking
hops. Their stars are genuinely elongated (ecc 0.69–0.87) but point every which way
(consensus 0.22–0.49) — that is optics and seeing at 1964 mm, not the mount. The
cross-check accepted raw eccentricity above an FL baseline with no direction requirement.

Raising the trailing amount from 0.15 to 0.5 was tried first and **broke the M82
regression case**, whose confirmed tracking hops carry trailingScore 0.30–0.50 — exactly
the range the good frames occupy. The amount does not separate the two cases; the
direction does:

| | trailingScore | consensus |
|---|---|---|
| M82 confirmed hops | 0.30–0.50 | 0.50 |
| user's confirmed hopped frame | 0.62 | 0.50 |
| four good RC12 frames | 0.24–0.39 | **0.22–0.49** |

So the amount stays at the permissive 0.15 and `consensus >= 0.5` is now required. This
is also the better test on its own terms: what makes a hop is that every star moves the
same way, not how far.

### Impact — GOLDENSET1 (464 frames)

| | v38 | v39 |
|---|---|---|
| Conservative false positives | 4 | **4** |
| A dark / cloud / trail / defocus | 63 / 54 / 23 / 5 | **63 / 54 / 23 / 5** |
| A total | 145 | **145** |
| false alarms, all tiers | 18 | 24 |

Prio A is untouched and Conservative is unchanged. The 6 additional soft-tier flags carry
no defect reason at all — they are pure z-score movement, caused by frames that previously
contributed *nothing* to the group statistics now contributing real eccentricity values.

ScoringRegression (9) + ScoringValidation (53) + TrailingConsensus (7) green.

---

## Version 38 — Elongation is a defect, not a ranking; narrowband star floor (2026-09-07)

**Live report: four RC12 frames with clearly visible elongation carried no elongation
reason, and one frame with 2257 real stars was flagged "zero/near-zero stars".**

### Elongation was gated behind a relative outlier test

All four elongation rules (4, 5, 6, 6a) started with

```swift
let isTrailingOutlier = (trailingZscores[localIdx] ?? 99) > 1.0
```

so a frame could only be found elongated if it was trailed MORE than its own group. A
mount problem affects a whole night — the median is then trailed too, nobody stands out,
and nothing is detected. The reported frame measured trailingScore 0.805, consensus 0.91,
eccentricity 0.72 — unambiguous systematic tracking error — with trailingZ **-2.07**:
badly trailed, but less so than its neighbours.

Rule 6a is documented as *"Absolute trailing ceiling — severe trailing is garbage
regardless of filter"* and the guard made it not absolute at all.

**Fix:** Rule 6a no longer checks `isTrailingOutlier`. Its two conditions are already
group-independent: a high trailing score means elongated stars, and high directional
consensus means they are elongated the SAME way — that is mount motion. Optical
aberration produces random position angles and fails the consensus test, which is what
continues to protect fast optics. Rules 4/5/6 keep the guard; 6a alone covers the
absolute case.

Measured on the live session: frames with trailingScore > 0.6 AND consensus > 0.5 that
carried NO elongation reason — Ha 17, SII 22 — are now all detected. Elongation reasons
Ha 22 → 39, SII 19 → 41.

### Narrowband star floor (Rule 1c)

A frame with 2257 real stars was called "zero/near-zero stars". Rule 1(c) flags below 15%
of the group P90, and the P90 was inflated by hot-pixel frames: in that night 9 of 18
frames report over 10000 "stars" while genuine frames sit near 3300, putting the bar at
2550. Rule 1(b) already relaxes its factor for narrowband (0.15 vs 0.25 broadband) because
the target is nebulosity and stars are incidental; 1(c) used a flat 0.15 regardless of
filter. Now filter-aware in the same way (narrowband 0.09).

Live: false "zero stars" Ha 25 → 16, SII 24 → 21.

### Impact — GOLDENSET1 (464 frames)

| | v37 | v38 |
|---|---|---|
| false alarms | 15 | **15** |
| Conservative false positives | 4 | **4** |
| catch | 154 | **161** |
| A dark | 63/63 | 63/63 |

No good frame is affected either way; the gain is pure catch. ScoringRegression (9) +
ScoringValidation (53) + TrailingConsensus (7) green.

---

## Version 37 — Background MAD floored so a stable night cannot collapse the denominator (2026-09-07)

**Reported from a live session: a good RC12 Ha frame was flagged "abnormal background
(clouds/gradient)" although its background sat 0.1 MAD BELOW its own group median.**

Rule 8 measures how far a frame's background deviates from its group, in MADs. On a
stable night that denominator can collapse: in the reported night **12 of 19 frames
reported an identical background level**, so the group MAD went to zero. The offending
frame sat 0.0005 above the median — **3 ADU out of 65535, physically nothing** — and
divided by ~0 that read as tens of MADs.

Same class as v34 and v35: a relative measure with no floor under the denominator. The
main z-score path (`zscores()`) has floored every metric for a long time via
`practicalMADFloor`; Rule 8 computes its own MAD via `medianAbsoluteDeviation` and
divides directly, so it bypassed that protection. It was the only such bypass — an audit
of every division by a spread measure found `MosaicGenerator` already guards with a floor,
the SNR computations are ratios rather than z-scores, and `QualityEstimator+Historical`
is informational only (it never changes a tier).

**Fix:** `bgMAD` is floored at 2% of the group's own background level — scale-free, so it
follows sky brightness, filter and exposure instead of fixing a number. Genuine outliers
stay obvious: in that same night a frame at 9× the median background still measures 412
MADs and is still caught.

**Impact:** exactly neutral on GOLDENSET1 (15 false alarms / 154 caught, unchanged). On
the reported live session the frame is released while the real outlier of the same night
is retained; "abnormal background" on that Ha group drops 29 → 27.

---

## Version 36 — Dark-detection scatter ceiling lowered to fit narrowband data (2026-09-06)

**Live-test regression report. On a real 833-frame RC12 session, 92 of 244 perfectly
good SII frames were marked "noise peaks, not real stars (dome/cap)" — including
frames with visible star trailing, which are obviously not dome-closed.**

**Root cause — the same mistake this rule set out to fix, reintroduced while fixing
it.** `darkFrameMADCeiling` shipped in v33 as an absolute 0.0002, calibrated on three
setups where dark frames sat at 0.000068 against a good-frame median of 0.000396 — a
factor of six, so a value in between looked safe. It does not generalise. On RC12
narrowband at 180s the entire distribution is an octave lower:

```
RC12 SII 180s, 244 frames:  min 0.000068  p10 0.000113  MEDIAN 0.000204  p90 0.000590
darkFrameMADCeiling = 0.000200   ->  lands exactly on the group median, 45% below it
```

The reported frames measured 0.000181 and 0.000157 — ordinary values for narrowband at
long focal length, where the background is simply smoother. Their high star counts
(16k–20k) are real sensor artefacts (hot pixels), which is what pushed them past the
`stars >= 10000` branch.

**Fix:** ceiling 0.0002 → **0.0001** (≈6.5 ADU of 65535). This sits in the gap between
the darks (0.000068) and the lowest good frame measured anywhere (0.000114).

| | GOLDENSET1 | live RC12 SII |
|---|---|---|
| dark frames caught | 63/63 → **63/63** | 1 genuine dark still caught |
| good frames touched | 0/206 → **0/206** | 92 → **0** |
| false alarms / catch | 15 / 154 → **15 / 154** | — |

Every per-label figure on GOLDENSET1 is identical to v35: the change is neutral on the
calibration set and resolves the live regression entirely.

### A group-relative version was tried and rejected

`MAD < 0.33 x group median` is the obviously more principled formulation and it fails
exactly where it matters most. Per case the discriminator was perfect — all darks below
the ceiling, no good frame below it, in every one of 17 cases. But the two-pass night
grouping can produce a group that is almost entirely darks (one night in the calibration
set is 62 of 64), and there the reference level IS the dark level, so the test measures
against itself and collapses: 24 darks lost their garbage reason and false alarms went
15 → 56.

Worth recording because a threshold sweep on raw metrics *predicted zero false alarms*
for that factor. It checks separation, not what the group statistics do afterwards. Only
the end-to-end measurement is decisive.

### Known risk, deliberately accepted

This remains an ABSOLUTE photometric threshold and can be wrong again for a sensor or
exposure regime quieter than anything measured so far. Both failed approaches point the
same way: the reference frame must not come from the data being judged. The durable fix
is the per-setup learned corridor (`CalibrationDatabase`, which today only promotes).

ScoringRegression (9) + ScoringValidation (53) + TrailingConsensus (7) green.

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
