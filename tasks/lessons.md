# Lessons Learned

## [2026-03-28] — iCloud container access blocks main thread for 10-30s
- **Mistake:** `FrameHistoryDatabase.init()` called `FileManager.url(forUbiquityContainerIdentifier:)` synchronously. App hung with spinning beachball on launch and during tests.
- **Root cause:** Apple's iCloud container resolution can take 10-30+ seconds on first call, especially if iCloud Drive is syncing or has connectivity issues. Same issue existed in CalibrationDatabase but was masked by lazy singleton init.
- **Rule:** Never call `url(forUbiquityContainerIdentifier:)` synchronously on main thread or in `init()`. Resolve asynchronously via `DispatchQueue.global().async` and use the result only when ready (`nil` until resolved = skip iCloud silently).
- **Applies to:** Any singleton that accesses iCloud containers, app startup code, test host initialization

## [2026-03-28] — SwiftUI Charts crashes on empty KeyValuePairs
- **Mistake:** `chartForegroundStyleScale` passed empty `KeyValuePairs<String, Color>` → `EXC_BREAKPOINT` crash in Charts framework `Sequence.reduce(into:)`.
- **Root cause:** SwiftUI Charts doesn't handle empty color scales. Our dynamic filter color builder returned `[:]` as placeholder.
- **Rule:** Never pass empty `KeyValuePairs` to `chartForegroundStyleScale`. Either build a non-empty literal, or use `foregroundStyle()` directly per mark with explicit colors.
- **Applies to:** Any SwiftUI Charts color scale configuration

## [2026-03-28] — Archive scanner GPU operations need .userInitiated QoS
- **Mistake:** Archive scanner ran at `.utility` QoS. GPU star detection via Metal compute hung — 0 files processed after 5 minutes.
- **Root cause:** Metal GPU dispatch on `.utility` threads gets deprioritized by the system. Star detection pipeline needs P-core scheduling to complete in reasonable time.
- **Rule:** Any code path that uses Metal compute (star detection, STF, GPU preview) must run at `.userInitiated` or higher QoS. Use `.utility` only for pure I/O or CPU-light work.
- **Applies to:** ArchiveScanner, PrefetchCache, any background GPU task

## [2026-03-28] — Skip app startup init in test host
- **Mistake:** Test host app ran `applicationDidFinishLaunching` including DB init, iCloud sync, splash screen — blocking test execution.
- **Root cause:** `xcodebuild test` launches the app as TEST_HOST. All startup code runs before tests.
- **Rule:** Guard heavy startup code with `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil` to skip when running as test host.
- **Applies to:** AstroTriageApp.swift, any app delegate startup code

## [2026-03-27] — Z-scores normalize away uniformly bad groups — need cross-group sanity
- **Mistake:** January night of M82 with FWHM 9-11, SNR 6-9 rated "Good" because all frames in the group were equally bad. Z-scores normalized to zero within the group.
- **Root cause:** Z-scores are purely group-relative. When ALL frames in a group are bad, the median IS bad, and no frame is an outlier. Stage 1 garbage rules (R2/R3) also use group medians.
- **Rule:** Always have a cross-group sanity check (Stage 1.5) that compares absolute metrics against the session's best decile (P10/P90). Use the best 10% as the "good" baseline, not the median. Require multi-group pools (≥2 filter/night combos) to avoid false positives in single-group sessions.
- **Applies to:** QualityEstimator, any relative scoring system, multi-night sessions

## [2026-03-27] — Compare "best" must search across groups when group best is also garbage
- **Mistake:** Compare with Best showed a garbage January R frame as "best" when comparing a garbage January G frame. Both were from the same bad night.
- **Root cause:** Best selection was limited to same filter+target+exposure group. When the entire group is bad, the "best" is just the least-bad garbage.
- **Rule:** When group best is below .good tier, widen search: first try same target+exposure across all filters, then same target with any filter/exposure. Always show a genuinely good reference if one exists anywhere in the session.
- **Applies to:** CompareWindow, any "best frame" selection logic

