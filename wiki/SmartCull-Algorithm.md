# SmartCull — Multi-Stage Quality Engine

SmartCull is a 5-stage pipeline that automatically scores every sub-exposure relative to its group (same target + filter + exposure + observing night). Validated on 1,638 frames across 7 setups, 4 telescopes, mono+OSC, narrowband+broadband.

**"1,638 frames. 14 decisions."** — SmartCull handles 99% of quality decisions automatically.

## How It Works

### Stage 1 — Garbage Detection (15 Rules)

Absolute thresholds catch catastrophic failures immediately. Any single metric failing = immediate trash (red icon). Multiple reasons are shown when more than one rule triggers.

- **R0: No signal** — zero stars AND no noise data detected
- **R0b: Dark frame / dome closed** — stars ≥ 10,000 (hot pixel false detections), or stars ≥ FL-scaled threshold + background < 0.002
- **R1: Zero/near-zero stars** — star count < 15% (narrowband) / 25% (broadband) of group median
- **R1b: Decentered target** — plate-solved position offset > 30% of FOV (requires CRVAL1/CRVAL2)
- **R2: SNR catastrophically low** — SNR < 50% of group median
- **R3: Severe defocus** — FWHM > 2x group median
- **R4: Severe HFR** — HFR > 2x group median
- **R5: Extreme eccentricity** — eccentricity excess > 1.0/effectiveTrailMult above FL-adaptive baseline (requires trailing outlier guard + FWHM cross-check)
- **R6: Star trailing** — trailing score > 0.7/effectiveTrailMult (dual-path: also fires at > 0.5/mult with consensus > 0.8). Cross-checked with FWHM and trailing outlier guard.
- **R6a: Absolute trailing ceiling** — trailing score > 0.50 + consensus > 0.50 + trailing outlier. Filter-independent, bypasses FWHM cross-check (tracking error produces normal FWHM).
- **R7: Star count anomaly** — stars > 1.8x median + elevated FWHM/HFR (doubled stars from tracking jump)
- **R7b: Atmospheric attenuation** — stars < 65% median + SNR < 65% median + FWHM normal. Detects thin cloud, dew, or fog (signal loss without defocus). Requires ≥8 frames.
- **R8: Background anomaly** — background > 5-6.5 MAD from group median (clouds, fog, gradient). Moon-aware for broadband (relaxes threshold near bright moon).
- **R9: Tracking hops** — star chain fraction > 25% (tracking jump during exposure)
- **R10: Twilight/daylight** — sun altitude > -12° for broadband; narrowband tolerates down to -6° (civil twilight)

### Stage 1.5 — Session-Wide Sanity Check

Cross-group comparison using P10/P90 benchmarks. Pools frames by object+exposure (ignoring filter/night) and compares each frame against the session's best decile. If 2+ metrics are dramatically worse than the best 10%, the frame is demoted to trash. A severe single-metric outlier (e.g. FWHM >1.4x P10) plus one more flag also triggers demotion. Requires at least 2 distinct observing nights and ≥6 frames in the pool to activate. FWHM threshold is target-type-aware (emission nebulae get 1.6x multiplier, IFN gets 1.8x, default 1.3x).

### Stage 2 — Relative Z-Score Ranking

Frames that pass Stage 1 are ranked within their group using robust statistics:

- **Statistics:** Median/MAD (outlier-resistant, not mean/stdev)
- **Metrics weighted:**
  - PSF Flux / Stars: 1.2x broadband / 0.5x narrowband — PSF flux replaces star count when available (captures both count AND brightness, immune to hot pixel inflation). Falls back to star count when GPU PSF fitting unavailable
  - FWHM: 1.0x (GPU-fitted via circular Gaussian, CPU fallback when GPU chi² too high)
  - HFR: 1.0x (fallback only when FWHM unavailable)
  - Noise: 1.0x
  - Trailing: filter-aware (0.3× narrowband, 0.6× RGB, 1.0× luminance, 0.7× unknown). Severity-dependent escalation: `baseMult + (1-baseMult) × trailingScore²` — mild narrowband trailing stays lenient, severe trailing approaches full luminance penalty.
