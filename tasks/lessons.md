# Lessons Learned

## [2026-03-19] — Always verify scoring changes with BOTH batch test AND app diagnostics
- **Mistake:** Changed z-score thresholds and rescue rules, verified only via batch test (19% trash). But app still showed 42% trash because the app's star detection pipeline produced different trailing scores, causing 20 false-positive "elongation" flags on the BEST frames.
- **Root cause:** Batch test and app use different code paths for star detection (batch: standalone PreviewGenerator; app: PrefetchCache pipeline). Trailing consensus analysis is sensitive to small differences in star positions/eccentricities.
- **Rule:** After ANY scoring change: (1) Run batch test to verify baseline. (2) Add diagnostic logging to the app (UserDefaults write). (3) Compare app output vs batch test. (4) Only present to user when BOTH match.
- **Applies to:** QualityEstimator changes, TrailingAnalyzer changes, any scoring pipeline

## [2026-03-19] — Trailing detection must cross-check FWHM: sharp stars can't be trailing
- **Mistake:** TrailingAnalyzer flagged 20 frames as "star trailing/elongation" even though they had FWHM 6.2-6.9 (the BEST in the session). Real trailing always degrades FWHM.
- **Root cause:** The PA consensus detector found directional agreement in star PSF orientation, but this was optical aberration (coma), not tracking error. The FWHM proved the stars were sharp.
- **Rule:** In Rule 5 (elongation garbage): if frame FWHM ≤ group median × 1.15, skip the trailing flag. Sharp stars + directional PA = optics, not tracking.
- **Applies to:** QualityEstimator Rule 5, TrailingAnalyzer interpretation

## [2026-03-19] — noStars rule needs FWHM cross-check for transient events
- **Mistake:** H#0005 (103 stars, median 1200) flagged as "zero/near-zero stars" trash. But FWHM 6.6 was BETTER than best frame (6.9). The frame visually looked fine — galaxy clearly visible, stars sharp.
- **Root cause:** A transient event (thin cloud, dew) reduced star visibility without degrading star quality. The noStars rule doesn't check if the remaining stars are actually sharp.
- **Rule:** TODO: Add FWHM cross-check to noStars rule. If FWHM ≤ median, the frame's stars are sharp — flag as borderline (transient event), not trash. Same principle as the trailing cross-check.
- **Applies to:** QualityEstimator Rule 1, any star-count-based garbage detection

## [2026-03-19] — Metal .private texture getBytes crashes GPU driver
- **Mistake:** Called `tex.getBytes()` on a PreviewGenerator output texture that has `.private` storageMode. Crashed with EXC_BAD_ACCESS in AGXMetalG15X_M1 twiddle function.
- **Root cause:** `.private` textures are GPU-only. `getBytes()` requires `.shared` or `.managed` storage. The driver crashes instead of returning an error.
- **Rule:** Always blit from `.private` to a `.shared` texture before calling `getBytes()`. Use `MTLBlitCommandEncoder.copy()` → `commit()` → `waitUntilCompleted()` → then `getBytes()` on the shared copy.
- **Applies to:** Any test or utility that needs to read back PreviewGenerator output, PNG export from GPU textures

## [2026-03-15] — NSTableView metric bar constraint accumulation
- **Mistake:** Used `bar.constraints.filter { ... }` to remove old width constraints before adding new ones on cell reuse
- **Root cause:** The proportional width constraint `bar.widthAnchor = cellView.widthAnchor * multiplier` is owned by the common ancestor (`cellView`), not by `bar`. So `bar.constraints` never found it. Constraints accumulated on each cell reuse until layout collapsed.
- **Rule:** For cross-view constraints (involving two sibling views or parent-child), search `parentView.constraints` for the constraint, not `childView.constraints`. Use `c.firstItem === bar || c.secondItem === bar` to find the right one.
- **Applies to:** NSTableView cell reuse with proportional/cross-view constraints

