#!/usr/bin/env python3
"""Build the curated Golden Mini-Set from the full QUALITYCHECKDATA corpus.

Auto-builds the cases that already have labeled good/bad data, choosing a SINGLE GroupKey
(one filter + one exposure) per case so QualityEstimator (minGroupSize=6) actually scores
them. Pure filename parsing — no image decode — so it runs instantly and handles both
NINA (.xisf) and ASIAIR (.fit) naming.

Measurement-based cases (no pre-existing PRE-DELETE labels) are auto-picked by the REAL
app pipeline (a one-shot XCTest dumps per-frame metrics), so picked frames match what the
gate re-measures. These live in QUALITYCHECKMINI (gitignored, persist):
  - short_osc_asiair_galaxy_trails (M101 60s Extr): bad = aligned star-trailing
    (trailingScore>=0.85 AND consensus>=0.7 → satellite-SAFE: a lone streak gives low
    consensus → score 0 → excluded); good = lowest trailingScore.
  - short_osc_asiair_galaxy_twilight (M101 120s Extr): good = deep-night low-background;
    bad = dawn-twilight frames (background ramp into daylight, Stage-1 garbage: abnormal
    background / no signal / low SNR). Also covers the strong-GRADIENT dimension.
Deferred dims with NO clean source in current data (harness XCTSkips them until populated):
  - dark/dome/cap: no dark/dome/flat frames exist in the corpus.
  - wind/FWHM-pure (round but bloated, dark sky): every high-FWHM frame on hand is either
    trailing (M81 bad-star-form, already a case) or dawn-contaminated (the twilight case);
    a clean isolated seeing/wind case needs the user to supply a windy-but-clear-night set.
Add either later with the same measurement-pick approach.

Usage:
    python3 scripts/build_mini_set.py            # auto-build labeled cases
    python3 scripts/build_mini_set.py --dry-run  # show selection without copying
"""
import os, re, sys, shutil
from collections import defaultdict

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SRC  = os.path.join(REPO, "TestImages", "QUALITYCHECKDATA")
DST  = os.path.join(REPO, "TestImages", "QUALITYCHECKMINI")
EXTS = {".fit", ".fits", ".fts", ".xisf"}
N_GOOD, N_BAD = 12, 8   # per case

# Auto-buildable cases: (case_id, good_source_relpath, bad_source_relpath)
# good = images directly in good_source dir; bad = images directly in bad_source dir.
CASES = [
    ("medium_mono_asiair_galaxy_badstars", "M81",      "M81/PRE-DELETE_bad_star_form"),
    ("long_mono_nina_nb_trackinghop",      "M82",      "M82-January"),
    # ngc7000 / NGC7635 PRE-DELETE frames are user rejections invisible to the metrics
    # (transparency/gradient/framing — "blind curation"); validation showed they score Good
    # with normal SNR, so they are NOT valid measurement-gate BAD cases. Kept good-only.
    ("fast_osc_nina_nb_baseline",          "NGC7635",  ""),
    ("medium_mono_asiair_nb_baseline",     "ngc7000",  ""),
]

def list_images(d):
    if not os.path.isdir(d): return []
    return sorted(os.path.join(d, f) for f in os.listdir(d)
                  if not f.startswith(".") and os.path.splitext(f)[1].lower() in EXTS)

def parse_key(fn):
    """Return (filter, exposure_rounded) from a NINA or ASIAIR filename, or (None, None)."""
    b = os.path.basename(fn)
    filt = exp = None
    # exposure: first '<num>s' token (handles 180.00s / 120.0s / 300.00s)
    m = re.search(r'_(\d+(?:\.\d+)?)s[_.]', b) or re.search(r'_(\d+(?:\.\d+)?)s', b)
    if m: exp = int(round(float(m.group(1))))
    # NINA: ..._LIGHT_<F>_<exp>s_...
    m = re.search(r'_LIGHT_([^_]+)_\d', b)
    if m:
        filt = m.group(1)
    else:
        # ASIAIR: ..._<camera>_<F>_gain... (camera like 2600MC/6200MM)
        m = re.search(r'_(?:\d{3,4}M[MC])_([A-Za-z]+)_gain', b)
        if m: filt = m.group(1)
        else:
            m = re.search(r'_([A-Za-z]{1,6})_gain', b)  # fallback
            if m: filt = m.group(1)
    return (filt, exp)