## [2026-03-27] — Satellite trail RANSAC fires false positives on extended objects
- **Mistake:** RANSAC collinear detection (8-point minimum) triggered on galaxy knots in edge-on galaxies like M82, dropping star count from ~1150 to ~183 via `correctedTotal = filtered.count` (center-crop only, not comparable to full-image GPU count).
- **Root cause:** Galaxy structure creates 8+ collinear bright regions within 5px tolerance. The count correction used center-crop-only count (apples) vs full-image count (oranges). No shape verification on trail candidates.
- **Rule:** After RANSAC trail detection, always verify candidates have streak-like axis ratios (< 0.3). Normal stars/galaxy knots have ratio > 0.3. Never replace full-image count with center-crop count — subtract trail detections instead.
- **Applies to:** StarMetricsCalculator, any collinear detection, star count pipeline

## [2026-03-27] — Hardcoded version strings in UI create drift
- **Mistake:** "What's New in v4.0.0" button label was hardcoded but release notes data was already at v5.3.0.
- **Root cause:** Version string in button label was set once and never updated during subsequent releases.
- **Rule:** Never hardcode version numbers in UI button labels. Use version-agnostic text ("What's New") and let the data array be the single source of truth.
- **Applies to:** Any UI text referencing version numbers, release notes, about screens

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

## [2026-03-29] — GRDB migration names are immutable
- **Mistake:** Renamed migration `v4_bortle_and_canonical_target` to `v5_` when inserting a new migration before it. App crashed on launch with assertion failure.
- **Root cause:** GRDB tracks applied migrations by name. Renaming a previously applied migration means GRDB can't find it → assertion failure.
- **Rule:** NEVER rename or reorder existing GRDB migrations. Always add new migrations AFTER the last one with incrementing version numbers.
- **Applies to:** FrameHistoryDatabase.swift, any GRDB migration code

## [2026-03-29] — Archive Scanner must exclude calibration frames via full path check
- **Mistake:** ArchiveScanner only checked exact folder names and filename prefixes for calibration detection. Missed "FlatWizard" in folder names and "FLAT" in mid-filename. 1,792 calibration frames entered the DB.
- **Root cause:** ArchiveScanner had its own exclusion logic instead of reusing SessionScanner's proven `isFileCalibration()` / `isFolderCalibration()`.
- **Rule:** Always use `SessionScanner.isFileCalibration()` for calibration detection — it handles NINA token parsing + keyword fallback. Also check full parent path for calibration keywords in ANY ancestor folder.
- **Applies to:** ArchiveScanner.swift, any file scanning code

## [2026-03-18] — SwiftUI Slider trailing closure vs onEditingChanged
- **Mistake:** Used `Slider(value:in:step:) { editing in ... }` thinking the trailing closure was `onEditingChanged`. It was interpreted as the `label` closure, so the callback never fired.
- **Root cause:** `Slider` has multiple initializers. The trailing closure maps to `label:` not `onEditingChanged:`.
- **Rule:** Always use the explicit named parameter: `Slider(value:in:step:onEditingChanged: { editing in ... })`. Never rely on trailing closure disambiguation for Slider.
- **Applies to:** SwiftUI Slider with onEditingChanged callback

## [2026-04-01] — Flat narrowband trailing multiplier makes garbage thresholds unreachable
- **Mistake:** Used flat 0.3× multiplier for narrowband trailing penalties. Garbage threshold became 0.7/0.3=2.33, but trailing score is capped at 1.0. Severe trailing on Ha/OIII/SII could NEVER be detected.
- **Root cause:** The code even acknowledged it: "effectively disabling trailing garbage for Ha/OIII/SII since score is capped at 1.0". The original rationale (mild trailing OK for narrowband) was valid but the flat multiplier was too aggressive.
- **Rule:** When dividing thresholds by a multiplier, always verify the resulting threshold is REACHABLE by the input value range. Use severity-dependent escalation instead of flat scaling when the metric has bounded range.
- **Applies to:** QualityEstimator trailing rules, any threshold logic with divisors