## [2026-03-15] — compareWithBest picked arbitrary frame from same tier
- **Mistake:** Used `qualityTier.rawValue` (0-3 enum) to find "best" frame. Among 20+ excellent frames, picked whichever `.max` returned.
- **Root cause:** `.max(by:)` on equal values returns arbitrary result. Need continuous z-score for fine-grained comparison.
- **Rule:** Always use `qualityZScore` (continuous Double) for "best" selection, not `qualityTier.rawValue` (discrete Int).
- **Applies to:** compareWithBest, any "find best in group" logic

## [2026-03-15] — Quality sort must re-apply after every recomputation
- **Mistake:** Used `initialQualitySortDone` flag to fire sort only once. After Reset + re-cache, quality scores changed but array was not re-sorted.
- **Root cause:** Quality scores update in-place on each `recomputeQualityScores()` call, but the sort only fired on the initial load.
- **Rule:** Set `needsQualityResort = true` whenever quality scores are recomputed with valid star metrics, not just on first load.
- **Applies to:** TriageViewModel.recomputeQualityScores(), any re-cache scenario

## [2026-03-15] — SNR contribution misleading for trash frames
- **Mistake:** Showed "100% contribution" next to red X trash icon (frame had high SNR but was elongated)
- **Root cause:** SNR contribution measures noise floor only, not star quality. A frame with excellent SNR can still be trash due to elongation.
- **Rule:** Hide SNR contribution for trash-tier frames — their signal is irrelevant since they'd ruin the stack.
- **Applies to:** QualityEstimator.computeScores(), QualityBreakdown.snrContribution

## [2026-03-07] — cfitsio HAVE_NET_SERVICES must NOT be defined
- **Mistake:** Defined `HAVE_NET_SERVICES` as `0` in Package.swift, thinking `#ifdef` checks value
- **Root cause:** cfitsio uses `#ifdef HAVE_NET_SERVICES` (checks existence, not value). With the macro defined (even as 0), the root://, http://, ftp://, https:// drivers were compiled in. The `root_init()` callback returns -1 (XRootD not installed), causing `fits_init_cfitsio()` to bail BEFORE setting `need_to_initialize = 0`. Every subsequent `fits_open_file` re-triggered init, adding ~12 more drivers each time until overflow.
- **Rule:** Never define feature-toggle macros to `0` when the library uses `#ifdef` (not `#if`). Either define them (enabled) or don't define them at all (disabled).
- **Applies to:** cfitsio Package.swift cSettings, any C library feature macros

## [2026-03-07] — cfitsio MAX_DRIVERS set to 24 (was 31, then 80)
- **Mistake:** Bumped MAX_DRIVERS to 80 as a band-aid instead of finding the root cause
- **Root cause:** The real fix was removing HAVE_NET_SERVICES. Only 13 drivers register without network services.
- **Rule:** Don't increase limits as a workaround — find and fix the root cause of overflow/corruption
- **Applies to:** cfitsio cfileio.c, any resource limit issues

## [2026-03-07] — cfitsio threading: use ONE mechanism, not both
- **Original mistake:** Added `_REENTRANT` while ALSO keeping the external `std::mutex`, creating two conflicting lock mechanisms
- **Root cause:** `_REENTRANT` activates cfitsio's internal pthread locks (FFLOCK/FFUNLOCK). Mixing with an external mutex is redundant and wasteful.
- **Resolution (v0.9.8):** Enabled `_REENTRANT` and REMOVED the external mutex entirely. cfitsio's internal locks protect shared global state (file handle table, one-time init, decompression buffers). Different files can now be decoded concurrently.
- **Rule:** Use one serialization mechanism. Either external mutex OR library-internal locks, never both. For cfitsio, `_REENTRANT` is the correct choice when concurrent decode is needed.
- **Applies to:** cfitsio threading, Package.swift cSettings

## [2026-03-08] — Wrong iOS project edited (AstroViewer-iOS vs AstroFileViewer-iOS)
- **Mistake:** Spent time adding bin2/debayer features to `/Users/joergklaas/Desktop/claude-code/AstroViewer-iOS/` (old incomplete copy) instead of the real app at `AstroTriage-blinkV2/AstroFileViewer-iOS/`
- **Root cause:** Two similarly-named iOS projects existed. Didn't verify which one was the active TestFlight app before editing.
- **Rule:** Always confirm you're editing the correct project by checking bundle ID, existing features, or asking the user. The real iOS app is `AstroFileViewer-iOS/` inside the AstroTriage-blinkV2 repo.
- **Applies to:** Any multi-project workspace, iOS companion apps

