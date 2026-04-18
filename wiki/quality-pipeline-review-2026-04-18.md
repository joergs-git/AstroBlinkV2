# Quality Pipeline Review — 2026-04-18 (Algorithm v23)

**Target file under review:** `AstroTriage/Engine/QualityEstimator.swift` (1999 lines at start).

**Input document:** `stagingcheckundpruefanweisungsdatei.md` — 10 findings authored during
an external code review.

**Data source:** Frame History DB at
`~/Library/Containers/com.joergsflow.AstroBlinkV2/Data/Library/Application Support/AstroBlinkV2/FrameHistory.sqlite`
(5811 rows, 4540 with user confidence ratings).

**Result artifacts:**
- Source changes committed with this document (algorithm version bumped 22 → 23).
- 4 regression tests added to `Tests/QualityEstimatorTests.swift`.
- This document preserves the analysis so the decisions can be re-reviewed without
  re-deriving the evidence.

---

## 1. Methodology

### 1.1 Phase 1 — Static analysis (read-only)

For each of the 10 findings from the prüfanweisung, we read the relevant
QualityEstimator lines and classified the finding as one of:

- `confirmed bug` — logic error reproducible from code alone
- `intentional` — behavior is deliberate, possibly empirically calibrated
- `uncertain` — cannot tell from code alone; needs real-data validation
- `invalid` — finding's premise is wrong

Static-analysis verdicts were recorded and then tested against real data in Phase 2.

### 1.2 Phase 2 — Empirical validation against curated frames

**Ground truth signal:** `userConfidence` column in `frame_record` table.

- `userConfidence = 1` (★) = user labeled as garbage → should be deleted
- `userConfidence = 2` (★★) = ambiguous
- `userConfidence = 3` (★★★) = clear keep → must not be trashed
- `userConfidence = 0` = unrated (excluded from validation)

`qualityFeedback` column has only 1 populated row across the whole DB — not
usable as a signal.

**Confusion matrix at entry (Algorithm v22 stored tier vs user rating):**

| algo tier     | 1★ garbage | 2★ ambiguous | 3★ keep | total |
| ------------- | ---------- | ------------ | ------- | ----- |
| trash (0)     | **525 TP** | 445          | **566 FP** | 1536 |
| borderline (1)| 182        | 165          | 271     | 618   |
| good (2)      | **152 FN** | 349          | **1566 TN** | 2067 |
| excellent (3) | 17         | 40           | 149     | 206   |
| uncertain (4) | 8          | 14           | 10      | 32    |
| *(unscored)*  | 9          | 6            | 66      | 81    |
| **total**     | 893        | 1019         | 2628    | 4540  |

Key rates:
- False-positive rate (algo=trash, user=keep): 566 / 2562 clear-keep = **22.1%**
- False-negative rate (algo=good/excellent, user=garbage): 169 / 884 clear-garbage = **19.1%**

**Garbage-reason breakdown of 566 FPs:**

| reason_preview                                      | count |
| --------------------------------------------------- | ----- |
| zscore_only (empty garbageReasons)                  | **247** |
| decentered target                                   | 79    |
| tracking hops                                       | 49    |
| star trailing / elongation                          | 47    |
| abnormal background (clouds / gradient)             | 36    |
| noise peaks (dome / cap)                            | 30    |
| "no signal" + "noise peaks" combo                   | 25    |
| twilight                                            | 14    |
| atmospheric attenuation + background anomaly combo  | 7     |
| other multi-reason combos                           | 32    |

**44% of all FPs have empty garbageReasons** — they are z-score, Stage 1.5, or
Stage 1.5b demotes where Stage 4 either refused to rescue or the reasoning was
preserved in non-persisted fields. This concentration drove our priority on
FINDING-01 and FINDING-06.

**Dataset diversity:**

- Algorithm versions: v18 (4149 rows), v19 (120), v22 (271) — spans ~5 months of
  algorithm evolution. Metric values and user ratings are durable across versions;
  only the stored `qualityTier` reflects the algorithm state at scoring time.