## [2026-04-01] — FWHM cross-check blocks legitimate tracking error detection
- **Mistake:** Rule 6a (absolute trailing ceiling) was blocked by `fwhmRulesOutTrailing` — frames with normal FWHM but severe trailing were not flagged.
- **Root cause:** Tracking error produces normal FWHM (good seeing) + high eccentricity (mount drift). The FWHM cross-check was designed for optical aberrations but blocks the most common trailing scenario.
- **Rule:** For trailing rules with consensus check, don't block on FWHM. Consensus (stars elongated in same direction) is the definitive guard against false positives — optical aberrations produce random PA, not consensus.
- **Applies to:** QualityEstimator Rule 6a, any future trailing detection rules

## [2026-04-02] — Dark frame detection must not contaminate group statistics
- **Mistake:** Rule 0b detected dome frames as garbage, but their extreme metrics (17000 stars, FWHM 3, SNR 113) stayed in the group median/z-score computation. Real frames scored as trash because the median was the dome value.
- **Root cause:** Group statistics (medians, z-scores) were computed from ALL frames including detected garbage. When dome frames outnumber real frames, the median IS the dome value.
- **Rule:** Detect dark frames in a PRE-PASS before computing group statistics. Null out their metrics in cleaned arrays. Also exclude Stage 1 garbage from session sanity P10/P90 benchmarks.
- **Applies to:** QualityEstimator pre-pass, session sanity benchmark collection, any group-relative scoring

## [2026-04-02] — Session sanity must require multi-night for cross-filter comparison
- **Mistake:** Session sanity compared NGC7000 Ha (FWHM 8) against OIII (FWHM 4) and flagged all Ha as "FWHM far above session norm." Single-night, multi-filter.
- **Root cause:** Different filters can have legitimately different FWHM. Session sanity was designed for multi-NIGHT comparison (catching bad nights), not cross-filter within one night.
- **Rule:** Require ≥2 distinct observing nights before session sanity fires. Single-night filter differences are optics, not bad data.
- **Applies to:** QualityEstimator sessionSanityCheck, any cross-group comparison

## [2026-04-02] — replace_all edits may miss code paths with different formatting
- **Mistake:** `replace_all` for `StarMetricsCalculator.measure(` with `generator: generator` parameter only caught 2 of 3 call sites in PrefetchCache. The third had slightly different indentation/context.
- **Root cause:** `replace_all` matches exact strings. If code paths have slightly different formatting, some are missed.
- **Rule:** After replace_all on function calls, grep for ALL call sites and verify each one manually.
- **Applies to:** Any replace_all edit on function signatures, especially in files with multiple code paths

## [2026-04-01] — PrefetchCache skips metric callbacks for cached frames
- **Mistake:** PrefetchCache.prefetchAll() had TWO skip checks (line 271 snapshot + line 289 thread-safe) that skipped entire pipeline including metric callbacks for already-cached frames. Quality scoring ran without metrics for those frames.
- **Root cause:** The "cached" check only considers preview textures, not whether star metrics and noise stats were delivered. Separate MainActor Tasks for different frames can execute out of order.
- **Rule:** When skipping cached items in a pipeline, check if ALL required outputs were delivered, not just the primary output (texture). Use a `needsAnalysis` set for frames that need re-processing. Also add delayed rescore retry to catch MainActor Task delivery races.
- **Applies to:** PrefetchCache.swift, TriageViewModel scoring triggers