## [2026-03-08] — iPhone 14 Pro Max produces wrong screenshot size for App Store 6.5"
- **Mistake:** Used iPhone 14 Pro Max simulator (1290×2796) for 6.5" App Store screenshots
- **Root cause:** iPhone 14 Pro Max resolution doesn't match any accepted size (1284×2778 or 1242×2688)
- **Rule:** Use iPhone 13 Pro Max (1284×2778) or iPhone 11 Pro Max (1242×2688) for 6.5" App Store screenshots
- **Applies to:** App Store screenshot requirements, iOS simulator selection

## [2026-03-08] — Metal texture size limit on iOS (8192px max in simulator)
- **Mistake:** Created full-resolution MTLTexture for 9576×6388 image, crashing on iOS simulator
- **Root cause:** iOS simulator (and some older devices) have 8192px max texture dimension
- **Rule:** Always check image dimensions against max texture size; use bin2 (half resolution) for display when exceeded. Add `binFactor` parameter to Metal shader for correct pixel mapping.
- **Applies to:** Metal compute shaders, iOS/iPadOS image display, large sensor cameras (ASI6200MM etc.)

## [2026-03-08] — Navigation wrap-around causes visual glitch with fast key repeat
- **Mistake:** Arrow key navigation wrapped from last→first image, causing the file list to jump unexpectedly during fast key repeat
- **Root cause:** Modulo wrap-around `(selectedIndex + 1) % images.count` triggers a large scroll jump when hitting the boundary, confusing the user
- **Rule:** Stop at boundaries instead of wrapping. Provide explicit jump keys (Page Up/Down, Home/End) for intentional first/last navigation.
- **Applies to:** List navigation with key repeat, NSTableView scroll behavior

## [2026-03-09] — ImageViewerView.updateNSView always debayered OSC images
- **Mistake:** `updateNSView` in `ImageViewerView.swift` always passed `bayerPattern` to `renderer.setImage()` without checking `debayerEnabled`, and used default `targetBackground` (0.25) instead of the user's stretch slider value.
- **Root cause:** SwiftUI calls `updateNSView` on every `@Published` property change. This re-invoked `setImage()` with the wrong parameters, overriding the debayer toggle and stretch settings that `displayCurrentImage()` or `updateStretchStrength()` had correctly applied moments before.
- **Rule:** In NSViewRepresentable `updateNSView`, always pass the FULL current state (debayerEnabled, stretchStrength, etc.) to renderer calls — never use hardcoded defaults. SwiftUI re-renders can override imperative state at any time.
- **Applies to:** NSViewRepresentable + Metal rendering, any SwiftUI wrapper around imperative view logic

## [2026-03-09] — clearImage with dummy MTKView
- **Mistake:** `toggleDebayer()` called `renderer?.clearImage(in: findMTKView() ?? MTKView())` — creating a dummy `MTKView()` as fallback which does nothing useful.
- **Root cause:** Copy-paste from early code. `clearImage` needs the actual MTKView to trigger `needsDisplay`.
- **Rule:** Never create dummy AppKit/UIKit views as fallbacks. Use `if let` guard and skip the call if the real view isn't available.
- **Applies to:** MetalRenderer API calls, any MTKView operations