def pick_group(good, bad):
    """Choose the (filter,exp) GroupKey present in good (and bad if any) maximizing usable frames."""
    gg = defaultdict(list); bb = defaultdict(list)
    for f in good: gg[parse_key(f)].append(f)
    for f in bad:  bb[parse_key(f)].append(f)
    if bad:
        shared = [k for k in gg if k in bb and k[0] is not None]
        if shared:
            # maximize min(good,bad) then total
            best = max(shared, key=lambda k: (min(len(gg[k]), len(bb[k])), len(gg[k]) + len(bb[k])))
            return best, gg[best], bb[best]
        # no shared key: take the bad group with most frames + its matching good key if any
        bk = max(bb, key=lambda k: len(bb[k]))
        return bk, gg.get(bk, []), bb[bk]
    # good-only
    gk = max(gg, key=lambda k: len(gg[k]))
    return gk, gg[gk], []

def evenly(seq, n):
    if len(seq) <= n: return list(seq)
    step = len(seq) / n
    return [seq[int(i * step)] for i in range(n)]

def build(case_id, good_src, bad_src, dry):
    gpath = os.path.join(SRC, good_src)
    bpath = os.path.join(SRC, bad_src)
    good_all = [f for f in list_images(gpath)]  # root-level only
    bad_all  = list_images(bpath)
    if not good_all and not bad_all:
        print(f"  ! {case_id}: no source images ({good_src}, {bad_src}) — skipped (corpus absent?)")
        return
    key, good_g, bad_g = pick_group(good_all, bad_all)
    good_sel = evenly(good_g, N_GOOD)
    bad_sel  = evenly(bad_g, N_BAD)
    filt, exp = key
    print(f"  {case_id}: GroupKey filter={filt} exp={exp}s | good {len(good_sel)}/{len(good_g)} "
          f"(of {len(good_all)} all)  bad {len(bad_sel)}/{len(bad_g)} (of {len(bad_all)} all)")
    if len(good_sel) < 6:
        print(f"    WARNING: <6 good frames in group — will be skipped by the gate (group<minGroupSize).")
    if dry: return
    out_good = os.path.join(DST, case_id, "good")
    out_bad  = os.path.join(DST, case_id, "PRE-DELETE")
    os.makedirs(out_good, exist_ok=True); os.makedirs(out_bad, exist_ok=True)
    for f in good_sel: shutil.copy2(f, out_good)
    for f in bad_sel:  shutil.copy2(f, out_bad)
    with open(os.path.join(DST, case_id, "README.txt"), "w") as fh:
        fh.write(f"case: {case_id}\nGroupKey: filter={filt} exposure={exp}s\n"
                 f"good source: {good_src} ({len(good_sel)} frames)\n"
                 f"bad source:  {bad_src} ({len(bad_sel)} frames)\n")

def main():
    dry = "--dry-run" in sys.argv
    if not os.path.isdir(SRC):
        print(f"QUALITYCHECKDATA not found at {SRC} — nothing to build."); return
    print(f"Building mini-set → {DST}  (dry-run={dry})")
    for c in CASES:
        build(c[0], c[1], c[2], dry)
    print("\nLabeled cases done. Unlabeled dims (M101 trails/twilight, Heart, NGC3184, ngc2251)")
    print("need thumbnail tagging — run the Swift analysis harness, then copy chosen frames.")

if __name__ == "__main__":
    main()