## [2026-04-03] — FITS decoder must check BITPIX before choosing read datatype
- **Mistake:** FITS decoder always read pixel data as TUSHORT (unsigned 16-bit integer). Float FITS files (BITPIX=-32 from APP/GraxPert, BITPIX=-64 from PixInsight) have values in [0.0, 1.0] range. Reading float 0.5 as uint16 truncates to 0 — all-black images.
- **Root cause:** The original decoder was written for NINA output only, which always writes 16-bit integer FITS. When users processed files through Astro Pixel Processor, PixInsight, or GraxPert, the output was float32/float64 FITS — a format the decoder silently misread.
- **Rule:** Always check the BITPIX keyword before choosing the cfitsio read datatype. BITPIX=16/32 → TUSHORT, BITPIX=-32/-64 → TFLOAT. For float data, auto-detect value range: if max <= 1.0, scale by 65535; if max > 1.0, assume pre-scaled. This applies to BOTH macOS and iOS decoders — they share the same C bridge code pattern but are separate source files.
- **Applies to:** ImageDecoderBridge.cpp (both Packages/ImageDecoder/ and AstroFileViewer-iOS/Packages/ImageDecoder/), any FITS reading code

## [2026-04-02] — SwiftUI on macOS blocks ALL external event delivery for cross-process IPC
- **Mistake:** Registered `astroblink://` URL scheme for PixInsight Bridge integration. URL scheme registered correctly in Info.plist and macOS resolved it, but SwiftUI's @NSApplicationDelegateAdaptor silently swallowed the `application(_:open:)` callback. The app never received the URL.
- **Root cause:** SwiftUI on macOS intercepts and blocks virtually all external event delivery mechanisms: custom URL schemes, Apple Events, file open events via `application(_:openFile:)`, DistributedNotificationCenter observers, UserDefaults written by external processes (KVO never fires), and `applicationDidBecomeActive` notifications from external activation. This is a known SwiftUI lifecycle issue with @NSApplicationDelegateAdaptor where the SwiftUI app lifecycle takes precedence over AppKit delegate methods.
- **Rule:** For cross-process IPC in a SwiftUI macOS app, the only reliable mechanism is clipboard marker + Timer polling. Write a known marker string to NSPasteboard from the external process, and poll for it with a Timer in the SwiftUI app (e.g. every 0.5s). Do NOT rely on URL schemes, Apple Events, DistributedNotifications, or any other standard macOS IPC — they all fail silently under SwiftUI.
- **Applies to:** Any macOS SwiftUI app needing to receive data from external processes, PixInsight Bridge, automation scripts, inter-app communication

## [2026-04-03] — GroupKey FL-bucketing broke trailing detection in uniformly bad groups
- **Mistake:** Added focal length to GroupKey to prevent cross-setup scoring (RASA vs RC12). This split M82 January (FL 2455mm) from March (FL possibly different) into separate groups. January group was ALL bad trailing — z-scores normalized, trailing outlier guard prevented detection. Dozens of obvious trailing garbage frames escaped as "Good".
- **Root cause:** FL-bucketing was added to GroupKey AND PoolKey (session sanity). When the session sanity pool also required FL match, it couldn't cross-compare bad January data against good March data from a different FL.
- **Rule:** GroupKey SHOULD include FL (scoring must not compare different plate scales). But session sanity PoolKey must NOT include FL — session sanity exists specifically to catch uniformly bad groups by cross-comparing against the session's best data, even from different setups. Always run the ScoringRegressionTests (especially testM82_JanuaryTrailingFramesMustBeDetected) before presenting scoring changes.
- **Applies to:** QualityEstimator GroupKey/PoolKey, any change to group composition logic

## [2026-04-05] — VLM relative comparison fails for majority-affected anomalies
- **Mistake:** VLM was asked to compare each frame against the "majority" to detect anomalies like ice/dew. When >50% of frames had ice, the iced frames became the baseline and clean frames were flagged as anomalous.
- **Root cause:** "Compare to majority" assumes the majority is clean. Ice/dew can affect the majority of a session (e.g., dew builds up and stays).
- **Rule:** Use deviation maps (pixel-by-pixel median comparison) + absolute anomaly checks instead of relative "compare to majority" prompting. Deviation maps surface structural differences regardless of which group is larger.
- **Applies to:** VisualAnomalyDetector, any VLM-based anomaly detection, any relative comparison approach