## [2026-03-10] — vDSP on Swift Arrays: no .advanced(by:) method
- **Mistake:** Used `original.advanced(by: offset)` with vDSP functions, but Swift `[Float]` has no `.advanced` method (that's for UnsafePointer)
- **Root cause:** Confused pointer arithmetic (C-style) with Swift array operations
- **Rule:** Use `withUnsafeBufferPointer { buf in ... buf.baseAddress! + offset ... }` to get pointer offsets for vDSP calls on Swift arrays
- **Applies to:** Accelerate/vDSP operations, any C-bridged function expecting pointers with offsets

## [2026-03-10] — SwiftUI .help() tooltips unreliable in floating NSHostingView windows
- **Mistake:** Added `.help("tooltip text")` to small Text views in Session Overview — tooltips never appeared
- **Root cause:** `.help()` modifier has unreliable hit-testing on small frames inside NSHostingView in floating windows
- **Rule:** For explanatory content, use a dedicated help button (?) that opens an NSWindow with NSAttributedString rich text, or NSAlert for simple messages. Don't rely on `.help()` for important information.
- **Applies to:** SwiftUI tooltips, floating windows, NSHostingView

## [2026-03-10] — Duplicate method declarations from RA/DEC parsing
- **Mistake:** Added new `parseRA`/`parseDec` methods in TriageViewModel, but they already existed in the Auto Meridian section
- **Root cause:** Large file, didn't search for existing methods first
- **Rule:** Always grep for existing method names before adding new ones in large files. Reuse existing utility methods.
- **Applies to:** TriageViewModel.swift, any large Swift class files

## [2026-03-10] — Swift abs/sqrt/cos ambiguity with tuples
- **Mistake:** `abs(coord.ra - refRA)` caused "ambiguous use of abs" compile error
- **Root cause:** Swift can't disambiguate between Foundation.abs and Swift.abs when used with tuple member access
- **Rule:** Use `Swift.abs()` explicitly and `.squareRoot()` method instead of global `sqrt()` to avoid ambiguity
- **Applies to:** Math operations on tuple/struct members in Swift

## [2026-03-07] — NSTableView multi-selection destroyed by updateNSView
- **Mistake:** `updateNSView` was calling `selectRowIndexes(byExtendingSelection: false)` on every SwiftUI update, replacing multi-selection with single selection
- **Root cause:** `reloadData()` clears selection, then the sync code only restored a single row
- **Rule:** Save and restore selection across `reloadData()`. Only override selection when table has ≤1 rows selected (programmatic navigation).
- **Applies to:** NSViewRepresentable + NSTableView interaction

## [2026-03-10] — Duplicate engine code: use protocol or keep separate V2 views
- **Decision:** Created separate QuickStackV2ProgressView + StackResultViewV2 rather than refactoring V1 views with generics/protocols
- **Root cause:** SwiftUI @ObservedObject requires concrete ObservableObject types, making protocol-based generics awkward
- **Rule:** When adding a V2 engine with identical @Published interface, duplicate the SwiftUI views (typed to V2) rather than over-engineering a protocol. If V2 replaces V1, delete the V1 views entirely.
- **Applies to:** QuickStackWindow.swift, any SwiftUI view paired with an ObservableObject engine

## [2026-03-10] — Toolbar icon alignment: use Spacer + fixed frame height
- **Decision:** Icons at top, Spacer pushes labels to bottom, fixed height 48pt, multiline labels
- **Rule:** For toolbar buttons with varying label lengths, use VStack { Icon; Spacer; Text } with .fixedSize(horizontal: false, vertical: true) and lineLimit(2)
- **Applies to:** sfToolbarButton in ContentView.swift

## [2026-03-13] — XcodeGen test target: DEVELOPMENT_TEAM + TEST_HOST + PRODUCT_MODULE_NAME
- **Mistake:** Test target failed with 3 different errors sequentially: (1) "no such module AstroTriage" because PRODUCT_MODULE_NAME defaulted to PRODUCT_NAME (AstroBlinkV2), (2) TEST_HOST pointed to AstroTriage.app instead of AstroBlinkV2.app, (3) "different Team IDs" because test target had no DEVELOPMENT_TEAM
- **Root cause:** XcodeGen derives PRODUCT_MODULE_NAME from PRODUCT_NAME, not the target name. When PRODUCT_NAME differs from target name, `@testable import` breaks.
- **Rule:** When target name ≠ product name, set PRODUCT_MODULE_NAME explicitly on the main target. Set DEVELOPMENT_TEAM on test target. Set TEST_HOST to actual product name. Put test target in scheme `test:` section only (not `build:`).
- **Applies to:** project.yml test target config, any XcodeGen project with PRODUCT_NAME override

## [2026-03-14] — vDSP_vsadd: use [scalar] not &scalar
- **Mistake:** Used `var negMed = -median; vDSP_vsadd(devs, 1, &negMed, ...)` — passing pointer to a scalar instead of array literal
- **Root cause:** vDSP_vsadd's scalar parameter expects `UnsafePointer<Float>` which works with both `&var` and `[literal]`, but `&var` on stack can be optimized away, giving undefined behavior in some contexts
- **Rule:** Always use `[scalar]` array literal syntax for vDSP scalar parameters: `vDSP_vsadd(arr, 1, [negMedian], &out, 1, count)`. Match STFCalculator.swift pattern.
- **Applies to:** Any vDSP call with scalar parameter (vsadd, vsmul, etc.)

## [2026-03-14] — Metal texture RGBA vs BGRA in PNG export
- **Mistake:** Assumed all textures were BGRA and always swapped R/B channels in saveAsPNG
- **Root cause:** restretch_float shader writes float4(r,g,b,1) into .rgba8Unorm textures, but stacking engine uses .bgra8Unorm for result textures
- **Rule:** Check `tex.pixelFormat == .bgra8Unorm` before swapping channels. Only swap for BGRA textures.
- **Applies to:** Any PNG/image export from Metal textures

## [2026-03-14] — Initial sort blocked by saved UserDefaults column order
- **Mistake:** Quality-based re-sort after precache was guarded by `AppSettings.columnOrder == nil` — if user ever manually dragged a column, the sort never fired
- **Root cause:** Saved column order (visual layout) and sort key derivation were conflated. Column positions should be independent of sort logic.
- **Rule:** Sort keys should always use the recommended column order (based on session type), not saved visual layout. Saved order only controls column positions.
- **Applies to:** Any feature that auto-sorts after async data becomes available, plus timing of @Published snapshots in updateNSView

## [2026-03-14] — NSTableView cell bounds.width is 0 on first layout
- **Mistake:** Used `cellView.bounds.width` to compute metric bar width — returns 0 before first layout pass, causing bars to "grow" when selected
- **Root cause:** NSTableCellView bounds aren't set until the view is laid out. First render has zero bounds.
- **Rule:** Use proportional constraints (`widthAnchor.constraint(equalTo: parent.widthAnchor, multiplier:)`) instead of fixed widths based on bounds.
- **Applies to:** Any NSTableView cell with dynamic-width subviews

## [2026-03-13] — Calibration filter: substring matching causes false positives on target names
- **Mistake:** `isCalibration()` used `filename.lowercased().contains("dark")` which falsely excluded targets like "Dark Nebula" and "Flat Rock Galaxy"
- **Root cause:** Substring matching on full filenames doesn't distinguish between calibration frame types and target names containing calibration keywords
- **Rule:** For filename-level calibration detection, parse the frame type token (LIGHT/DARK/FLAT/BIAS) via NINAFilenameParser first. Only fall back to substring matching for non-NINA filenames. Folder-level detection can safely use substring matching.
- **Applies to:** SessionScanner.swift, any calibration frame detection logic

## [2026-03-17] — GPU star detection buffer overflow causes left-biased star positions
- **Mistake:** `maxGPUCandidates = 512` was too small. GPU threads execute in tile order (left-to-right), so the buffer filled up with only left-side stars. Increased to 4096, then again to 16384 for L-band images with 6000+ peaks.
- **Root cause:** Metal compute threads are dispatched in threadgroup order. With atomic_fetch_add into a fixed-size buffer, early threadgroups (left side) fill it before right-side threads execute.
- **Rule:** GPU candidate buffers must be sized for the WORST CASE (densest star field), not average. L-band broadband images can have 10,000+ peaks. Use at least 16384.
- **Applies to:** PreviewGenerator.detectStarsGPU, any GPU kernel with atomic append to fixed buffer

## [2026-03-17] — Stacking false triangle matches produce ghost images
- **Mistake:** Minimum inlier threshold was 3, allowing coincidental matches with 73-166° rotation and 0.6-3.8x scale to pass through. Only validated scale on one axis.
- **Root cause:** With sparse star fields (M81), false triangle matches can have 3-5 coincidental inliers. Need ≥6 to reliably reject false positives.
- **Rule:** Require ≥6 initial inliers AND ≥5 refined inliers (4px). Validate scale on BOTH axes. Don't restrict rotation — let inlier counting do the rejection.
- **Applies to:** QuickStackEngineV2.matchTrianglesHashed, QuickStackEngine.solveAffine

## [2026-03-18] — FITS/XISF header string values include single quotes
- **Mistake:** Used header values directly (e.g., `String(dateStr.prefix(10))`) without stripping FITS single quotes. `'2026-03-18T...'` → prefix(10) = `'2026-03-1` (quote eats a character). Filter `'L'` broke matching.
- **Root cause:** C bridge returns FITS string values verbatim with surrounding single quotes. `readHeaders` only trimmed whitespace, not quotes.
- **Rule:** Always strip surrounding single quotes from FITS/XISF header values at the source (`readHeaders`). Never assume header string values are clean.
- **Applies to:** MetadataExtractor.readHeaders, any FITS/XISF header value usage

## [2026-03-18] — Satellite trail detection needs collinear pattern matching, not per-pixel shape
- **Mistake:** Tried per-star axisRatio check at 5px aperture to detect trail segments. Trail segments look like slightly elongated blobs at small apertures (axisRatio 0.15-0.30), passing the threshold.
- **Root cause:** Shape analysis measures local morphology. A satellite trail is a global geometric pattern (collinear points), not a local shape feature.
- **Rule:** Detect satellite trails via RANSAC collinear point detection on star positions (≥8 points within 5px of a line, spanning ≥15% of image diagonal). Remove trail detections BEFORE any metric measurement.
- **Applies to:** StarMetricsCalculator, any satellite/streak detection

## [2026-03-18] — Session overview callbacks must be wired in ALL load paths
- **Mistake:** `wireSessionOverviewCallbacks()` only called in `openFolder()`. Sessions loaded via `loadSession()`, `loadFiles()`, `loadMultipleFolders()` had nil callbacks → clicks did nothing.
- **Root cause:** Only tested the primary load path, not all entry points.
- **Rule:** Any setup that must happen for every session load should go in all load methods, or be called from a shared setup function.
- **Applies to:** TriageViewModel session loading, any session-level initialization

## [2026-03-17] — NSView star overlay coordinates must match Metal drawable ratio
- **Mistake:** Divided effScale by backingScaleFactor (bs=2) which halved circle positions on Retina. Then removed /bs entirely which doubled them. The correct factor is drawableW/viewW.
- **Root cause:** Metal NDC coordinates map to the drawable (which may or may not be Retina-scaled). The overlay NSView works in view points. The ratio between drawable pixels and view points determines the correction factor.
- **Rule:** Use `drawableRatio = drawableW / viewW` for the scale correction, not hardcoded backingScaleFactor. Also apply bs/drawableRatio to pan offset for consistent tracking.
- **Applies to:** CompareWindow.swift StarOverlayView.draw(), any NSView overlay on MTKView

## [2026-03-18] — NSWindow EXC_BAD_ACCESS on close without isReleasedWhenClosed
- **Mistake:** Created NSWindow for Color Combine result without `window.isReleasedWhenClosed = false`. Crashed with `objc_release` in `_NSWindowTransformAnimation dealloc` when closing.
- **Root cause:** NSWindow created as a local variable has no strong reference. ARC deallocates it, but the close animation still holds a dangling reference.
- **Rule:** Always set `window.isReleasedWhenClosed = false` on programmatically created NSWindows. Follow the LightspeedStacker result window pattern.
- **Applies to:** Any NSWindow created in a function scope (ColorCombineWindow, QuickStackWindow)

## [2026-03-18] — SwiftUI Slider trailing closure vs onEditingChanged
- **Mistake:** Used `Slider(value:in:step:) { editing in ... }` thinking the trailing closure was `onEditingChanged`. It was interpreted as the `label` closure, so the callback never fired.
- **Root cause:** `Slider` has multiple initializers. The trailing closure maps to `label:` not `onEditingChanged:`.
- **Rule:** Always use the explicit named parameter: `Slider(value:in:step:onEditingChanged: { editing in ... })`. Never rely on trailing closure disambiguation for Slider.
- **Applies to:** SwiftUI Slider with onEditingChanged callback
