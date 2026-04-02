# Frequently Asked Questions

## General

**Q: Does AstroBlink permanently delete files?**
Never. The pre-delete feature moves files to a `_predel/` subfolder. You can undo with Cmd+Z. Files are only permanently deleted if you manually empty the `_predel/` folder.

**Q: Can I use AstroBlink without AIsaac?**
Yes. AIsaac is completely optional. The app works fully offline with all culling, stacking, and analysis features. AIsaac requires an internet connection.

**Q: Does AstroBlink work with my capture software?**
AstroBlink reads standard FITS and XISF files from any capture software: NINA, SGP, Voyager, APT, ASIAIR, PHD2, etc. NINA's filename tokens and ImageMetaData.csv are supported for extra metadata.

**Q: Why does my quality column show no icons for some frames?**
Quality scoring requires at least 6 frames in a group (same target + filter + exposure). Groups with fewer than 6 frames don't get scored because statistical comparison (z-scores) needs enough samples to be meaningful. This is normal — those frames aren't bad, just in a small group.

## AIsaac

**Q: Is AIsaac free?**
Yes — the Free Sonnet Buddy tier is included, giving you 20 AI queries per day. For deeper analysis with Claude Opus, you can bring your own Anthropic API key (Opus Superexpert mode).

**Q: What data does AIsaac send?**
Only technical session metadata: equipment names, filter names, quality scores, and an 800px JPEG thumbnail of the current image. No file paths, no personal data, no full-resolution images. See the [Privacy Policy](https://github.com/joergs-git/AstroBlinkV2/blob/main/PRIVACY.md).

**Q: Can AIsaac see my images?**
Yes — AIsaac receives an 800px JPEG thumbnail of the currently displayed frame. This helps with visual analysis but is far too small to extract sensitive detail.

**Q: Why does AIsaac sometimes give wrong answers about what's in an image?**
Claude's vision capabilities are impressive but not perfect, especially with monochrome astrophotography images. If AIsaac misidentifies something, just correct him — he'll accept the correction and adjust.

**Q: How do I use voice input?**
Hold the microphone button (left of the input field) and speak. Release to send. macOS will ask for microphone and speech recognition permissions on first use. Works offline on Apple Silicon.

**Q: Can I use AIsaac in German/Dutch/Spanish/etc.?**
Yes — just type in any language and AIsaac will respond in the same language. If your FITS headers contain site coordinates, AIsaac will also offer to switch to your local language automatically.

## SmartCull

**Q: What's the difference between the quality tiers?**
- **Excellent (green):** Clearly above average — best frames
- **Good (green half):** Near average — solid, definitely keep
- **Uncertain (blue ?):** Small group (<8 frames) with ambiguous quality — inspect manually
- **Borderline (orange):** Below average — worth visual inspection. 4 sub-levels from nearly-good to nearly-trash
- **Trash (red):** Catastrophically bad (Stage 1) or statistically worst (Stage 2)

**Q: Should I delete all orange (borderline) frames?**
Usually not. Research shows that including softer-but-round frames barely affects final FWHM while significantly boosting SNR. Only delete frames with elongated stars (trailing). AIsaac's Smart Mark feature can help you decide.

**Q: What is "trailing consensus"?**
When a mount has tracking errors, all stars trail in the same direction. SmartCull measures the position angle of each star's elongation and checks if they agree. >50% agreement = tracking error. Random directions = normal optical aberration (not penalized).

**Q: Why are narrowband frames less penalized for trailing?**
Narrowband filters (Ha, OIII, SII) capture diffuse nebula emission. The science target doesn't depend on point-source star sharpness, and narrowband PSFs are already naturally bloated from chromatic effects. Long narrowband exposures (300-600s) are expensive — clear narrowband nights are rare. Slight tracking drift within the seeing disk barely affects the final stack quality. SmartCull applies a 0.3× trailing weight multiplier for narrowband, 0.6× for RGB, and full 1.0× for luminance (the sharpness channel). This prevents wasting precious integration time on frames with barely visible elongation.

**Q: What is the Convergence Guard?**
When you've already culled most of the bad frames, further culling gives diminishing returns — you lose more integration time (SNR) than you gain in quality. The Convergence Guard warns you before the Autopilot marks frames in this situation. If the quality spread is already tight (< 0.3) or SNR loss would exceed integration loss, a dialog explains why you might want to stop. Conservative mode is never guarded — trash is always trash.

**Q: What is Blink Playback?**
Click the Play button in the slider bar to auto-cycle through all visible images at an adjustable speed (0.1–2s delay). If you have frames selected, it blinks only those. Press ESC or the Stop button to end. It respects your current filters and hide-marked setting. Great for quickly spotting patterns like trailing, clouds, or focus drift.

**Q: What is the Frame History Database?**
A persistent SQLite database that tracks all per-frame quality metrics across every session you open. Frames are identified by SHA256 hash (first 64KB), so renamed or moved files are still recognized. This enables cross-session scoring, historical baselines, and the History window with 6 KPI charts. Backed up to iCloud automatically.

**Q: What does the "Re-Analyze" button do?**
When the scoring algorithm is updated, previously scored frames may use an older version. The orange Re-Analyze button in the History window re-scores all stale records with the current algorithm. No image re-decode needed — it uses the stored metrics. Frames in groups too small for statistical scoring get their version bumped to clear the stale indicator.

**Q: What is PSF Flux?**
PSF Flux measures the total stellar signal in a frame by summing the fitted Gaussian flux (2π·A·σ²) across all measured stars, scaled to the full image. It captures both star count AND brightness — more robust than star count alone because it's immune to hot pixel inflation. PSF Flux z-score replaces star count in quality scoring when GPU PSF fitting is available.

**Q: Why do the History charts look different at long time ranges?**
When the selected time range exceeds 6 months, charts automatically switch to monthly aggregation for cleaner trends. A calendar icon indicates this mode. This avoids cluttered daily bars over many months.

## Stacking

**Q: Is LightspeedStacker a replacement for PixInsight/APP?**
No — it's a quick preview stacker for checking session quality and sharing previews. For final results, use dedicated stacking software. LightspeedStacker includes min/max pixel rejection and Lanczos-3 interpolation.

**Q: What is SSWEIGHT?**
A quality weight (0-100) written to your FITS/XISF headers. PixInsight's WBPP (Weighted Batch Pre-Processing) uses this for weighted integration — better frames get more weight in the final stack.

---

More questions? [Open an issue on GitHub](https://github.com/joergs-git/AstroBlinkV2/issues)