## [2026-04-05] — Nebula filaments confused with satellite trails by VLM
- **Mistake:** Claude Vision mistook emission nebula structure (filaments, bright ridges) for satellite trails, flagging clean narrowband frames as contaminated.
- **Root cause:** VLM prompt included satellite trail detection. Nebula filaments and satellite trails share visual characteristics (bright linear structures on dark background).
- **Rule:** Remove satellite detection from VLM entirely — it is already handled by TrailingAnalyzer metrics which use star position analysis, not visual appearance. Add explicit warning in VLM prompt about astronomical object structure (nebula filaments, galaxy arms) not being artifacts.
- **Applies to:** VisualAnomalyDetector prompt engineering, VLM Edge Function, any visual inspection of astronomical images

## [2026-04-05] — "Flag aggressively" causes VLM over-flagging
- **Mistake:** VLM prompt instructed "flag aggressively, false positives acceptable" and "flag ALL frames from first ice appearance." Model interpreted this as marking nearly everything suspicious.
- **Root cause:** Aggressive language in prompts combined with temporal propagation rules ("all frames after first ice") caused the model to cascade flags across the entire session.
- **Rule:** Instruct VLM to "evaluate EACH tile on its own visual evidence." Never use temporal propagation rules like "flag all after first detection" — ice/dew can come and go (dew heater cycles). Keep prompt language neutral: describe what to look for, not how aggressively to flag.
- **Applies to:** VisualAnomalyDetector prompt, any VLM prompt for sequential frame analysis

## [2026-04-05] — anthropic-version 2025-04-15 does not exist
- **Mistake:** Specified `anthropic-version: 2025-04-15` in Supabase Edge Function, assuming a newer API version existed. Request failed.
- **Root cause:** Assumed API versions follow a predictable date pattern. They don't — only specific published versions exist.
- **Rule:** Extended thinking works with the standard `2023-06-01` API version. Don't invent API version strings. Always verify against the Anthropic API documentation.
- **Applies to:** Supabase Edge Functions calling Claude API, any direct Anthropic API integration

## [2026-04-05] — 5MB image limit is per-image, not total
- **Mistake:** Assumed 5MB base64 limit was shared across all images in a single API call. Halved the budget per image when sending 2 images (reference + candidate), resulting in unnecessary quality loss.
- **Root cause:** Misread the API documentation. Claude API allows 5MB base64 per individual image, independently.
- **Rule:** Each image in a Claude API call has its own independent 5MB base64 limit. Don't reduce quality of individual images based on how many images are in the request.
- **Applies to:** VisualAnomalyDetector image preparation, any multi-image Claude API call

## [2026-04-05] — Heat map colors compress poorly in JPEG
- **Mistake:** Deviation map heat maps (red/yellow/green gradients) needed aggressive JPEG compression (quality 0.35 or 50% resize) to fit under the 5MB API limit. Initial attempts at moderate quality exceeded the limit.
- **Root cause:** Colorful images with gradients have high entropy — JPEG compression is far less effective on color heat maps than on grayscale astronomical images.
- **Rule:** Budget for aggressive compression when sending colorful visualizations (heat maps, deviation maps) to the API. Grayscale compresses ~3-5x better than color at the same quality. Consider 50% resize + quality 0.35 as a starting point for heat maps. Alternatively, consider grayscale encoding if color is not essential for interpretation.
- **Applies to:** MosaicGenerator deviation maps, any colorful visualization sent to Claude API

## [2026-04-03] — R0b Path B false positive on low-gain narrowband (L-eXtreme)
- **Mistake:** R0b Path B (stars >= 5000 AND bg < 0.003) flagged real NGC 7635 frame as "dome/cap". Frame had 5185 real stars with L-eXtreme filter at GAIN 10 on 620mm wide-field.
- **Root cause:** Low gain (10) + dual-narrowband filter produces very low background (< 0.003 normalized). The 5000-star threshold was calibrated for gain 100+ where background is naturally higher. Wide-field setups also detect more stars than long FL.
- **Rule:** R0b Path B star threshold must be FL-dependent: wide FOV sees more real stars, so threshold must be higher. Background threshold tightened from 0.003 to 0.002 (real dark frames are always < 0.001). Formula: `7500 * (1000/FL)^2`, clamped [5000, 10000].
- **Applies to:** QualityEstimator R0b, any dark frame detection logic, low-gain imaging setups

