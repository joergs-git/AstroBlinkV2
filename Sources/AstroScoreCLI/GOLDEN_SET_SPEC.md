# Golden-Set Curation Spec (Phase 1)

The calibration ground truth for tuning the auto-mark pipeline. `AstroScoreCLI` scores this set
with the default config and reports agreement (catch rate / false-alarm rate); Phase 2 changes
are accepted only if they improve agreement here **without** regressing any case.

Point the CLI at it with `--data-root <root>` (or the env var `ASTRO_TEST_DATA_ROOT`).

---

## 1. Folder layout (exact)

```
<root>/<CASE>/good/          representative GOOD frames (KEEP)
<root>/<CASE>/PRE-DELETE/    representative BAD frames  (would-delete)   [omit for a good-only baseline]
```

- Put `<root>` on the Desktop or a NAS path — the CLI is not sandboxed and reads it directly.
- Keep **original NINA filenames** (the parser needs `Light_<target>_<exp>s_..._<FILTER>_...`).
- Formats: `.fit` / `.fits` / `.fts` / `.xisf`.

## 2. The iron rule — ONE GroupKey per case

A case must hold frames of a **single** GroupKey: same **filter + target + exposure + focal
length + sensor**. Mixing splits the group, and groups under 6 frames are never scored.

- **good/**: **≥ 12** frames (more = more stable group median → trustworthy relative scoring).
- **PRE-DELETE/**: **≥ 6** frames (or omit the folder for a good-only baseline case).
- good and bad in one case MUST be the same GroupKey (the bad frames are scored *against* the
  good ones). A trailed 300s Ha frame does not belong in a 120s L case.

## 3. Defect matrix — only PHYSICALLY-MEASURABLE defects

The metrics can see: FWHM, HFR, star count, eccentricity, trailing (PA consensus), background
level, SNR. A BAD frame must fail on one of these. **Do NOT** put frames rejected for reasons
invisible to the metrics (poor transparency, bad framing/centering-by-eye, "just didn't like
it") into PRE-DELETE — those are blind-curation and will look like false alarms. Keep such
sessions as **good-only baselines** instead.

Name each case folder with a defect token so the gate knows what to assert:

| Token in case name | Defect | Who curates | Required signal |
|---|---|---|---|
| `...trail...` | star trailing (tracking) | **you** (visible streaks) | high trailingScore **and** high consensus (satellite-safe) |
| `...hop...` | tracking hop / jump | you or measurement | elevated star-chain fraction + elongation |
| `...defocus...` / `...fwhm...` | out-of-focus / bloated PSF | you (obvious) or measurement | FWHM ≥ 1.3× the good median |
| `...wind...` | wind-shake (round but bloated) | measurement | high FWHM, dark sky |
| `...badstar...` | bad star shape (astig/coma burst) | measurement | eccentricity / trailing outlier |
| `...lowsnr...` | thin cloud / low signal | you (visible haze) | SNR < 0.65× good median |
| `...cloud...` | passing/closed cloud | **you** (obvious) | low SNR **or** raised background |
| `...gradient...` / `...twilight...` / `...dawn...` | sky gradient / twilight / dawn | **you** (obvious bright/washed sky) | background ≥ 3× good median + a Stage-1 garbage reason |
| `...dark...` / `...dome...` / `...cap...` | dark / dome flat / cap-on | you (blank/no stars) | a Stage-1 garbage reason (no real signal) |

`good`, `baseline`, `clean` → good-only cases (assert only that good scores as Good/Excellent).

## 4. Two curation modes

- **Human-labeled** (defects the eye sees reliably at large scale — clouds, gradients, twilight/
  dawn, gross trailing, obvious defocus, dark/dome): you sort frames into good/ and PRE-DELETE/.
- **Measurement-assisted** (defects the eye can't judge — subtle FWHM/wind, marginal SNR, star-
  shape/count anomalies): drop a WHOLE session into one folder, tell me the defect token, and I
  run the CLI to propose the good/bad split by the real pipeline; you confirm. This avoids
  "picking by eye on thumbnails" mismatching what the gate re-measures.

## 5. Coverage — span BOTH scopes

The whole point is per-scope robustness (a threshold right for one scope is wrong for another).
Aim to cover each defect on **at least two very different setups**, especially:

- **Short-FL fast OSC** (e.g. 468 mm f/5.5, ASI2600MC, 3.76 µm ≈ 1.66"/px) — naturally higher
  ecc (~0.5–0.6), rich star fields.
- **Long-FL mono** (e.g. RC12 2423 mm, ~0.32"/px) — tight PSF, low ecc (~0.23), sparse fields.

Plus, if available: a **narrowband** case and a **broadband/L** case per scope (filter-aware
paths differ). Include **dark/dome** frames if you have them (currently missing from the corpus).

## 6. Target size

~8–12 cases total: the defect matrix above across the two scopes, plus 2–3 good-only baselines
(one per scope/filter) to pin down the false-alarm rate on genuinely clean nights. ~10–20 GB is
plenty. Quality and correct labeling matter far more than volume.

## 7. Do / Don't

- DO keep good and bad in the SAME GroupKey per case.
- DO pick trailing-bad frames that are satellite-safe (high consensus, not a lone streak).
- DON'T mix filters/exposures/targets in one case.
- DON'T put blind-curation rejects (transparency/framing) in PRE-DELETE — baseline them.
- DON'T hand-pick star-size defects by eye — hand me the session, I measurement-pick.

---

## 8. Concrete case checklist (tailored: 468mm OSC + RC12 mono + more)

Case naming: `<scope>_<filter>_<target>_<token>` (e.g. `osc468_L_ic1318_baseline`,
`rc12_Ha_m82_trail`). Pick a REAL session for each row. Curator column: **you** = sort by eye;
**measure** = hand me the whole session, I propose the good/bad split via the CLI, you confirm.

| # | Prio | Case | Scope | good | bad | Curator | Notes |
|---|---|---|---|---|---|---|---|
| 1 | P1 | `osc468_L_*_baseline` | 468 OSC | ≥12 | – | you | clean L night (e.g. the IC 1318 set). Pins false-alarm rate + holds the 0045/0047 pair. |
| 2 | P1 | `rc12_<filt>_*_baseline` | RC12 mono | ≥12 | – | you | clean mono night (L or NB). The long-FL counterpart. |
| 3 | P1 | `osc468_L_*_cloud` | 468 OSC | ≥12 | ≥6 | you | good = clear frames, bad = visibly cloudy/hazy frames, SAME night+filter+exposure. |
| 4 | P1 | `rc12_<filt>_*_cloud` | RC12 mono | ≥12 | ≥6 | you | same, mono. Tests the raw sky-ADU/SNR thresholds across plate scale. |
| 5 | P1 | `osc468_<filt>_*_gradient` | 468 OSC | ≥12 | ≥6 | you | bad = twilight/dawn/strong-gradient frames (bright washed sky). |
| 6 | P1 | `osc468_L_*_trail` | 468 OSC | ≥12 | ≥6 | you | bad = visible star streaks, satellite-safe (whole frame trailed, not one dot). |
| 7 | P1 | `rc12_<filt>_*_trail` | RC12 mono | ≥12 | ≥6 | you | trailing on the tight-PSF scope (different ecc baseline). |
| 8 | P2 | `osc468_L_*_fwhm` | 468 OSC | ≥12 | ≥6 | measure | subtle defocus/wind — hand me the session, I split. |
| 9 | P2 | `rc12_<filt>_*_fwhm` | RC12 mono | ≥12 | ≥6 | measure | same, mono. |
| 10 | P2 | `<scope3>_<filt>_*_baseline` | 3rd scope | ≥12 | – | you | a third setup (RASA/85mm/…) good-only — extra scope diversity. |
| 11 | P2 | `<scope3>_<filt>_*_<defect>` | 3rd scope | ≥12 | ≥6 | you/measure | any clear defect on the third scope. |
| 12 | P3 | `<scope>_*_dark` / `_dome` | any | ≥12 | ≥6 | you | ONLY if dark/dome/cap frames available (currently missing from corpus). |

**Minimum viable first pass:** rows 1–7 (both scopes: baseline + cloud + gradient + trail).
That already exercises the knife-edge (Problem 1) and the raw photometric thresholds (Problem 2)
on two very different plate scales. Rows 8–12 deepen it.

## 9. Hand-off workflow

1. Create a root folder on the Desktop, e.g. `~/Desktop/GOLDENSET/`.
2. **You-curated cases:** make `<CASE>/good/` + `<CASE>/PRE-DELETE/`, drop the frames in.
3. **Measure cases:** make `<CASE>/` and drop the WHOLE session in it (flat), tell me the token;
   I run the CLI, propose the good↔PRE-DELETE split, you confirm before it's locked.
4. Tell me the root path. I run `AstroScoreCLI --data-root <root> --report --csv` and we read the
   agreement together; then Phase 2 fixes are tuned against it, each gated on "improves agreement,
   regresses nothing".