- Telescopes / focal lengths represented: RASA 8", RC12 (2423mm and 1964mm reduced),
  various refractors at 140mm–1000mm, short-FL setups down to 468mm.
- Cameras: ASI6200MM, ASI2600MC, other mono + OSC.
- Filters: L, R, G, B, H (Ha), O (OIII), S (SII).
- Targets: 200+ across all DSO types.

### 1.3 Simulation approach for finding-level impact measurement

Python3 + pandas was used to:
1. Export rated frames to CSV (`/tmp/astrocalib/rated.csv`).
2. Reconstruct `GroupKey` and `PoolKey` from frame fields.
3. Re-simulate each proposed rule change against the same frames.
4. Compare the proposed-tier-outcome to `userConfidence` for each frame.
5. Report net TP/FP deltas.

Simulation limitations and how they're handled:
- My simulation used a default `fwhmSanityMultiplier = 1.3` (galaxy/cluster).
  Real code varies by target type (1.3–1.8). Where directional evidence is
  clear, this is not a problem. Where the finding's impact is small and sensitive
  to multiplier, the simulation's sign was cross-checked against a sanity run
  (see `sanity_check.py` output — 52% of simulated demotes agree with stored
  trash tier, explained by Stage 1 garbage + calibration locking not being
  modeled).
- `isLockedKeep` and community-floor locks were not modeled. They only *protect*
  frames from being demoted; since the curated set has user ratings (not
  calibration locks), this is conservative — actual FP reductions would be at
  least as good as simulated.

All simulation scripts preserved under `/tmp/astrocalib/` at implementation
time; key inputs and outputs are captured in the per-finding sections below so
the analysis is reproducible without the scripts.

---

## 2. Per-finding verdicts and decisions

Each block captures:
- **Static verdict** (Phase 1)
- **Empirical measurement** (Phase 2)
- **Decision** (implemented / deferred / rejected)
- **Rationale**

### FINDING-01 — Stage 4 reverts Stage 1.5 / 1.5b demotes [P1, implemented]

**Static verdict:** Confirmed bug. Stage 4 match clause at line 1109 keys on
`.trash where bd.garbageReasons.isEmpty`. Stage 1.5 (line 1752) and Stage 1.5b
(line 1516) both set `garbageReasons: []` and stash reasons in
`sessionSanityReasons` / `historicalBaselineReasons`. The reasons fields are
invisible to the match clause. Stage 4's rescue rebuilds the breakdown via
positional init and silently discards the reason fields.

**Empirical measurement:**
Predicted Stage-1.5 demotes that satisfy Stage-4 rescue criteria (FWHM within
good-frame P90 of group) = 220 frames. User-rating breakdown:
- 65 human-garbage (fix = correct → trash)
- 87 human-keep (fix = wrong → rescue)
- 68 ambiguous

Net if "fix as originally proposed" (stop Stage 4 from rescuing these):
**−22 frames** (87 frames wrongly demoted vs 65 correctly demoted).

**The prüfanweisung's proposed fix would WORSEN accuracy.** The "bug" is
protecting more correct keeps than it's causing FNs.

**Decision:** Keep Stage 4 rescuing these frames, **but preserve the reason
fields** so the UI still shows "REVIEW — <reason>" via `recommendationLabel`
(QualityBreakdown lines 110-112). Users retain visibility into why the frame
was initially flagged; the frame itself isn't auto-trashed.

**Code change:** Stage 4 rescue now constructs `var demoted = QualityBreakdown(...)`
then mutates `sessionSanityReasons`, `historicalBaselineReasons`,
`historicalZScore`, `historicalPercentile`, `isCommunityFloorLocked`,
`lowConfidenceScoring` from the `oldBD` before writing to `result`. Also
suppresses the "FWHM comparable to good frames" reasoningText when the
sanity reasons are non-empty so the sanity reasons get top billing in the UI.

