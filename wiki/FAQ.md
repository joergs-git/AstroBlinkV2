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
- **Borderline (orange):** Below average — worth visual inspection. 4 sub-levels from nearly-good to nearly-trash
- **Trash (red):** Catastrophically bad (Stage 1) or statistically worst (Stage 2)

**Q: Should I delete all orange (borderline) frames?**
Usually not. Research shows that including softer-but-round frames barely affects final FWHM while significantly boosting SNR. Only delete frames with elongated stars (trailing). AIsaac's Smart Mark feature can help you decide.

**Q: What is "trailing consensus"?**
When a mount has tracking errors, all stars trail in the same direction. SmartCull measures the position angle of each star's elongation and checks if they agree. >50% agreement = tracking error. Random directions = normal optical aberration (not penalized).

## Stacking

**Q: Is LightspeedStacker a replacement for PixInsight/APP?**
No — it's a quick preview stacker for checking session quality and sharing previews. For final results, use dedicated stacking software. LightspeedStacker includes min/max pixel rejection and Lanczos-3 interpolation.

**Q: What is SSWEIGHT?**
A quality weight (0-100) written to your FITS/XISF headers. PixInsight's WBPP (Weighted Batch Pre-Processing) uses this for weighted integration — better frames get more weight in the final stack.

---

More questions? [Open an issue on GitHub](https://github.com/joergs-git/AstroBlinkV2/issues)
