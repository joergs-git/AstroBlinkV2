# Lessons Learned

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

## [2026-03-07] — NSTableView multi-selection destroyed by updateNSView
- **Mistake:** `updateNSView` was calling `selectRowIndexes(byExtendingSelection: false)` on every SwiftUI update, replacing multi-selection with single selection
- **Root cause:** `reloadData()` clears selection, then the sync code only restored a single row
- **Rule:** Save and restore selection across `reloadData()`. Only override selection when table has ≤1 rows selected (programmatic navigation).
- **Applies to:** NSViewRepresentable + NSTableView interaction