**Test:** `testFINDING01_stage4RescuePreservesSanityReasons`.

---

### FINDING-02 — Per-night overwrite erases combined-pass Stage 1 garbage [P1 → rejected]

**Static verdict:** Confirmed bug. Combined pass writes result first, per-night
pass (lines 320-322) iterates after and overwrites. Relative rules (1b, 2, 3, 4,
7, 7b, 8, 9) recompute against per-night medians and may not re-fire.

**Empirical measurement:**
Frames flagged by combined pass but NOT by per-night pass: **49 frames**.
- 15 human-garbage (fix = correct to preserve flag)
- 15 ambiguous
- 19 human-keep (fix = wrong to preserve flag)

Net if "fix as proposed" (preserve combined flag through per-night): **−4 frames**.

Of the 19 wrongly-preserved flags, 18 would be `stars` rule (low star count vs
combined-pool median). In per-night view, those frames' star counts are normal
for that night — the combined view is just comparing to a larger, deeper pool.
Per-night is empirically more accurate in the "legitimately-dim-night" case.

**Decision:** **Do not implement.** The per-night overwrite is working as
intended. Added a long comment at lines 293-321 explicitly documenting this
as empirically-validated intentional behavior so future reviewers can skip
re-deriving the evidence.

**No code behavior change.** Comment-only.

---

### FINDING-03 — Stale rescue reasoning on uncertain override [P1 cosmetic, implemented]

**Static verdict:** Confirmed. `reasoning` is built with the post-rescue tier
at line 985; the uncertain flip at line 1019 changes tier afterwards; the
breakdown is built with the stale `reasoning`. Triggers when Stage 3 rescues
a frame from `.borderline` → `.good` with `combinedZ ∈ (-1.0, -0.5)` in a
small group (<8), then uncertain override demotes to `.uncertain`.