- **Eccentricity:** Derived from elliptical PSF fit (σx/σy) when available, image moments as fallback
- **Target-aware weights (v5.14.0):** Metric weights adjust by deep-sky object type. Galaxies: FWHM 1.4×, trailing 1.2× (resolution-critical). Emission nebulae: noise 1.4×, FWHM 0.7×. IFN: noise 2.0×, FWHM 0.4×. Clusters: stars 0.2-0.3×. FOV fill ratio modulation: small target boosts FWHM +20%, target fills frame boosts noise +20%.
- **MAD floor (v5.14.0):** Prevents z-score amplification in tight sessions. FWHM floor scales with focal length (0.20-0.80px). Stars: 10% of median. Noise: 0.0008. Trailing: 0.04.
- **Z-scores capped at ±3.0** to prevent one extreme value from dominating
- **Minimum group size: 6 frames** (median/MAD needs ≥6 samples)

**Tier thresholds:**
- Excellent: z > 0.5 (green full circle)
- Good: z > -0.5 (green half circle)
- Uncertain: small group (<8 frames) with ambiguous z-score (-1.0 to 0.5) — blue question mark
- Borderline: z > -2.0 (orange — 4 sub-levels from light to deep)
- Trash: z ≤ -2.0 (red X)

### Stage 3 — Rescue Rules

Pattern-based rules rescue frames that z-scores unfairly penalize:

- **Rule A:** Good FWHM + acceptable noise → rescued to Good (even if star count dipped)
- **Rule B:** Star count dip + sharp stars → recognized as transient event (clouds, dew), not quality issue
- **Rule C:** FWHM-only penalty → promoted to Borderline with lower SSWEIGHT (softer seeing still adds signal)

### Stage 4 — Sanity Check

Z-score trash with FWHM actually in the Good range → promoted to Borderline. Catches the rare case where overall z-score dips below threshold but stars are perfectly sharp.

## Adaptive Thresholds

- **Focal-length-adaptive trailing:** baseline_ecc = 0.8 / sqrt(focalLength / 200). Short FL tolerates more aberration.
- **Filter-aware trailing penalty:** Narrowband (Ha/OIII/SII) × 0.3 — slight trailing barely affects diffuse emission. RGB × 0.6. Luminance × 1.0 (full strictness — the sharpness channel). Unknown filters × 0.7. Garbage thresholds, z-score weights, rescue rules, and SSWEIGHT penalty all scale with this multiplier.
- **Background anomaly scales with group size:** 10 frames → 6.5 MAD, 20+ frames → 5.0 MAD
- **Narrowband star weight:** reduced to 0.5x because narrowband inherently detects fewer stars

## Orientation Consensus (Industry First)

When a mount has tracking errors, ALL stars trail in the SAME direction. SmartCull uses circular statistics to detect this:

- Measures position angle (PA) of each star's elongation via 2D image moments
- Computes orientation consensus: fraction of stars agreeing on direction
- >50% consensus = systematic tracking error (penalize heavily)
- Random PAs = normal optical aberration (don't penalize)

## Self-Calibration

After 30+ frames with the same setup (telescope + camera + focal length):
- An absolute quality floor activates
- Frames meeting the learned baseline are locked as KEEP (blue lock icon)
- Z-scores cannot override locked frames
- Prevents the "death spiral" where repeated culling removes good frames

**Community Floor (Cold Start):** When local calibration has fewer than 30 frames, a community baseline is used instead. Frames meeting the community floor are promoted to Good with a gray lock badge (weaker than the blue local calibration lock).

## Quality Reasoning ("Why?")

Hover any quality icon to see:
- Per-metric z-scores (Stars, FWHM, HFR, Noise, Trailing)
- SNR contribution percentage
- Human-readable explanation ("FWHM worst in group", "Star count dip — likely transient")
- KEEP/DELETE recommendation with reasoning

## Culling Autopilot

Click the auto-mark button (wand icon) in the toolbar for one-click auto-marking:
- **Conservative:** Only Stage 1 garbage
- **Balanced:** + severe borderline (severity ≥ 2)
- **Aggressive:** + all borderline frames

Each mode shows the frame count and integration impact before applying.

### Convergence Guard (v5.10.0)
The autopilot warns before marking when further culling has diminishing returns:
- Quality spread already tight (< 0.3) — remaining frames are very similar in quality
- SNR loss would exceed integration loss — you'd lose more signal than you gain in quality
- A confirmation dialog explains the trade-off. Conservative mode is never guarded (trash is always trash).

### Session Spread Stats
The Auto-Mark popover includes a collapsible "Session Spread" section showing:
- Per-metric distribution (FWHM, Stars, Noise, Trailing) with min/max range and z-score spread
- Tight/normal/wide labels per metric
- Overall quality spread percentage with color-coded readiness bar
