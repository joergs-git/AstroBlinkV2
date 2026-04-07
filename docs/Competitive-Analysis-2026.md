# Competitive Analysis: AstroBlink vs PixInsight vs Siril vs APP

**Date:** April 2026  
**Scope:** Frame culling / subframe selection / triage workflow comparison  
**Research sources:** CloudyNights, StargazersLounge, astrotreff/astronomie.de, official changelogs, product pages

---

## Current Versions & Pricing

| Tool | Version | Price | Platform | GPU Compute |
|------|---------|-------|----------|-------------|
| **AstroBlink** | v5.19.2 (build 65) | Free | macOS (Apple Silicon native) | Full Metal pipeline |
| **PixInsight** | 1.9.3 (Feb 2025) | €300 perpetual | Win/Mac/Linux | None (confirmed v1.9.3) |
| **Siril** | 1.4.2 (Feb 2026) | Free, open-source | Win/Mac/Linux | None (open issue #1450) |
| **APP** | 2.0.0-beta40 (Mar 2026) | €60/yr or €165 perpetual | Win/Mac/Linux (Java) | None ("on TODO list") |

---

## Feature Comparison Matrix

### Visual Inspection

| Feature | AstroBlink | PixInsight | Siril | APP |
|---------|-----------|-----------|-------|-----|
| Visual blink comparator | Native, GPU-accelerated | Blink tool (separate, CPU) | Python addon only | Not available |
| Metrics alongside images | 20+ sortable columns | No (Blink = visual only) | One metric at a time | Basic quality in list |
| Consistent auto-stretch | 3 modes (auto/locked/global) | Per-frame only (inconsistent) | Buggy (open issue #1934) | Basic |
| Compare window | Synced zoom/pan + PA overlay | Complex setup | Not available | Not available |
| Meridian flip handling | Auto-rotation (XOR logic) | Must StarAlign first | No | No |
| Blink video export | GIF + HEVC (.mov) | No | No | No |
| Night mode (red-on-black) | Yes | No | No | No |

### Quality Scoring

| Feature | AstroBlink | PixInsight | Siril | APP |
|---------|-----------|-----------|-------|-----|
| Combined quality score | 5-stage SmartCull (automatic) | Manual JS expressions | No combined score | Unreliable |
| Star trailing detection | Orientation consensus (industry first) | No | No | No |
| Filter-aware scoring | NB×0.3, RGB×0.6, L×1.0 | No | No | No |
| Target-aware scoring | 229+ targets, type-based weights | No | No | No |
| Self-calibrating baseline | Per-setup, learns after 30 frames | No | No | No |
| Convergence detection | Auto "culling complete" signal | No | No | No |
| GPU PSF fitting | Elliptical Gaussian (Metal) | CPU only | No | No |
| SSWEIGHT export | FITS/XISF headers + CSV | Native (proprietary formula) | No | No |
| PSFSWGHT export | Open formula (PI 1.8.9+ compatible) | Native PSFSignalWeight | No | No |

### File Management

| Feature | AstroBlink | PixInsight | Siril | APP |
|---------|-----------|-----------|-------|-----|
| One-key mark/delete | Space + Cmd+Bksp | Multi-step workflow | Checkbox (no file move) | % slider only |
| Pre-delete staging | PRE-DELETE/ folder | No | No | No |
| Unlimited undo | Cmd+Z (full stack) | No | No | No |
| Delete from within app | Yes | No | No (by design) | No |
| Move to custom folder | Cmd+M + create folder | Move icon (cumbersome) | No | No |

### Metadata & Integration

| Feature | AstroBlink | PixInsight | Siril | APP |
|---------|-----------|-----------|-------|-----|
| NINA filename tokens | 20+ tokens (HFR, stars, etc.) | No | No | Partial |
| NINA CSV integration | Full (SessionMetadata plugin) | No | No | No |
| ASIAIR filename parsing | 2/12 tokens (header fallback works) | No | No | No |
| FITS/XISF header reading | Full (cfitsio + libxisf) | Full | Full | Full |
| Bortle from satellite data | VIIRS 2024 (0.025° resolution) | No | No | No |
| Moon distance/phase | Full calculator | No | No | No |

### Performance (50MP mono, Apple Silicon)

| Metric | AstroBlink | PixInsight | Siril | APP |
|--------|-----------|-----------|-------|-----|
| STF stretch | <8ms (GPU) | Seconds (CPU) | Seconds (CPU) | Seconds (CPU) |
| First image display | ~170ms | Seconds | Seconds | Seconds |
| Navigation (cached) | <32ms | ~500ms+ | ~500ms+ | ~1s+ (Java GC) |
| 300-file session | <45s | Crashes at 200+ XISF | Minutes | UI freezes |
| Memory model | Unified Memory, zero-copy | Standard copies | Standard | Java heap |

### Additional Features

| Feature | AstroBlink | PixInsight | Siril | APP |
|---------|-----------|-----------|-------|-----|
| AI assistant | AIsaac (Claude-powered) | None (anti-AI license) | None | None |
| Target catalog + visibility | 533+ objects, alt/az, weather, FOV | No | No | No |
| Frame history database | SQLite, cross-session, iCloud sync | No | No | No |
| Quick stacking | LightspeedStacker (GPU, Lanczos-3) | Full pipeline | Full pipeline | Full pipeline |
| Color combine | SHO/HOO/LRGB presets, weight sliders | Full pipeline | Full pipeline | Full pipeline |
| Confidence rating | 1-3 stars, persisted | No | No | No |
| Keyboard-first UX | 20+ shortcuts, key repeat | Limited | Limited | Limited |

---

## Detailed Competitor Analysis

### PixInsight (v1.9.3, €300) — Blink + SubframeSelector

#### Verified Current Pain Points (April 2026)

**Blink Tool:**
- Cannot delete or move files — must use external file manager after visual identification
- Shows zero metrics (FWHM, stars, eccentricity, SNR) — visual-only
- Meridian flip frames appear 180° rotated — "only way to get uniform rotation is to blink after StarAlignment"
- Crashes with 200+ compressed XISF files on 32GB systems
- No sorting, filtering, or grouping capability
- Each frame gets different auto-stretch — unreliable for comparison

**SubframeSelector:**
- Still requires hand-written JavaScript expressions for weighting formulas
- Different formulas needed for galaxies vs nebulae vs clusters
- PSFSignalWeight formula remains proprietary and undocumented
- Does not read NINA CSV data or HFR/star count from filenames
- *Partial improvement:* WBPP 2.9.0 (Jan 2026) added interactive threshold filtering with bar charts — simpler but still manual threshold-based, not automated

**Overall Workflow:**
- Two completely disconnected tools with no shared context
- Growing user consensus: "just dump everything into WBPP" — many have given up on culling entirely
- No GPU compute at all (confirmed: "PixInsight 1.9.3 still doesn't make direct use of GPUs")
- New PCL License v2.0 (April 2025) explicitly prohibits AI/ML training on PI code
- €300 price + steep learning curve barrier for beginners

**What PI Does Well:**
- Mature ecosystem with decades of community knowledge
- Excellent processing algorithms (for post-calibration work)
- Large tutorial/YouTube ecosystem
- Cross-platform (Win/Mac/Linux)
- PSFSignalWeight is accurate despite being proprietary

---

### Siril (v1.4.2, Free)

#### Verified Current Pain Points (April 2026)

- **No combined quality score** — Individual metrics only (FWHM, roundness, stars, background). No composite ranking.
- **No native blink comparator** — Python addon `Svenesis-BlinkComparator.py` (PyQt6) is now capable but requires separate install, runs as external window
- **Cannot delete/move files** — Design philosophy: "Could you add commands to delete files? Short answer: No."
- **Plot shows one metric at a time** — Cannot overlay multiple metrics. Improved in 1.4.0 (internal siril_plot), still single-metric natively
- **Auto-stretch buggy** — Open issue #1934 (March 2026, v1.4.2): "Sequence stretching and autostretch can misuse statistics"
- **No SSWEIGHT export** — Cannot write quality weights to headers
- **No GPU compute** — Open issue #1450 (Dec 2024, still open)
- **No star trailing detection** — Basic roundness ratio only, no orientation consensus
- **No AI-based culling** — AI integration only for post-processing (GraXpert, CosmicClarity)

**What Siril Does Well:**
- Free and open-source with active development
- Good stacking engine with drizzle support (v1.4.0)
- Strong astrometry (SIP distortions)
- Growing Python scripting ecosystem
- Cross-platform

---

### AstroPixelProcessor (v2.0.0-beta40, €60/yr or €165)

#### Verified Current Pain Points (April 2026)

- **No GPU acceleration** — Still Java/CPU-only after 40+ beta releases. "On the TODO list" with no date.
- **Quality score unreliable** — Forum thread: "Quality Score unreliable for useable subs." Users advised to manually verify via plots.
- **UI freezes** — Java Swing blocks on long operations. Complete unresponsiveness.
- **No blink comparator** — RFC filed ("Blink mode to remove bad frames"), on developer TODO since 2021, not implemented after 40 betas
- **No SSWEIGHT export** — Cannot write quality weights to FITS/XISF headers
- **No trailing detection** — No orientation consensus, no focal-length baseline
- **Memory issues** — "Why would APP need 2.3 TB to integrate 38 GB?" JVM memory pressure.
- **Still in beta** — APP 2.0 has been in beta for years; user frustration with pace
- **Subscription fatigue** — €60/year renters feel locked in

**What APP 2.0 Improved:**
- Faster registration engine
- Better Local Normalization Correction (LNC 2.0)
- Improved multi-narrowband processing
- ~30-50% performance boost in beta40
- Apple Silicon native build (~50% faster than Intel)

**What APP Does Well:**
- Beginner-friendly compared to PixInsight
- Good optical distortion correction
- Multi-narrowband support
- Cross-platform

---

## AstroBlink Unique Advantages

Features no competitor offers:

1. **Orientation Consensus Trailing Detection** — Industry first. Circular statistics on star position angles distinguish tracking errors from optical aberrations.
2. **Target-Aware Quality Scoring** — 229+ deep-sky targets with type-based metric weight modifiers (galaxies, nebulae, clusters scored differently).
3. **Self-Calibrating Per-Setup Baseline** — Learns equipment quality baseline after 30+ frames. Locks proven-good frames.
4. **Filter-Aware Trailing Penalties** — Physics-based: narrowband trailing penalized 70% less than luminance.
5. **Convergence Detection** — Signals when further culling is counterproductive.
6. **AIsaac AI Assistant** — Claude-powered session analysis with equipment memory.
7. **GPU PSF Fitting** — Elliptical Gaussian via Metal compute, eccentricity + PA from fitted parameters.
8. **Integrated Visual + Metrics** — Single tool combines blink AND scoring. No competitor does both.
9. **Pre-Delete Staging with Undo** — Crash-safe filesystem moves, unlimited undo stack.
10. **Frame History Database** — Cross-session quality tracking, historical z-scores and percentiles.
11. **Blink Video Export** — GIF/HEVC with crop-to-zoom, multi-select.
12. **Target Catalog + Visibility** — 533+ objects, alt/az, weather, FOV simulation inside the culling tool.

---

## AstroBlink Current Limitations

1. **macOS only** — Excludes Windows/Linux users (majority of astrophotography market). Biggest competitive limitation.
2. **Not a full processing pipeline** — Purpose-built culler, not a replacement for PI/Siril/APP for calibration or deep post-processing.
3. **Smaller community** — Newer tool vs decades of PI community knowledge and tutorials.
4. **No plate solving** — Relies on FITS header coordinates from capture software.
5. **Limited non-NINA filename parsing** — NINA: 20+ tokens. ASIAIR: 2/12 tokens (gain, sensor temp). SGPro/Voyager: not parsed. FITS/XISF header fallback extracts all standard keywords regardless of capture software, so files still work — just without filename-only tokens like HFR and star count.
6. **VLM Check still ALPHA** — Vision-based anomaly detection not reliable enough for production.

---

## ASIAIR Filename Compatibility

Example ASIAIR filename:  
`Light_M 81_180.0s_Bin1_6200MM_H_gain100_20260402-002642_101deg_-10.0C_140er_0003`

| Token | Value | Parsed? | Why |
|-------|-------|---------|-----|
| Frame Type | `Light` | No | Expects underscore-surrounded `_LIGHT_` |
| Target | `M 81` | No | Expects NINA date-target-time pattern |
| Exposure | `180.0s` | No | Expects `_NNNs_` or `_NNNs#` context |
| Binning | `Bin1` | No | Expects `BinNxN` format (e.g., `bin1x1`) |
| Camera | `6200MM` | No | Expects `ASI` prefix |
| Filter | `H` | No | Expects frame type keyword before filter |
| Gain | `gain100` | **Yes** | Matches `(?i)gain(\d+)` anywhere |
| DateTime | `20260402-002642` | No | Expects `YYYY-MM-DD` and `HH-MM-SS` |
| Rotator | `101deg` | No | No filename extractor (header only) |
| Sensor Temp | `-10.0C` | **Yes** | Matches `_(-?\d+\.?\d*)[cC]_` |
| Focal Length | `140er` | No | No filename extractor |
| Sequence # | `0003` | No | Expects `#NNNN` prefix |

**Result: 2/12 tokens parsed. All standard FITS header keywords (OBJECT, FILTER, EXPTIME, CCD-TEMP, GAIN, DATE-OBS, INSTRUME, TELESCOP, etc.) are read correctly from file headers regardless of filename format.**

---

## Competitive Positioning

```
                    VISUAL INSPECTION
                         |
         Blink (PI)      |        AstroBlink
         visual only     |        *** UNIQUE POSITION ***
         no metrics      |        visual + metrics + AI
         no delete       |        automated scoring
                         |        pre-delete staging
                         |
  ---- NO SCORING -------+-------- AUTOMATED SCORING ---->
                         |
         Siril           |        SubframeSelector (PI)
         basic metrics   |        powerful but manual formulas
         no blink        |        no visual inspection
         no scoring      |        proprietary algorithms
                         |
         APP             |
         unreliable score|
         no GPU          |
```

**AstroBlink is the only tool that combines visual inspection AND automated scoring.**
No competitor sits in this quadrant.

---

## Forum Evidence of Market Demand

- **CloudyNights: ["Better alternatives to blink?"](https://www.cloudynights.com/forums/topic/955947-better-alternatives-to-blink/)** — Users actively searching. Tools mentioned: ASTAP, ASIFitsView, Tenmon. None combines visual + metrics.
- **CloudyNights: ["Need simple quick easy ways to view and delete bad subframes?"](https://www.cloudynights.com/topic/922072-need-simple-quick-easy-ways-to-view-and-delete-bad-subframes/)** — Direct demand for AstroBlink's exact feature set.
- **CloudyNights: ["PI: Blink vs SS vs WBPP"](https://www.cloudynights.com/topic/898247-pi-blink-vs-ss-vs-wbpp/)** — Growing consensus to skip both tools and "just use WBPP." Users gave up on culling.
- **APP Forum: ["Blink mode to remove bad frames"](https://www.astropixelprocessor.com/community/rfcs-request-for-changes/blink-mode-to-remove-bad-frames/)** — Requested since 2021, still not implemented.
- **German forums:** APP session management frustration, Siril script complexity barriers.

---

## Sources

- [CloudyNights: Better alternatives to blink?](https://www.cloudynights.com/forums/topic/955947-better-alternatives-to-blink/)
- [CloudyNights: Need simple quick easy ways to view and delete bad subframes](https://www.cloudynights.com/topic/922072-need-simple-quick-easy-ways-to-view-and-delete-bad-subframes/)
- [CloudyNights: PI Blink vs SS vs WBPP](https://www.cloudynights.com/topic/898247-pi-blink-vs-ss-vs-wbpp/)
- [CloudyNights: Subframe Selection and multiple night imaging](https://www.cloudynights.com/forums/topic/997234-pixinsight-subframe-selection-and-multiple-night-imaging/)
- [APP Forum: Blink mode RFC](https://www.astropixelprocessor.com/community/rfcs-request-for-changes/blink-mode-to-remove-bad-frames/)
- [APP Release Information](https://www.astropixelprocessor.com/community/release-information/)
- [Syracuse Astro: ASIFitsView as Blink alternative](https://www.syracuse-astro.org/2024/01/20/a-better-blink-tool-asifitsview/)
- [PixInsight SubframeSelector guide](https://stirlingastrophoto.com/posts/subframeselector-psfsignalweight-drizzle/)
- [APP Owner's License (€165)](https://www.astropixelprocessor.com/product/astro-pixel-processor-owner-license/)
- [APP Renter's License (€60/yr)](https://www.astropixelprocessor.com/product/astro-pixel-processor-renter-license/)
- [Siril GitLab: GPU offload issue #1450](https://gitlab.com/free-astro/siril/-/issues/1450)
- [Siril GitLab: Auto-stretch bug #1934](https://gitlab.com/free-astro/siril/-/issues/1934)