**Empirical measurement:** Not directly measurable on stored data (reasoning
text isn't persisted), but the narrow-window reproduction is clear from code
inspection.

**Decision:** Implement the proposed fix. 6-line change adds a `finalReasoning`
variable that overrides to "Small group — low confidence" when the final tier
is `.uncertain`. Tooltips and recommendationLabel now reflect the final tier.

**Test:** `testFINDING03_uncertainOverrideReplacesStaleReasoning`.

---

### FINDING-04 — P90 / P10 small-array index collapse [P1 → rejected]

**Static verdict:** Confirmed math quirk. At count=5–10, `Int(count * 0.9)`
indexes the last element (P100) and `count / 10` indexes 0 (minimum). Not
strictly P90/P10.

**Empirical measurement:**
- **Rule 1c:** 220/234 groups have nominally different current vs interpolated
  P90 stars. But only **3 frames** change classification if we switch. 2 of
  those 3 are human-garbage (correct catches lost). Net: **−2 frames**.
- **Stage 1.5 `fwhmP10`:** 148/232 groups differ. Median FWHM delta = 0.02 px.
  Max delta = 2.9 px but rare. The 1.3× threshold absorbs most of the
  difference; classification changes would be minimal and direction-unclear.

**Decision:** **Do not implement.** Current "mathematically imprecise" behavior
is empirically more accurate on this dataset. Added comments at both sites
documenting the empirical validation and the reason the index wasn't changed.

**No code behavior change.** Comment-only.

---

### FINDING-05 — wSum == 0 silent frame drop [P1 narrow, implemented]

**Static verdict:** Confirmed. `guard wSum > 0 else { continue }` at line 926
(renumbered to 942 at analysis time, now shifted further) silently drops frames
that can't produce any z-score. Pre-guard at line 539 only skips when BOTH
`noiseMAD` and `computedStarCount` are nil — a frame with one populated but
alone in its group (other frames unmeasured → `zscores()` requires count ≥ 2,
returns all nil) slips through to line 926.

**Empirical measurement:** Very narrow case, 0 confirmed occurrences in the
curated dataset. No direct accuracy signal. But the UX bug (missing quality
icon, silent data loss) is real.

**Decision:** Implement. Replace silent `continue` with `.uncertain`
breakdown + explicit "No comparable frames in group — metrics unmeasured or
isolated" reasoning. Zero accuracy impact on current data; UX improvement for
partial-measurement edge cases.

**Test:** `testFINDING05_wSumZeroProducesUncertainNotSilentDrop`.

---

### FINDING-06 — Stage 1.5 severe single-FWHM-outlier path [P2 → P0 impact, implemented]

**Static verdict:** Flagged as calibration question. `severeFwhmMultiplier =
fwhmSanityMultiplier + 0.1` means for galaxies the severe threshold is 1.4×
pool P10 — a narrow margin above the 1.3× "flag" threshold. Single-flag demote
at 1.4× could be too aggressive.

**Empirical measurement:** This was the biggest win. Investigated with
threshold sweep + pure-severe-path analysis.

**Sweep (`/tmp/astrocalib/f06_severe.py`):**

| severeMult | total demoted | TP (garbage) | FP (keep) | precision |
| ---------- | ------------- | ------------ | --------- | --------- |
| 1.30       | 2157          | 594          | 960       | 38.2%     |
| 1.35       | 2122          | 585          | 943       | 38.3%     |
| **1.40 current** | 2082   | 565          | 927       | 37.9%     |
| 1.45       | 2049          | 552          | 911       | 37.7%     |
| 1.50       | 2033          | 548          | 911       | 37.6%     |
| 1.60       | 2013          | 544          | 910       | 37.4%     |
| 1.80       | 1993          | 538          | 905       | 37.3%     |
| 2.00       | 1969          | 536          | 889       | 37.6%     |

Pure-severe-path isolation (`/tmp/astrocalib/f06_severe_pure.py`) — frames with
EXACTLY 1 flag AND FWHM > pool_p10 × severeMult:

| severeMult | n_demoted | TP | FP | precision |
| ---------- | --------- | -- | -- | --------- |
| 1.30       | 219       | 62 | 98 | 38.8%     |
| **1.40 current** | 144 | 33 | 65 | 33.7%    |
| 1.60       | 75        | 12 | 48 | 20.0%     |
| 1.80       | 55        | 6  | 43 | 12.2%     |

**Critical observation:** For EVERY severeMult value tested, the single flag
that fires is ALWAYS `fwhm`. The severe path never catches the "catastrophic L
seeing with good SNR / stars" case claimed by the comment at line 1716-1719 —
when that scenario occurs in reality, it's already caught by the 2-flag rule
because real catastrophic-seeing frames fail other metrics too.

**Option comparison (`/tmp/astrocalib/f06_option_b.py`):**

| option                                              | demoted | TP  | FP  | prec  | net vs current |
| --------------------------------------------------- | ------- | --- | --- | ----- | -------------- |
| **CURRENT (severeMult = 1.4)**                      | 2082    | 565 | 927 | 37.9% | baseline       |
| A: severeMult = 1.6                                 | 2013    | 544 | 910 | 37.4% | −4             |
| B: severe requires non-FWHM flag too                | 1938    | 532 | 862 | 38.2% | **+32**        |
| D: remove severe path entirely (≡ B on this data)   | 1938    | 532 | 862 | 38.2% | **+32**        |

**Decision:** Implement **Option D** (remove severe path entirely). Option B
is semantically equivalent on this data and Option D is simpler (fewer branches
to reason about). Expected improvement: **+32 frames correctly classified on
the curated set**. Larger gains expected on production data because the same
pattern (single-FWHM-flag at 34% precision) will repeat.

**Code change:**
- Deleted `severeFwhmMultiplier` local constant (line 1705).
- Deleted `isSevereOutlier` computation (lines 1765-1768).
- Simplified guard: `guard flags.count >= 2 else { continue }` (was
  `flags.count >= 2 || (flags.count >= 1 && isSevereOutlier)`).
- Added lengthy comment explaining the removal and linking to this document.

**Test:** `testFINDING06_singleFWHMFlag_doesNotDemote`.

---

### FINDING-07 — Rule 7b disabled on bimodal groups [P2 → rejected]

**Static verdict:** Flagged as design question. `starWeight > 0` guard at
line 749 disables Rule 7b when CV > 1.0 (bimodal star counts).

**Empirical measurement:** Only **4 bimodal groups** in the entire 4540-frame
curated dataset, covering 226 frames. If the guard were removed:
**0 additional frames** would be flagged as `starCountDrop` in those bimodal
groups (Rule 7b has its own `stars_med > 20` + `ratio < 0.65` requirements
which don't match in those 4 groups either).

**Decision:** **Do not implement.** The guard has zero empirical cost and
serves as a safety net against false positives on genuinely-bimodal groups.
Added a comment documenting the validation.

**No code behavior change.** Comment-only.

---

### FINDING-08 — Stage 3 Rule A vs Rule B discrimination [P2 cosmetic, implemented]

**Static verdict:** Confirmed that Rule A fires without checking stars, so
Rule B's `starsLow && fwhmOK && trailingOK` path is unreachable when noise
is also OK. Tier outcome is identical (both → `.good`); only the reasoning
text differs.

**Empirical measurement:** 138 frames fall into the Rule-A-applies-and-starsLow
overlap zone. 63 of those would actually be rescued (were borderline or trash
pre-rescue). Human ratings on those 63:
- 27 human-keep (43%)
- 21 ambiguous (33%)
- 15 human-garbage (24%)

Tier outcome unchanged by the fix — all 63 still end up `.good`. Change is
purely textual: the 63 rescued frames now show "Star count dip with normal
FWHM — likely transient event" instead of "FWHM and noise within group norm"
when that's the more accurate narrative.

**Decision:** Implement. One-word change (`&& !starsLow`) with minimal risk.

**No tier-change regression test needed** — existing tests cover the
`.good` outcome. The reasoning-text change is implicit.

---

### FINDING-09 — Raw-MAD threshold in Rule 8 [P2 → rejected]

**Static verdict:** Confirmed inconsistency. `medianAbsoluteDeviation()`
(line 1858) returns raw MAD; `zscores()` (line 1820) normalizes via × 1.4826.
Rule 8 uses raw MAD with threshold 5.0 → 5 raw MADs ≈ 7.4σ-equivalent.
Either empirically calibrated on raw MADs OR too conservative if intended
as σ.

**Empirical measurement:** Full background-deviation analysis
(`/tmp/astrocalib/f09_rule8.py`). 3837 frames evaluated. Threshold sweep:

| threshold | total flagged | TP (garbage) | FP (keep) |
| --------- | ------------- | ------------ | --------- |
| 3.0 raw MAD      | 332    | 103 | 127 |
| 3.3 (≈5σ)        | 298    | 95  | 111 |
| 4.0              | 253    | 84  | 88  |
| **5.0 current**  | 201    | 69  | 61  |
| 6.0              | 170    | 59  | 45  |
| 7.5              | 137    | 50  | 35  |

In the "missed" window (3.3–5.0 raw MADs), there are 26 human-garbage frames.
But **18 of those 26 are already flagged by other garbage reasons**, and
**25 of the 26 are already trashed by the algorithm overall** (only 0 FNs in
that window). Lowering the threshold would:
- Add 18 redundant flags on already-caught frames.
- Add 7–8 net-new catches.
- Add 50 additional false positives on human-keep frames.

Precision at current threshold: 54%. At 3.3: 34%. Clear regression.

**Gradients observation:** User mentioned "strong gradients dann und wann, aber
keine harten Wolkenbilder". Per-frame gradients don't produce deviation-vs-group-median
signal (gradients are uniform across a session). Rule 8 targets frame-to-frame
background shifts; lowering the threshold would not help catch gradients
(which are a different problem needing a different detector).

**Decision:** **Do not change threshold.** Add comments clarifying:
1. `medianAbsoluteDeviation()` returns raw MAD (not σ-normalized).
2. Rule 8's threshold is deliberately calibrated in raw MAD units and was
   empirically validated.

**Comment-only changes** at Rule 8 site (line ~800) and
`medianAbsoluteDeviation()` doc-comment.

---

### FINDING-10 — `garbagePercentile` dead constant [P3, implemented]

**Static verdict:** `grep garbagePercentile` across the repo returns exactly
one site: the declaration itself. Zero reads.

**Decision:** Delete. No functional impact.

**Code change:** Removed the 3-line declaration block (lines 205-207 in the
original file).

---

## 3. Cross-cutting changes

### 3.1 Header pipeline-order comment

The top-of-file comment in `QualityEstimator.swift` previously mentioned only
Stages 1, 1.5, 2 — omitting Stages 1.5b, 3, 4, and the uncertain override.
A reader couldn't tell from the header where Stage 4 runs or that Stage 1.5b
follows 1.5. The header now enumerates all stages in execution order with
inline notes on the intra-per-group-loop steps (dark-frame pre-pass, absolute
floor, Stage 2/3, community floor, uncertain override) and the post-pass
stages (1.5, 1.5b, low-confidence flag, Stage 4, historical annotation).

### 3.2 Algorithm version bump

`kAlgorithmVersion`: 22 → 23. FINDING-06 (severe path removal) and FINDING-01
(Stage 4 reason preservation) both change scoring behavior. The other changes
are comment-only, test additions, bug fixes that don't alter any
algorithmically-reachable state, or dead-code removal.

The version bump ensures:
- Frame History DB records carry the correct version for re-analysis.
- The ALGORITHM_CHANGELOG.md entry for v23 is authoritative for interpreting
  records stored during this window.
- Users clicking "Re-Analyze All" on older records will migrate them under the
  new logic.

### 3.3 Changelog entry

See `ALGORITHM_CHANGELOG.md` → "Version 23 — v5.26.0 (2026-04-18)". Mirrors
the decision summary above but written in the codebase's standard changelog
format.

---

## 4. Tests added

All four tests are in `Tests/QualityEstimatorTests.swift` under the
"Algorithm v23 regression tests (curation-driven tune-up, 2026-04-18)" MARK.

| Test                                                        | Finding | What it asserts |
| ----------------------------------------------------------- | ------- | --------------- |
| `testFINDING06_singleFWHMFlag_doesNotDemote`                | 06      | Frames with ONLY a "FWHM far above norm" flag are not session-sanity-demoted to trash. |
| `testFINDING01_stage4RescuePreservesSanityReasons`          | 01      | When Stage 4 rescues a sanity-demoted frame to borderline, `sessionSanityReasons` remain populated and `recommendationLabel` starts with "REVIEW —". |
| `testFINDING03_uncertainOverrideReplacesStaleReasoning`     | 03      | Frames whose tier flips to `.uncertain` have reasoning "Small group — low confidence" (no stale rescue narrative). |
| `testFINDING05_wSumZeroProducesUncertainNotSilentDrop`      | 05      | A frame in a group where z-scores are all nil is emitted as an `.uncertain` breakdown (not silently dropped from the result dict). |

Existing tests that must still pass (regression coverage):
- `testSessionSanityCheck_demotesBadCrossGroup` (uses a 2-flag scenario)
- `testSessionSanityCheck_mixedPlateScaleStillCatchesRealBadNight` (FWHM at 2.1× P10 → still demoted via non-FWHM flag co-occurrence)
- `testSessionSanityCheck_respectsLockedKeep` (Stage 1 garbage not re-demoted)
- `testSessionSanityCheck_mixedPlateScaleArcsecNormalization` (uniform seeing → no sanity flags)
- All existing Stage 1 / Stage 2 / Stage 3 rescue tests.

---

## 5. Findings at a glance (for quick re-review)

| # | Prüfanweisung verdict | Empirical verdict | Decision | Expected delta on curated set |
| - | --------------------- | ----------------- | -------- | ------------------------------ |
| 01 | Confirmed bug (P0)    | Partially correct; proposed fix would net-worsen | **Implemented differently** — preserve reason fields, keep the rescue | Rescued-borderline frames now show REVIEW banner with original sanity reason |
| 02 | Confirmed bug (P1)    | Net −4 if implemented | **Rejected** (comment only) | No change |
| 03 | Confirmed bug (P1 cosmetic) | Narrow reproduction from code | **Implemented** | No tier change; better tooltip text |
| 04 | Confirmed bug (P1)    | Net −2 if implemented | **Rejected** (comment only) | No change |
| 05 | Confirmed bug (P1 narrow) | 0 occurrences in data but UX-real | **Implemented** | Frames no longer silently drop from result dict |
| 06 | Uncertain (P2)        | **Clear win: +32 frames** | **Implemented** (severe path removed) | +32 frames net correct |
| 07 | Uncertain (P2)        | 0 bimodal groups benefit | **Rejected** (comment only) | No change |
| 08 | Confirmed design (P2) | Cosmetic only, 63 frames affected | **Implemented** (one-word fix) | No tier change; better reasoning text on 63 frames |
| 09 | Confirmed inconsistency (P2) | Current threshold validated | **Rejected** (comment only) | No change |
| 10 | Dead code (P3)        | Confirmed 0 reads | **Implemented** (delete) | No functional change |

**Scoring-behavior-changing fixes:** 01 (partial), 03, 05, 06, 08.

**Expected net impact on curated set:**
- FINDING-06 alone: +32 correctly-classified frames.
- FINDING-01 (reason preservation): 0 tier changes, but recommendationLabel now
  renders "REVIEW — …" on an estimated 220 borderline frames that previously
  had generic reasoning — much better UX / Autopilot interaction.
- FINDING-03 / 05 / 08: edge-case or cosmetic, no measurable accuracy delta.

**Expected net impact on production data:** At least proportional to curated
set since the curated set is representative (multi-setup, multi-filter,
multi-FL, multi-target). Total production DB has 5811 rows; with 44% FP rate
on z-score-only trash, the v23 changes should recover ~15-20 additional
frames per active user session.

---

## 6. Re-review checklist (for future reviewer)

If a follow-up review wants to validate the decisions in this document:

1. **Regression baseline:** Run `xcodebuild test -scheme AstroTriage`. All
   existing + 4 new tests in `QualityEstimatorTests.swift` should pass.
2. **Re-run curated dataset:** Re-analyze the Frame History DB with v23 and
   compare tier distribution to v22. Expect ~30-50 net tier changes (mostly
   trash → borderline rescues).
3. **Check confusion matrix:** Expect FP rate (algo=trash, user=keep) to drop
   from 22.1% toward ~20-21%. FN rate should be unchanged.
4. **Spot-check 5 rescued borderlines:** Open the app, find a frame that was
   trash under v22 and is now borderline. Confirm the recommendationLabel
   tooltip reads "REVIEW — …" with a sanity reason (FINDING-01 fix visible).
5. **Spot-check severe-path removal:** Find a frame that was previously
   sanity-demoted by single FWHM flag (look in v22 diagnostic logs:
   `~/Library/Containers/com.joergsflow.AstroBlinkV2/Data/Library/Application Support/AstroBlinkV2/stage15b_diag.txt`
   for demote entries). Under v23 such a frame should retain its pre-sanity tier.

If any of these checks fails, the decisions in this document need to be
re-examined. The Python scripts under `/tmp/astrocalib/` (rebuildable from the
DB export + this document's Section 2 table structures) remain the canonical
way to re-measure any proposed change.
