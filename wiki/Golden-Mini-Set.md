# Golden Mini-Set — image-based regression gate

A curated ~9 GB / 6-case image set that replaces the full ~331 GB `QUALITYCHECKDATA`
corpus as the day-to-day image-pipeline regression gate (~60 s vs ~5 min).

It validates the end-to-end **measurement** pipeline on real pixels
(`ImageDecoder` → `StarMetricsCalculator` → `TrailingAnalyzer` →
`QualityEstimator.computeScores`). It is complementary to — not a replacement for —
the synthetic `ScoringRegressionTests` / `ScoringValidationTests`, which use
hardcoded metric values (no images) and remain the always-on scoring-logic gates.

## Layout & resolution

- `TestImages/QUALITYCHECKMINI/<CASE>/{good,PRE-DELETE}/` — one folder per case.
  This data is **gitignored** (lives on the dev machine, optionally an external
  archive); contributors without it get clean skips.
- Each case holds **≥6 frames of ONE `GroupKey`** (filter + target + exposure +
  focal length + sensor). `QualityEstimator.computeScores` only scores a group with
  `≥ minGroupSize (6)` frames sharing one key, so mixing filters/exposures in a case
  silently splits it into sub-6 groups that never get scored.
- `Tests/GoldenMiniSetTests.swift` — the gate. Data-root resolution precedence:
  `ASTRO_TEST_DATA_ROOT` env → `QUALITYCHECKMINI` → `QUALITYCHECKDATA` → `XCTSkip`.
  The gate runs only against `QUALITYCHECKMINI`; absent data → clean skip (CI stays green).
- `scripts/build_mini_set.py` — reproducible curation (auto-copies the already-labeled
  cases with a single GroupKey; documents the measurement-picked cases).

## What the gate asserts (per case)

**Hard (fails the build):**

- **Good-side floor** — `median(good-frame quality rank) ≥ Good`.
- **Measured-metric separation**, selected by the defect token in the case id:
  - `trails` / `badstars` / `hop` — bad trailing median `>` good `+ 0.10`.
  - `twilight` / `gradient` / `dawn` — each bad frame carries a Stage-1 garbage reason
    **and** bad background median `> 3×` good.
  - `lowsnr` / `cloud` — bad SNR median `< 0.65×` good.
  - `wind` / `fwhm` / `defocus` — bad FWHM median `> 1.3×` good.
  - `dark` / `dome` — each bad frame carries a Stage-1 garbage reason.

**Soft (informational, NOT a gate):** the tier caught-fraction (reference ≥ 60 %).
Relative tier-scoring needs the full-corpus session-sanity context that a small
isolated group can't reproduce — that's what the synthetic tests cover. The
**measured separation** is the real gate; it is exactly what catches a repeat of the
v6.4.2 trailing-measurement bug (where severe trails were mis-measured as round).

## Cases (6) — coverage matrix

| Case | Source | Dimensions |
|---|---|---|
| `short_osc_asiair_galaxy_trails` | M101 60 s Extr | short FL · OSC · ASIAIR · galaxy · star trails |
| `short_osc_asiair_galaxy_twilight` | M101 120 s Extr | short FL · OSC · ASIAIR · twilight + strong gradient |
| `long_mono_nina_nb_trackinghop` | M82 + M82-January | long FL · mono · NINA · narrowband · tracking hops |
| `medium_mono_asiair_galaxy_badstars` | M81 | medium FL · mono · ASIAIR · galaxy · bad star form |
| `fast_osc_nina_nb_baseline` | NGC7635 | fast FL · OSC · NINA · narrowband · good-only baseline |
| `medium_mono_asiair_nb_baseline` | ngc7000 | medium FL · mono · ASIAIR · narrowband · good-only baseline |

Covers: short / medium / long / fast focal length · OSC + monochrome · NINA (`.xisf`)
+ ASIAIR (`.fit`) · galaxy + narrowband nebula · trails at short and long FL ·
twilight · strong gradient · satellite-safe trail detection.

## Curation rules (when adding or regenerating cases)

- **One GroupKey per case.** Never mix filters or exposures.
- **Bad frames must have a physically-measurable defect.** Frames a human rejected
  for reasons invisible to the metrics (transparency, framing — the "blind curation"
  limitation) are **not** valid bad cases; keep them as good-only baselines (this is
  why ngc7000 / NGC7635 PRE-DELETE frames became baselines).
- **Star-trail bad picks must be satellite-safe:** require high trailing score **and**
  high orientation consensus. A lone satellite streak produces low consensus → trailing
  score 0 → it is correctly excluded.
- **Pick by the real pipeline, not by eye.** Use a one-shot measurement dump
  (decode → measure → analyze) and select on the resulting metrics, so the picked
  frames match what the gate re-measures. Small auto-stretched thumbnails are not
  reliable for judging star roundness.

## Deferred dimensions (harness skips until data exists)

- **dark / dome / cap** — no dark / dome / flat frames exist in the corpus.
- **wind / FWHM-pure** (round but bloated stars on a dark sky) — every high-FWHM frame
  currently on hand is either trailing (already the M81 case) or dawn-contaminated
  (the twilight case); a clean isolated case needs a windy-but-clear-night set.

Both can be added later with the same measurement-pick approach; no change to the gate
is required (it auto-discovers any populated `<CASE>/` and skips absent ones).
