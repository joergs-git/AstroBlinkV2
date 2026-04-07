# AstroBlink vs Competitors — Why AstroBlink?

If you're coming from PixInsight, Siril, or AstroPixelProcessor and wondering what AstroBlink does differently, this page breaks it down.

---

## The Problem with Current Tools

Every astrophotographer needs to cull bad sub-exposures before stacking. The current options all force a compromise:

- **PixInsight Blink** lets you visually flip through frames — but shows zero quality metrics, can't delete files, and crashes with 200+ compressed XISF files
- **PixInsight SubframeSelector** measures FWHM/eccentricity/SNR — but requires hand-written JavaScript formulas and has no visual preview
- **Siril** measures individual metrics — but has no combined quality score and no built-in blink mode
- **APP** has a quality score — but users report it's unreliable, and it still has no blink comparator after 40+ beta releases

**The result?** Many astrophotographers have given up on culling entirely, dumping everything into WBPP and hoping for the best.

---

## What AstroBlink Does Differently

AstroBlink is the **only tool that combines visual blink inspection AND automated quality scoring** in one integrated UI.

### One-Key Workflow
- Arrow keys to navigate, Space to mark, Cmd+Backspace to move marked files to a PRE-DELETE folder
- Full undo with Cmd+Z — nothing is permanent until you confirm
- No multi-step file operations, no external file managers

### SmartCull — 5-Stage Automatic Quality Scoring
- Stage 1: Detects garbage (dome frames, dark frames, extreme outliers)
- Stage 1.5: Cross-group session sanity check
- Stage 2: Z-score ranking across FWHM, stars, noise, trailing
- Stage 3: Rescue rules (saves frames unfairly penalized by one metric)
- Stage 4: FWHM sanity check

No formulas to write. No thresholds to guess. Works out of the box.

### Industry-First Trailing Detection
AstroBlink's orientation consensus algorithm analyzes the **direction** of star elongation across the frame:
- If stars are elongated in the **same direction** → tracking error (penalize)
- If elongation directions are **random** → optical aberration like coma (don't penalize)
- Focal-length-aware baseline: short FL naturally has more coma, long FL expects tighter PSFs

No other tool makes this distinction.

### Filter-Aware Scoring
Narrowband trailing (Ha, OIII, SII) is penalized 70% less than luminance — because narrowband PSFs are naturally bloated, and 300-600s narrowband exposures are expensive. Don't throw away precious Ha data for slight trailing that won't affect the nebula.

### Target-Aware Scoring
AstroBlink knows that galaxies, nebulae, and star clusters have different quality priorities:
- **Galaxies**: FWHM and trailing matter most (small angular size)
- **Nebulae/SHO**: Star count less important (extended emission dominates)
- **Star clusters**: Star count heavily weighted (stars ARE the target)

229+ deep-sky targets with automatic type classification.

### Self-Calibrating Baseline
After 30+ frames with the same equipment setup, AstroBlink learns your baseline quality. Frames that meet this baseline are locked as KEEP — they're objectively good for your setup, regardless of what other frames in the session look like.

### GPU-Accelerated Everything
Built from the ground up for Apple Silicon with Metal compute:
- STF auto-stretch: <8ms for 50MP images (PixInsight takes seconds)
- Navigation with cache: <32ms (instant feel)
- GPU PSF fitting: elliptical Gaussian for accurate eccentricity
- Dual Metal command queues for parallel display + prefetch

---

## Side-by-Side Comparison

| | AstroBlink | PixInsight | Siril | APP |
|--|-----------|-----------|-------|-----|
| **Price** | Free | €300 | Free | €60/yr or €165 |
| **Visual blink** | Native GPU | Separate tool (CPU) | Python addon | Not available |
| **Quality scoring** | Automatic 5-stage | Manual formulas | No combined score | Unreliable |
| **Trailing detection** | Orientation consensus | None | None | None |
| **File management** | Mark + move + undo | Can't delete from Blink | Can't delete (by design) | % slider only |
| **GPU compute** | Full Metal pipeline | None | None | None (Java) |
| **NINA integration** | Full (CSV + filename + headers) | No | No | Partial |
| **SSWEIGHT export** | Yes (headers + CSV) | Native | No | No |
| **AI assistant** | AIsaac (Claude-powered) | None | None | None |
| **Meridian flip** | Auto-rotation | Must align first | No | No |
| **Platform** | macOS | Win/Mac/Linux | Win/Mac/Linux | Win/Mac/Linux |

---

## Capture Software Compatibility

AstroBlink reads quality data from multiple sources in priority order:

1. **FITS/XISF headers** (works with ALL capture software — NINA, ASIAIR, SGPro, Voyager, KStars, TheSkyX)
2. **NINA filename tokens** (20+ tokens: HFR, star count, filter, gain, exposure, etc.)
3. **NINA ImageMetaData.csv** (SessionMetadata plugin data)

**ASIAIR users:** Your FITS headers contain all standard keywords (OBJECT, FILTER, EXPTIME, CCD-TEMP, GAIN, DATE-OBS, INSTRUME, TELESCOP, etc.) and AstroBlink reads them all. Filename-specific tokens like HFR and star count are NINA-only, but AstroBlink measures these directly from your images using GPU analysis — often more accurately than capture software estimates.

---

## What AstroBlink Is NOT

AstroBlink is a **dedicated culling/triage tool**, not a full processing pipeline. It does not replace PixInsight, Siril, or APP for:
- Calibration (darks, flats, bias)
- Deep stacking with rejection algorithms
- Post-processing (curves, color balance, noise reduction workflows)

AstroBlink sits **before** your processing pipeline: cull the bad frames, export SSWEIGHT/PSFSWGHT for weighted stacking, then process in your tool of choice.

---

## SSWEIGHT & PSFSWGHT — Bridge to PixInsight

AstroBlink writes quality weights directly to your FITS/XISF headers:

- **SSWEIGHT** — Compatible with PixInsight WBPP weighted integration
- **PSFSWGHT** — Compatible with PixInsight 1.8.9+ PSFSignalWeight

AstroBlink's PSFSWGHT formula is fully documented and open (unlike PixInsight's proprietary PSFSignalWeight). A PixInsight bridge script is also available to import AstroBlink's CSV data directly into PI.

---

## More Information

- **[SmartCull Algorithm](SmartCull-Algorithm)** — Deep dive into the 5-stage scoring pipeline
- **[Getting Started](Getting-Started)** — First-time setup and workflow
- **[Keyboard Shortcuts](Keyboard-Shortcuts)** — Complete keyboard reference
- **[AIsaac Guide](AIsaac-Guide)** — Your built-in AI astrophotography assistant
- **[FAQ](FAQ)** — Frequently asked questions