## [2026-04-04] — Supabase JSON integers break Swift Codable Double fields
- **Mistake:** `CatalogTarget` struct used `Codable` auto-synthesis with `Double?` fields. Supabase returns integers for whole numbers (6 not 6.0), causing `DecodingError.typeMismatch`.
- **Root cause:** Swift's `JSONDecoder` strictly matches number types. A JSON `6` decodes as Int but not Double.
- **Rule:** For any struct decoded from Supabase REST JSON, use a custom `init(from:)` with flexible number decoding: try Double first, then Int, convert. Never rely on auto-synthesis for numeric fields.
- **Applies to:** TargetCatalogService.CatalogTarget, any Supabase-backed Codable struct

## [2026-04-04] — base64-prefix cache keys collide for similar URLs
- **Mistake:** DSS thumbnail disk cache used `base64EncodedString().prefix(64)` of the URL as filename. All DSS URLs share the same base64 prefix (same domain/path), so different targets got the same cache file.
- **Root cause:** base64 is not a hash — similar inputs produce similar outputs. Truncating to 64 chars lost the unique part (coordinates at the end).
- **Rule:** For URL-based cache keys, extract the unique identifying parts (e.g. RA/Dec coordinates) directly, or use a proper hash (SHA256). Never truncate base64 as a cache key.
- **Applies to:** Any disk cache keyed by URL

## [2026-04-04] — SwiftUI List Section headers create gray gap above data
- **Mistake:** Put column headers as a VStack item above a SwiftUI `List`, creating a large gray dead zone between headers and first row.
- **Root cause:** SwiftUI `List` has internal padding/chrome that can't be removed from outside.
- **Rule:** Put column headers as a pinned `Section(header:)` inside the List, not outside it. Use `.textCase(nil)` to prevent uppercase transformation.
- **Applies to:** Any SwiftUI List with custom column headers

## [2026-04-04] — Filter gap indicator should not show for never-imaged targets
- **Mistake:** Gap icon showed for all targets missing filter data, including never-imaged ones. User feedback: "doesn't make sense to show gap for targets not shot at all."
- **Root cause:** Original logic treated `history == nil` as a gap. But "never imaged" is different from "imaged but imbalanced."
- **Rule:** Filter gap indicators and the "Has filter gap" toggle should require `history != nil`. A gap means "you started this target but some filters are underserved" — not "you haven't started yet."
- **Applies to:** TargetDatabaseViewModel, TargetDatabaseWindow filter gap logic

## [2026-04-06] — VLM (LLM Vision) cannot reliably detect instrumental artifacts in astro subs
- **Mistake:** Assumed Claude Vision and other LLMs could detect ice/frost/dust shadows in auto-stretched astro sub-exposure mosaics. Tried 4+ prompt strategies (prescriptive categories, open-ended comparison, invariance-based analysis) and multiple LLM systems.
- **Root cause:** (1) Auto-stretch normalizes each tile independently, reducing contrast of ice shadows. (2) LLMs latch onto the most visually obvious difference (e.g. twilight brightness) rather than subtle instrumental patterns. (3) When >50% of frames have a defect, it becomes "normal" to the model. (4) Median-based computational analysis also fails when the median itself is contaminated by the majority of affected frames.
- **Rule:** VLM-based visual anomaly detection for astronomical sub-exposures is not production-ready. Mark it ALPHA and warn users. For reliable ice/frost detection, analyze raw pixel data in the scoring pipeline (before auto-stretch), not post-stretch mosaic tiles. Star count is the best metadata proxy for optical cleanliness (ice reduces visible stars).
- **Applies to:** VLM Check feature, any future AI-based visual quality assessment, MosaicGenerator center-detection algorithm
