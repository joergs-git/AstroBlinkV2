# AstroScoreCLI — headless scoring / tuning driver

A non-sandboxed command-line tool that runs the **exact same** decode → measure → score
pipeline as the app (via the shared `ScoringRunner`), but can read **any** NAS/Desktop folder
and score it with a **JSON-configurable** threshold set — no recompile. Built for batch tuning
and golden-set regression / ML calibration of the auto-mark pipeline.

## Build

```
xcodegen generate
xcodebuild build -project AstroTriage.xcodeproj -scheme AstroScoreCLI \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/dd-cli CODE_SIGNING_ALLOWED=NO
codesign --force --sign - build/dd-cli/Build/Products/Debug/AstroScoreCLI   # ad-hoc, for local Metal
```

The compiled `default.metallib` sits next to the binary and is loaded automatically.

## Usage

```
AstroScoreCLI --data-root <folder> [--csv <out.csv>] [--config <config.json>] [--report]
AstroScoreCLI --dump-config          # print the default threshold JSON (template for --config)
```

- `--data-root` — either a **golden-set root** (`<CASE>/good` + `<CASE>/PRE-DELETE` subfolders)
  or a **flat folder** of frames (scored as one unlabeled case). Each case is scored as its own
  group via `QualityEstimator.computeScores`, exactly as in-app.
- `--csv` — per-frame results (tier, combinedZ, FWHM, HFR, stars, ecc, trailing, SNR, z-scores,
  garbage reasons, recommendation).
- `--config` — **partial** JSON override: set only the knobs you want to tune; the rest stay at
  their defaults. Missing file keys never change behavior.
- `--report` — agreement report (human label vs assigned tier: catch rate / false-alarm rate).

## Golden-set layout

```
<root>/<CASE>/good/          ≥6 GOOD frames of ONE GroupKey (filter+target+exposure+FL+sensor)
<root>/<CASE>/PRE-DELETE/    BAD frames of the same GroupKey
```
`ASTRO_TEST_DATA_ROOT` is honored by the in-app `GoldenMiniSetTests` for the same layout.

## Tunable knobs (Phase 0)

`--dump-config` emits the current defaults (all reproduce today's scoring exactly):

| key | default | meaning |
|---|---|---|
| `thresholdExcellent` | 0.5 | combinedZ above → excellent |
| `thresholdGood` | -0.5 | combinedZ above → good (the good/borderline knife-edge) |
| `thresholdBorderline` | -2.0 | combinedZ above → borderline, else trash |
| `zscoreCap` | 3.0 | per-metric z clamp |
| `garbageDropFactor` | 0.5 | Stage-1 relative garbage cut (× group median) |
| `absoluteTrailingCeilingScore` | 0.6 | Rule 6a absolute trailing-garbage ceiling |
| `absoluteTrailingCeilingConsensus` | 0.5 | consensus gate for Rule 6a |

Measurement-side constants (StarMetrics apertures, HFR/FWHM px bounds) and the filter-trailing
multipliers are **not** externalized yet — a later increment.

## Example: probe the good/borderline knife-edge

```
echo '{ "thresholdGood": -0.7 }' > tune.json
AstroScoreCLI --data-root "/path/to/session" --config tune.json --csv tuned.csv --report
```
Widening the good band (−0.5 → −0.7) rescues frames that sit just below the cutoff — the
mechanism behind "two near-identical frames, opposite verdict". Validate any change against a
curated golden set before adopting it in-app.
