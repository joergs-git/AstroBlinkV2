# SmartCull — Multi-Stage Quality Engine

SmartCull is a 5-stage pipeline that automatically scores every sub-exposure relative to its group (same target + filter + exposure + observing night). Validated on 1,638 frames across 7 setups, 4 telescopes, mono+OSC, narrowband+broadband.

**"1,638 frames. 14 decisions."** — SmartCull handles 99% of quality decisions automatically.

## How It Works

### Stage 1 — Garbage Detection (11 Rules)

Absolute thresholds catch catastrophic failures immediately. Any single metric failing = immediate trash (red icon). Multiple reasons are shown when more than one rule triggers.

- **R0: No signal** — zero stars AND no noise data detected
- **R1: Zero/near-zero stars** — star count < 15-25% of group median
- **R1b: Decentered target** — plate-solved position offset > 30% of FOV (requires CRVAL1/CRVAL2)
- **R2: SNR catastrophically low** — SNR < 50% of group median
- **R3: Severe defocus** — FWHM > 2x group median
- **R4: Severe HFR** — HFR > 2x group median
- **R5: Extreme eccentricity** — eccentricity > 2x focal-length-adaptive baseline
- **R6: Star trailing** — trailing score > 0.7 (cross-checked with FWHM degradation)
- **R7: Star count anomaly** — stars > 1.8x median + elevated FWHM (doubled stars from tracking jump)
- **R8: Background anomaly** — background > 5-6.5 MAD from group median (clouds, fog, gradient). Bortle-aware, moon-aware for broadband.
- **R9: Tracking hops** — star chain fraction > 25% (tracking jump during exposure)
- **R10: Twilight/daylight** — sun altitude > -12° for broadband; narrowband tolerates down to -6° (civil twilight)

### Stage 1.5 — Session-Wide Sanity Check

Cross-group comparison using P10/P90 benchmarks. Pools frames by object+exposure (ignoring filter/night) and compares each frame against the session's best decile. If 2+ metrics are dramatically worse than the best 10%, the frame is demoted to trash. A severe single-metric outlier (e.g. FWHM >1.4x P10) plus one more flag also triggers demotion. Requires at least 2 filter/night combinations in the pool to activate.

### Stage 2 — Relative Z-Score Ranking

Frames that pass Stage 1 are ranked within their group using robust statistics:

- **Statistics:** Median/MAD (outlier-resistant, not mean/stdev)
- **Metrics weighted:**
  - Stars: 1.2x (broadband) / 0.5x (narrowband — fewer stars is normal)
  - FWHM: 1.0x
  - HFR: 1.0x
  - Noise: 1.0x
  - Trailing: filter-aware (0.3× narrowband, 0.6× RGB, 1.0× luminance, 0.7× unknown)
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
