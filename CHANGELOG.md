# Changelog

All notable changes to AstroBlink & AIsaac will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [5.26.1] — 2026-04-18

### Added
- **Floating Image Overlay** — Top-left overlay on the image viewer with four pieces stacked vertically: large filter letter (Ha / L / OIII / …), capture time + observing-night date, a 5%-size mini-map of the full image, and the current 1-3 star rating (1★ = outline, 2/3★ = filled; all monochrome white). Anchored in viewport space so it stays pinned during zoom and pan. Default on for new installs (persisted via AppSettings + iCloud); toggle with ⌘⇧O or View → Show Image Overlay. Auto-enabled on entering Blind Curation, restored to prior state on exit.
- **Live Viewport Indicator** — A thin white dashed rectangle (2pt dashes, 1pt gaps) on the mini-map tracks the currently-visible sub-region of the full image in real time while you zoom and pan the main viewer. Hides automatically when the whole image fits (no cropping). Works with click-drag zoom, ⌥-drag pan, and scroll-wheel pan.

### Fixed
- **Mini-map thumbnail SIGSEGV on AGX** — The direct `MTLTexture.getBytes` readback path crashed inside `agxsTwiddleAddressCommon` when the display texture used a GPU-private tile-swizzled layout. Thumbnail generation now goes through CoreImage (`CIImage` + `CIContext.createCGImage`) which handles storage-mode translation and detiling internally.
- **Viewport indicator Y sign / pan lag** — Initial implementation used the wrong sign for Y (indicator showed a position above the actual visible region) and only refreshed on zoom, not on pan or scroll. Both are now corrected: viewport center derives from `renderQuad`'s NDC convention (panOffset.y is negated in NDC, so both X and Y use `0.5 - panOffset/(imgDim·effScale)`), and the pan-drag and scroll-wheel paths now refresh the indicator live.

---

## [5.26.0] — 2026-04-18

### Fixed
- **Stage 1.5 Severe-FWHM False Positives (Algorithm v23)** — The Stage 1.5 session-sanity check's single-flag "severe FWHM" demote path has been removed after empirical validation against 4540 user-rated frames from the Frame History DB. That path uniquely fired on frames where FWHM was the only flag at ~34% precision — 65 false positives for every 33 true catches. Genuinely bad frames still fail multiple metrics simultaneously and are caught by the 2-flag rule. Net impact: +32 frames correctly classified on the curated set; the biggest wins expected on broadband sessions with moderate-seeing nights that previously got over-aggressively demoted.
- **Stage 4 FWHM-Rescue Preserves Session-Sanity Reasons** — When a frame demoted by Stage 1.5 or Stage 1.5b (historical baseline) has FWHM within the good-frame 90th percentile and gets rescued back to borderline, the original `sessionSanityReasons` and `historicalBaselineReasons` now carry through to the new breakdown. The recommendation label renders "REVIEW — <reason>" so the user still sees why the frame was originally flagged. Previously the reasons were silently dropped during the rescue's breakdown reconstruction.
- **Uncertain Tier Reasoning Coherence** — When the small-group uncertain override flips a rescued frame from `.good`/`.borderline` to `.uncertain`, the tooltip now reads "Small group — low confidence" instead of the stale rescue narrative ("FWHM and noise within group norm" etc.). Cosmetic but noticeable in tooltips and Autopilot decisions.
- **Isolated-Frame Silent Drop** — A frame that passed the measurement guard but couldn't produce any z-score (e.g. the only measured frame in a 6-frame group — `zscores()` needs ≥2 values) was silently dropped from the scoring result. No quality icon, no tooltip, no downstream stage saw it. Now produces an uncertain breakdown with explicit "No comparable frames in group — metrics unmeasured or isolated" reasoning.

### Changed
- **Stage 3 Rescue Rule Discrimination** — Rescue Rule A (`fwhmOK && noiseOK && trailingOK` → good) now additionally requires the star count to be within normal range, so Rule B (star-dip rescue) can own the "Star count dip with normal FWHM — likely transient event" narrative. Tier outcome is identical (both rules → `.good`); reasoning text is now more accurate for the ~63 frames per curated session where stars dropped but other metrics stayed fine.
- **Algorithm Version Documentation** — Added inline code comments documenting empirically-validated intentional behavior at four sites: per-night overwrite of combined-pass breakdowns, P90/P10 small-array index convention in Rule 1c and Stage 1.5, Rule 7b `starWeight > 0` guard, and Rule 8's raw-MAD threshold. These are changes that a static review might want to "fix" but empirical data shows they are net-correct — the comments prevent future reviewers from re-deriving the evidence.
- **QualityEstimator Header Comment** — Top-of-file pipeline description now lists the full execution order (stages 1, 1.5, 1.5b, 2, 3, 4 + side-lanes) instead of only stages 1, 1.5, 2.

### Added
- **Quality Pipeline Review Document** — `wiki/quality-pipeline-review-2026-04-18.md` captures the full 10-finding code review, empirical validation methodology (4540-frame confusion matrix: 22.1% FP rate + 19.1% FN rate at v22 entry), per-finding decision rationale, and a 5-step re-review checklist for future reviewers. Includes documentation of three findings explicitly rejected as empirically net-negative (per-night overwrite, P90 small-array indexing, Rule 7b bimodal guard) with the numbers that justify keeping current behavior.
- **4 Regression Tests** — New tests in `QualityEstimatorTests.swift` guarding the v23 changes: single-FWHM-flag-does-not-demote, Stage-4-preserves-sanity-reasons, uncertain-reasoning-coherence, wSum==0-produces-uncertain-not-silent-drop.

---

## [5.25.2] — 2026-04-17

### Fixed
- **Mixed-sensor scoring separation (Algorithm v22)** — Sessions with multiple cameras (e.g. ASI6200MM full-frame + ASI2600MC APS-C on the same scope) now correctly partition quality scoring by sensor resolution. Previously, the smaller sensor's frames were compared against the larger sensor's star counts and noise, producing false trash marks. GroupKey now includes image dimensions so each camera gets scored against its own peers.
- **Auto-rotate dimension guard** — Meridian flip rotation is now skipped for frames with different dimensions than the reference. Prevents meaningless 180° UV flips when mixing full-frame and APS-C images.

### Added
- **Mixed-dimension warning** — When loading a session with multiple sensor resolutions, a non-blocking alert lists each dimension group with camera names and frame counts, recommending separate folders for best results.
- **1-star garbage UX** — 1-star rating now displays as outline star (☆) instead of filled (★) to visually distinguish garbage from real quality ratings. Pressing 1 auto-marks the frame for pre-delete, saving an extra Space press. Tooltip updated to indicate auto-mark behavior.

---

## [5.25.0] — 2026-04-16

### Fixed
- **Full-res saturation filter for FWHM/HFR** (Algorithm v21) — Star metric measurement now rejects saturated stars at full resolution before computing FWHM and HFR. Previously, a single clipped star on a moonlit B-filter open cluster frame (NGC 2251, ASI6200MM @ 504mm, 120s gain 100) inflated FWHM to 11.88px — wildly above the true session median. The saturation filter checks peak pixel intensity against a configurable ceiling and excludes stars whose cores are clipped, ensuring only well-exposed stars contribute to the final FWHM/HFR values. External user report from first beta tester (Mac Studio M3 Ultra, Virginia USA).
- **Peak-SNR quality gate** — Filters noise measurement peaks on bright moonlit backgrounds that produced spurious noise MAD spikes, preventing false quality demotion on frames with elevated but uniform sky background.
- **GPU PSF fit initial guess** — `psf_fit_gaussian` and `psf_fit_elliptical` Metal kernels now use the stamp peak pixel for the amplitude initial guess instead of the bin2x peak. The bin2x value underestimated amplitude on undersampled stars, causing slow convergence or fit failure.

### Added
- **AIsaac Newton custom icon** — Purple silhouette with stars replaces the SF Symbol sparkles icon across toolbar button, chat window, and header inspector. Distinctive branding for the AI assistant.
- **Quality Assessment Incomplete UX** — When FWHM or HFR measurement is incomplete (e.g. too few unsaturated stars), the file list cell shows "!" with a tooltip explaining why. The Header Inspector's Quality Metrics section displays a detailed explanation. A dedicated "Ask AIsaac" button auto-fires a context-rich query about the specific frame's measurement issue.
- **AIsaac per-frame context enrichment** — System prompt now includes SNR, moon illumination %, moon distance, object name, and night identifier for the currently selected frame. AIsaac references frames by their deterministic `#XX-NNNN` hash ID. Metrics-first analysis rule ensures data-driven responses.
- **"Ask AIsaac about this frame" button** — Available on ALL quality metric sections in the Header Inspector, not just incomplete assessments. One-click to get AI analysis of any frame's quality metrics in context.

### Changed
- **Toolbar polish** — VLM Check button uses grid icon (grey). Auto-Mark button uses purple tint with white glow effect. Delete button removed from toolbar. Night mode now follows system appearance setting. Top padding adjusted for cleaner layout.

---

## [5.24.0] — 2026-04-14

### Added
- **Curated dataset auto-sync to Supabase** — every time the user rates a frame with `1`/`2`/`3` (setting `userConfidence > 0`), the full ground-truth row is mirrored to the new `public.curated_frames` Supabase table via fire-and-forget REST upsert. Clearing a rating (same key twice → `userConfidence = 0`) deletes the row on Supabase so stale labels don't accumulate. Keyed on `(file_hash, machine_hash)` so the same frame rated on two different Macs stays as two distinct rows — cross-machine consensus is a query, not an overwrite. The local `FrameHistory.sqlite` remains the source of truth; Supabase is a queryable mirror that Claude Code sessions can read via MCP without needing the user's Mac to be online. Network failures are silently swallowed, same pattern as `BenchmarkSharing.autoUploadSessionLoad`. New file `AstroTriage/Engine/CurationService.swift` with `uploadCuratedFrame(entry:)`, `deleteCuratedFrame(fileHash:)`, and `bulkSync(completion:)`. Uses `Prefer: resolution=merge-duplicates` + the table's `UNIQUE (file_hash, machine_hash)` constraint for native PostgREST upsert semantics. Wired into `TriageViewModel.setUserConfidence()` right next to the existing Frame History DB update. (`AstroTriage/Engine/CurationService.swift`, `AstroTriage/Engine/TriageViewModel.swift`)
- **Window → Advanced → Sync Curated Dataset to Supabase…** — bulk backfill for ratings made while offline or before `CurationService` existed. Iterates every row from `FrameHistoryDatabase.curatedFrameRecords()` and upserts each to Supabase, reporting success/failure counts in the status bar. Safe to re-run — upsert semantics mean duplicate calls are no-ops. (`AstroTriage/App/AstroTriageApp.swift`, `AstroTriage/UI/ContentView.swift`)
- **Supabase `public.curated_frames` table** — new migration `create_curated_frames`. 39 columns: `(file_hash, machine_hash)` composite unique identity; denormalized filename / capture timestamp / equipment / capture parameters; every computed pixel-derived metric (FWHM, HFR, stars, ecc, noise, PSF flux, trailing); environment (moon, bortle, twilight) for future stratification; the algorithm's verdict at rating time (`quality_tier`, `combined_z_score`, `garbage_reasons`) so drift per `algorithm_version` can be measured; the ground-truth label `user_confidence` (CHECK constraint 1..3); `quality_feedback` for the orthogonal A-key signal; algorithm + app version + rated_at for provenance. Two indexes: `(machine_hash, setup_hash, filter)` for per-setup regression queries, `canonical_target` for target-type stratification. RLS enabled with anon INSERT / SELECT / UPDATE policies mirroring the existing `session_benchmarks` pattern.

### Changed
- **Advanced menu reorganized** — the former "Export Curated Dataset…" item is now "Export Curated Dataset to File…" to disambiguate from the new Supabase sync option sitting right above it. Both paths produce the same data; the Supabase one is the canonical store going forward, the file one is for offline inspection and diffing.

---

## [5.23.0] — 2026-04-14

### Added
- **Blind Curation mode** (`Window → Advanced → Toggle Blind Curation`, `⌘⇧B`) — a labeling mode for building a ground-truth quality dataset. When active, every metric column, the quality tier icon, the feedback column, and the Header Inspector's Quality Metrics section are hidden so the user rates frames purely on visual impression. Only `#`, filename, date, time, filter, and star (`★`) remain visible. Rate with `1`/`2`/`3` (same keys as normal confidence rating — `1` = worst, `2` = fair, `3` = good). On exit, the prior column layout and Header Inspector state are restored from a snapshot taken at entry time, so your normal workflow UI comes back exactly as it was. Status bar reports rated count on exit. The blind column set is never persisted to `visibleColumns` AppSettings so it can't contaminate your regular layout. Pairs with the new curated-dataset export feature. (`AstroTriage/Engine/TriageViewModel.swift`, `AstroTriage/UI/FileListView.swift`, `AstroTriage/App/AstroTriageApp.swift`, `AstroTriage/UI/ContentView.swift`)
- **Export Curated Dataset** (`Window → Advanced → Export Curated Dataset…`) — exports every frame the user has personally rated (`userConfidence > 0` in the Frame History DB) as a timestamped folder containing three files: `curated_dataset.csv` (flat table with 54 columns — identity, equipment, capture params, all computed metrics, trailing analysis, environment, algorithm results, ground-truth labels, meta), `curated_manifest.json` (same data as a structured Codable snapshot with summary), and `curated_summary.txt` (human-readable per setup × filter × rating breakdown). Option A of the curation plan: metrics only, no pixel file copies. Regression harnesses read these files and open the original NAS/SSD frames on demand. New `FrameHistoryDatabase.curatedFrameRecords()` query method (`WHERE userConfidence > 0 ORDER BY setupHash, filter, captureDate, captureTime`). New `CuratedExport` engine with `runInteractive(viewModel:)` entry that shows a folder picker, writes all three files, and reveals the result in Finder on success. Row builder is split out as `csvRow(for:)` so the Swift type checker doesn't time out on the 54-field literal. (`AstroTriage/Engine/CuratedExport.swift`, `AstroTriage/Engine/FrameHistoryDatabase.swift`, `AstroTriage/App/AstroTriageApp.swift`, `AstroTriage/UI/ContentView.swift`)

### Fixed
- **NAS session header corruption (cross-contaminated DATE-LOC / EXPTIME / filter across rows)** — `TriageViewModel.cacheNetworkFiles` updated `self.images[index].decodingURL = localURL` via index-based write from inside `DispatchQueue.concurrentPerform`. The adjacent `networkURLUpdater` callback in the same closure used URL-based lookup (correct), but the `decodingURL` write did not. Because `applySortByColumnOrder` reorders `self.images` on quality-score completion while downloads are still in flight, stale indices from the `concurrentPerform` snapshot then landed cache paths onto the wrong entries. The subsequent `enrichWithHeaders()` call (line 1655) reads `images[i].decodingURL` and assigns the read headers back via `headersByURL[images[i].url]` — so the right URL key silently received headers from a different physical file. Manifested as "file `2026-03-31_...` shows `DATE-LOC = 2026-04-09T01:02:07` and `EXPTIME = 300` in the Header Inspector" while the file on disk held the correct `2026-04-01T04:12:06` and `EXPTIME = 180`. Local-disk sessions are unaffected because `decodingURL` stays equal to `url` there and the race can't happen. Fix: capture `sourceURL` at the top of the closure and use `self.images.firstIndex(where: { $0.url == sourceURL })` for the assignment, matching the URL-based pattern already used by `networkURLUpdater` two lines below. Blast radius on sessions loaded before this fix: Frame History DB rows (and iCloud rotation of them) may contain wrong filter, exposure, captureDate/Time, focalLength, target, and derived quality tiers for affected frames; a clean reload rewrites those rows via UPSERT on `fileHash`. `CommunityDetectionService.uploadSessionData` and `CalibrationDatabase.commitSession` only fire on PRE-DELETE confirm, so if you hadn't confirmed a PRE-DELETE in an affected session, community baselines and Welford calibration stats are clean. `benchmarkService.autoUploadSessionLoad` is unaffected — it only uploads aggregate timings, no per-frame fields. Full post-mortem in this session's conversation. (`AstroTriage/Engine/TriageViewModel.swift`)
- **Swift 6 strict type inference — pre-existing compile breaks** — Three `abs($0 - median)` closures in `QualityEstimator.swift` and one in `FrameHistoryModel.swift:fwhmChartStats` failed "ambiguous use of 'abs'" under stricter Swift 6 overload resolution; one Int→Double coercion in `FrameHistoryModel.swift` FL-cluster merge failed the same way; two `abs($0.date.timeIntervalSince(hd))` closures and one stale `Swift.abs(...)` namespace prefix in `FrameHistoryWindow.swift` also failed. Replaced `abs(x)` with `x.magnitude` in the closures (single unambiguous method instead of a multi-type overload set), and added explicit `[Double]` / `Double` annotations on the MAD computation temporaries so the nested map→sorted→subscript→multiply chain resolves in reasonable time. The fixes are behavior-identical and unlock the build without touching scoring logic. (`AstroTriage/Engine/QualityEstimator.swift`, `AstroTriage/Engine/FrameHistoryModel.swift`, `AstroTriage/UI/FrameHistoryWindow.swift`)

---

## [5.22.3] — 2026-04-14

### Added
- **Auto-Mark popover — per-filter loss breakdown** — Each Conservative / Balanced / Aggressive option in the Auto-Mark popover now shows a third compact line listing how many frames per filter would be marked, with the per-filter integration time. Sorted by exposure descending (biggest loss first), shown only when the option would touch 2+ distinct filters. Lets the user judge channel-level risk before confirming a culling step instead of just seeing one aggregate frame count and hour total. Example output: `33 Ha = 2.0h   56 R = 1.0h   22 B = 30m`. `ContentView.AutoMarkPopover.MarkOption` extended with a `filterBreakdown: [FilterImpact]` field; nil/empty filters bucketed as "—" so unknown frames still surface. (`AstroTriage/UI/ContentView.swift`)

### Fixed
- **Welcome window — "Get Started" button now reliably visible on first show** — The first-launch onboarding window's "Get Started" button used SwiftUI's `.borderedProminent` style, which renders nearly invisibly inside an `NSHostingView` when the parent NSWindow is inactive at first paint. Adding `NSApp.activate()` and `keyboardShortcut(.defaultAction)` was not sufficient because `borderedProminent`'s background fill follows the system `controlActiveState`. Replaced with a plain Button + explicit `Color.accentColor` `RoundedRectangle` background and white-on-blue text label — immune to inactive-window state and renders identically whether the window is key or not. (`AstroTriage/App/AstroTriageApp.swift`)
- **Welcome window — standard window chrome** — The onboarding window previously had only a `.titled` style mask, missing the red close, yellow miniaturize, and green zoom traffic-light buttons. Now uses `[.titled, .closable, .miniaturizable, .resizable]` with `minSize` 720×560 and `maxSize` 1100×820 so the user can close, minimize, zoom, and resize within sane bounds. Root view frame switched from a hard `.frame(width: 820, height: 640)` to flexible `min/ideal/max` so the bottom Get Started VStack can never be clipped by an over-tight root frame. (`AstroTriage/App/AstroTriageApp.swift`)
- **Session load benchmark — "Time to first image" now measures app readiness, not user click latency** — The metric was firing from `displayCurrentImage()` callbacks (`TriageViewModel.swift` ~lines 5220 / 5319), which silently no-op when `findMTKView()` returns nil (the Metal view is not yet attached at session-load time) or when the user navigated to a different image while the original decode was still running. The result was that the metric only landed when the user eventually clicked something — sometimes 30 minutes after session start — producing nonsense values. Fix: added `onFirstPreviewStored` callback on `PrefetchCache`, fired exactly once per session from `storePreview()` the very first time any preview lands in the cache (regardless of which image, regardless of user navigation). Wired in `TriageViewModel.init` to call `benchmarkStats.markFirstImageDisplayed()`. The flag is reset by `resetFirstPreviewTracking()` at every `markSessionStart()` call (4 callsites: `loadFiles`, `loadMultipleFolders`, `loadMixedSelection`, `loadSession`). The original `displayCurrentImage()` calls remain as a defensive fallback (idempotent due to the `firstImageDisplayTime == nil` guard inside `BenchmarkStats`). (`AstroTriage/Engine/PrefetchCache.swift`, `AstroTriage/Engine/TriageViewModel.swift`)

---

## [5.22.2] — 2026-04-13

### Fixed
- **Session sanity now compares FWHM in arcseconds on mixed-plate-scale pools** (Algorithm v18) — `QualityEstimator.sessionSanityCheck`: when the target+exposure pool contains frames at different plate scales (min/max `arcsecPerPixel` ratio > 1.10 and every frame has a plate scale), both the pool P10 benchmark and the per-frame comparison are computed in arcseconds instead of pixel FWHM. The original cross-setup "catch a bad night" design intent is preserved; the plate-scale bias that systematically over-flagged longer-FL frames is removed. Single-plate-scale sessions — the common case — have zero behavioral change because the arcsec conversion is a uniform multiplier per frame and the `fwhm/P10` ratio is identical. Star-count sanity check is skipped on mixed-plate-scale pools because detection sensitivity scales with plate scale and there is no clean normalization. `kAlgorithmVersion` bumped 17 → 18. Triggered by analysis of the user's M97 session where the RC12 native (2423mm) + RC12 + 0.81× reducer (1964mm) frames landed in the same pool and the native frames were being demoted despite equivalent physical seeing.

### Under the hood
- New unit tests `testSessionSanityCheck_mixedPlateScaleArcsecNormalization` (positive: good mixed-FL pool not demoted) and `testSessionSanityCheck_mixedPlateScaleStillCatchesRealBadNight` (negative control: bad native-FL frames still caught in a mixed pool). `testSessionSanityCheck_demotesBadCrossGroup` remains untouched and passes — pre-existing synthetic tests don't populate plate scale, so they traverse the unchanged pixel-FWHM fallback path.

---

## [5.22.1] — 2026-04-13

### Fixed
- **Quality feedback now reloads across sessions and machines** — User agree/disagree/partly feedback (the `A` key cycle) was already persisted to the Frame History DB and uploaded to Supabase, but was not read back when a folder was reopened. Added restore in both `onFileHash` callbacks mirroring the existing `userConfidence` path. Because `fileHash` is the primary key on `frame_record` and the SQLite file is iCloud-synced, feedback given on one Mac now also appears when the same session is opened on another Mac — without any new sync code.
- **Parent folder with stray root files + subfolders now merges everything** — `SessionScanner.scan` no longer short-circuits on `rootHasImages`. Opening a parent like `M97/` with 2 loose `.fits` files at root plus per-filter `Ha/`, `OIII/`, `SII/` subdirs now loads all of them instead of just the 2 at root.
- **PRE-DELETE folders auto-skipped during recursion, loadable when explicitly picked** — `_predel` / `pre-delete` / `predelete` (case-insensitive) directories encountered at `depth > 0` during a parent-folder scan are skipped so their contents don't pollute the session. Opening one directly as the top-level rootURL still works, so power users can review and restore previously culled frames.
- **Multi-folder selection security scopes & session root** — `loadMultipleFolders` now holds security-scoped access on every picked folder (pre-5.22.1 only kept scope on the first one, so PRE-DELETE moves for frames in folders 2, 3, … failed with a sandbox error). `sessionRootURL` is now the deepest common ancestor of the picked folders instead of the first folder's parent.
- **Mixed files + folders in Open panel** — Picking a mix of loose files and folders used to silently drop every folder because `loadFiles` filtered URLs by `.fits` extension. A new `loadMixedSelection` path scans every picked directory and merges every loose file as its own `ImageEntry`, deduped by standardized URL.
- **Multi-source PRE-DELETE confirmation** — Multi-folder / mixed sessions now show a one-time informational line in the PRE-DELETE confirmation dialog explaining where the files will be moved (`<commonAncestor>/PRE-DELETE/`). Subsequent deletes in the same session don't re-prompt.
- **Per-group feedback & algorithm-agreement counts in Supabase upload** — `CommunityDetectionService.uploadSessionData` previously computed session-wide totals of `user_agreed/disagreed/partly_agreed/algo_flagged_trash/user_overrode_keep` and stamped them onto every filter/exposure row, inflating server-side aggregates by a factor of (group count). Fixed to compute each counter from its own group's entries. Misleading comment on `CommunitySessionEntry` corrected. Existing corrupted rows from 2026-04-13 were manually deleted from Supabase before shipping this fix.

### Changed
- **Feedback icons redesigned** — Agree / Disagree / Partly now render as `hand.thumbsup.fill` / `hand.thumbsdown.fill` / `hand.point.right.fill` (thumbs up / thumbs down / sideways pointing hand) in the FB column and the right-click Quality Feedback submenu. Clearer semantics than the old checkmark / cross / half-circle.
- **Right-side Session Overview panel visibility persisted** — New `showSessionOverviewPanel` AppSettings key (dual-write UserDefaults + iCloud). Load paths (`loadFiles`, `loadMultipleFolders`, `loadSession`, `loadMixedSelection`) no longer force-show the panel on every folder open; the user's last choice is respected. First-run default remains collapsed.

---

## [5.22.0] — 2026-04-13

### Added
- **AutoRotate — WCS plate-solve based visual alignment** — Pixel-locks every frame of each target to a single reference regardless of filter, exposure, or night. For plate-solved frames (the vast majority of ASIAir and NINA captures), the transform is computed exactly from the FITS/XISF WCS data (`CD1_1`/`CD1_2`/`CD2_1`/`CD2_2` matrix, `CRPIX1`/`CRPIX2`, `CRVAL1`/`CRVAL2`) via direct matrix algebra — takes microseconds, is mathematically exact, and works for any rotation or pointing offset. Frames without WCS fall back to a synthetic rotation transform derived from the `ROTATOR` header vs the reference's rotator. Smart reference selection picks the frame whose pointing is closest to the median CRVAL of the target group, so outliers (e.g. a frame where the mount lost center) never become the baseline everyone else aligns to. Replaces the old header-flip / star-matching paths as the primary alignment route.
- **Synchronous WCS pre-scan** — On session load, FITS/XISF headers for every file are read in parallel (`DispatchQueue.concurrentPerform`) before prefetch workers start. Populates WCS fields (`wcsCD11`/`wcsCRPIX1`/`solvedRA`/etc.) plus `NAXIS1`/`NAXIS2` dimensions synchronously, so prefetch workers see accurate per-frame WCS state and can skip expensive triangle matching for plate-solved frames. ~50ms for 180 local files; scales with file count and I/O speed.
- **XISF NAXIS keyword injection** — `ImageDecoderBridge.read_xisf_headers` now appends synthetic `NAXIS1`/`NAXIS2` entries from `LibXISF::Image::width()` and `height()`. XISF stores image dimensions as `<Image>` geometry attributes, not FITS-style keywords, so libxisf's `fitsKeywords()` wasn't exposing them. Without this fix, XISF files couldn't participate in WCS alignment (the normalization step needs pixel dimensions).
- **Quality Feedback** — New user feedback loop on the algorithm's quality tier assessment. Press **A** to cycle: Agree → Disagree → Partly → Clear. New "FB" column right next to the Q column with colored icons (green checkmark / red X / orange half). Context menu "Quality Feedback" submenu for mouse users. Multi-selection aware. Persisted in the Frame History DB (migration v9) and in the per-setup CalibrationProfile. Uploaded anonymously to the `community_sessions` table so thresholds can be tuned from real user agreement rates.
- **Auto-upload of session load benchmarks** — Session scan/first-image/header/caching timings are now uploaded anonymously to the community leaderboard automatically after caching completes. No more manual click on the Benchmark button. Only meaningful sessions (≥5 files) are uploaded. Machine identity is already a SHA256 hash of the hardware UUID — unchanged from the existing community upload path.
- **Checkered-flag Auto-Mark icon** — The toolbar Auto-Mark button now uses SF Symbols' `flag.checkered` with red/white palette rendering — a racing finish-line flag instead of the previous magic wand. Clearer visual metaphor for "finish the culling job".

### Changed
- **Star chain detection is now FL-adaptive** — The `closeThreshold` in `StarMetricsCalculator.detectStarChains()` scales with plate scale when `arcsecPerPixel` is available. Physical threshold of 40 arcseconds divided by plate scale, capped at 120 pixels. At long FL (2423 mm, 0.32"/px) the threshold stays at 120 px (preserves existing behavior); at mid FL (468 mm / 85 mm aperture scopes, ~1.66"/px) it drops to ~24 px, preventing the false positives on NGC 2024 and similar dense wide-field targets where normal star clustering used to get flagged as tracking hops. Directional consensus (R) and garbage fraction thresholds now scale smoothly with plate scale across 0.5–2.5"/px (linear interpolation, no discontinuous behavior between 450mm and 550mm). Algorithm version bumped to 17.
- **Quality Feedback column visible by default** — The new FB column auto-migrates into existing users' saved visible column set via a new `seenDefaultColumns` UserDefaults key. Future default-visible column additions inherit this migration behavior.
- **Play speed default 0.1s** — Blink playback now defaults to the fastest step (0.1s). Previously defaulted to 0.5s.
- **community_sessions table extended** — New columns `user_agreed`, `user_disagreed`, `user_partly_agreed`, `algorithm_version`. Migration `20260412_community_feedback_columns.sql` applied to Supabase. Enables server-side analysis of per-setup agreement rates and baseline-drift correlation with algorithm versions.
- **Renamed "Meridian Flip" → "AutoRotate"** — Toolbar toggle label, status pill, tooltip, help text, and README. The feature is now broader than pier-side correction — it handles any plate-solved transform.
- **Line-buffered stdout for debug runs** — `setvbuf(stdout, nil, _IOLBF, 0)` at app startup so `print()` output is visible live when redirected to a file during debugging (was block-buffered, hiding everything until exit).

### Fixed
- **Meridian flip detection** — Replaced XOR logic with OR: any single signal (PIERSIDE change, rotator ≥ 90°, WCS rotation ≥ 90°) triggers the flip. The old XOR cancelled detection on ASIAIR/AM5 mounts where BOTH PIERSIDE and ROTATOR change during a flip. Used as fallback only when WCS is unavailable.
- **Mirrored alignment transforms rejected** — Added determinant sign check in `DisplayAligner.solveAffine` and `refineTransform`. Triangle-ratio matching is invariant to triangle handedness, so the hash search could pair a CCW triangle with its CW mirror and produce a negative-determinant affine. Mirror transforms are never legitimate between frames from the same camera, so they're rejected regardless of rotation angle.

---

## [5.21.1] — 2026-04-12

### Fixed
- **Filter Gap Integration Hours** — Fixed SQL GROUP BY that merged multiple targets imaged on the same night with the same filter into one row, causing one target to receive all hours while others showed zero. Integration hours in the Target Catalog's Filter Gap Analysis now correctly attribute hours per target.
- **Borderline Frames Counted** — Filter Gap Analysis now includes borderline and uncertain frames (qualityTier 1 & 4) in the usable integration count. These frames are stackable and were incorrectly excluded, causing actual hours to appear lower than reality.

---

## [5.21.0] — 2026-04-11

### Added
- **Focal Length Column** — New hideable "FL" column shows FOCALLEN header value in mm. Sortable. Enable via column picker (right-click header).
- **Filter-Aware Stage 1.5b** — Historical baseline check now applies relaxed thresholds for narrowband filters (Ha, OIII, SII): FWHM 6 MADs (was 3), trailing scaled by filter multiplier, combined 7.0 (was 3.5). Prevents false trash on narrowband data with slightly worse seeing.
- **Rule 1 P90 Floor** — Star count garbage detection now also checks against group P90 (top 10%). Catches clouded frames in groups where many bad frames drag the median down.

### Fixed
- **PE Arc Detection** — Gradient-based second chance in `computeShape()` rescues PE arc stars that fail concentration check. Only activates when medianFWHM >= 8px (avoids narrowband nebula false positives). M82 PE detection improved from ~52/64 to ~60/64.
- **Clouded Frame Detection** — Rule 0 simplified: no computed FWHM = trash. Catches heavy clouds, fog, lens cap, dome closed regardless of group composition.
- **Stacking Mixed Targets** — `validateSameTarget()` now uses plate-solved coordinates (CRVAL1/CRVAL2) as primary source. Nearby targets sharing same FOV (e.g. M81 + M82, ~0.6 degrees apart) can now be stacked together.
- **Stretch Reset Persistence** — Reset button now saves default stretch value (0.25) to AppSettings, persisting across app restarts.

### Changed
- Algorithm version bumped to 16 (re-analysis recommended for previously scored frames).

---

## [5.20.5] — 2026-04-09

### Added
- **Temperature vs HFR Metrics Tab** — New "Metrics" tab in Frame History window. Scatter plot: X=ambient temperature, Y=HFR, colored by filter. 1°C-binned rolling average trend line shows focus drift correlation. Night picker for single-night per-frame detail or all-nights nightly medians longterm view. Filter scope: All/Narrowband/Broadband/per-filter.
- **Rain Forecast in Target Catalog** — Hourly precipitation probability bars below cloud cover chart. Blue/cyan/indigo color scale, past/current/future styling. Only shown when precipitation > 0%.
- **Setup Management** — Gear icon next to Setup picker opens management dialog: rename (nickname), fix focal length (override bad plate-solve values), merge into another setup, delete setup. Orphaned sessions auto-cleaned on load.
- **Destroy All DB Data** — Window > Advanced > Destroy All DB Data. Two safety confirmations. Destroys local SQLite, iCloud backups, and calibration files.
- **FOCPOS Header Extraction** — Focuser position from FOCPOS/FOCUSPOS FITS header extracted to ImageEntry for autofocus event detection.
- **Educational Tooltips** — All 6 History chart types now include explanatory text about what the metric means, why it matters, and what to look out for.
- **Overall Stats in Tooltips** — Score (avg/median), Efficiency (avg/median), Performance (avg/median/MAD), Metrics (avg HFR/temp) shown in hover tooltips for numerical comparison.
- **Rolling Average 50/100** — Performance chart rolling window options expanded from 5/10/20 to 5/10/20/50/100.

### Changed
- **No More X-Axis Scrollbars** — Score, Efficiency, and Performance charts now always fit to window width instead of horizontal scrolling.
- **Tooltip Flip** — Tooltips automatically flip to left side of cursor when near right window edge.
- **Tooltip Readability** — Font scaled 1.2x, max width constrained to 380px.
- **Fuzzy Hover Detection** — Bar charts use nearest-point matching within 30 days instead of exact day match.

### Fixed
- **Empty Setups Filtered** — Setups with 0 frames (orphaned after merge/delete) no longer appear in dropdown.
- **Merge/Delete Cleanup** — Setup merge and delete operations now also clean session_record table.
- **Metrics Tab Data Loading** — Fixed: metricsFrameData, metricsNights, metricsEvents now @Published for immediate view updates.
- **Crash on M Key** — Fixed range crash (1..<0) when pressing M key with no session loaded.

---

## [5.20.0] — 2026-04-07

### Added
- **Meteoblue Weather Forecast** — Replaced 7Timer + Open-Meteo with Meteoblue via Supabase Edge Function. 1-hourly cloud layers (low/mid/high), visibility (km), fog probability, wind, humidity, pressure for 7 days. Past hours greyed out, bold NOW marker on current hour, future bars in color. Hover any bar for rich detail card (cloud breakdown, seeing estimate, temp, humidity, wind, fog, rain). "powered by meteoblue" attribution
- **Target Hierarchy (Industry First)** — 120+ parent/child mappings across 30+ deep-sky complexes (Orion, Heart & Soul, Veil, Carina, Rho Oph, Virgo, etc.). Sub-targets show "Part of [parent]" in catalog detail and list rows. Parents show clickable sub-target pills. Hover tooltip shows hierarchy. Frame History rolls up sub-target integration time to parent. `majorTarget` field on ImageEntry + FrameRecord with DB migration
- **Fuzzy Target Name Matching** — Compound name splitting ("M81-Bode" → "M81"), suffix typo normalization ("Bode Galaxcie" → "M81"). All compare and grouping paths use canonical target names
- **Compare Fallback Label** — Shows reason when cross-filter or cross-exposure fallback is used ("Best (R filter)", "Best (180s exposure)")
- **Setup Dedup** — Frame History dropdown disambiguates duplicate mount+camera labels by appending focal length (e.g., "ZWO AM5 + ZWO ASI6200MM Pro (620mm)")
- **Setup Nicknames Everywhere** — `setupDisplayName()` helper, nickname in AIsaac historical context
- **Common Names Everywhere** — AIsaac context shows "M81 (Bode's Galaxy)" format for all targets

### Changed
- **Monthly Trend Line** — Session Score chart always shows nightly bars + monthly median trend line (white/dark adaptive) when >6 months of data. Median computed from per-night scores, not aggregated metrics
- **Seeing Estimation** — Multi-factor heuristic using visibility (primary), high clouds, wind speed, humidity instead of simplistic 7Timer scale

### Fixed
- **Database Audit** — IC434/B33 duplicate merged (fixed type to emissionNebula), ABELL21/SH2-274 orphan resolved, LEOTRIPLET aliases removed (M65/M66/NGC3628 keep standalone entries), IC1805 alias IC1795 removed (Fish Head is sub-target), NGC7000 alias IC5070 removed (Pelican is sub-target), IC4604→RHOOPH parent references fixed, NGC7822 added to DB, unreachable parentTargetMap entries cleaned, added CYGNUSWALL→NGC7000 and PICKERINGSTRIANGLE→NGC6960

## [5.18.0] — 2026-04-05

### Added
- **VLM Check — Claude Vision Anomaly Detection** — New "VLM Check" toolbar button in Actions group generates mosaic wallpapers from cached session frames grouped by target/filter/setup. Claude Vision (Opus with extended thinking) analyzes mosaics for ice crystals, dew, clouds, obstructions, focus shifts, and light leaks
- **Deviation Map** — Computes per-pixel median across all tiles in a group, displays heat map (black→blue→cyan→yellow→red→white) showing how each tile deviates from the group median. Makes any anomaly visually obvious at a glance. Toggle via waveform button in bottom bar
- **Click-to-Mark Tiles** — Single-click any tile in the mosaic to toggle mark/unmark on the corresponding frame in the file list. Blue "MARKED" overlay on toggled tiles. Works independently of VLM analysis
- **Chronological Sequence Analysis** — VLM prompt guides model to walk through tiles in time order, detecting transient defects that appear, persist, or worsen across the session
- **Mosaic Tile Annotations** — Each 480×360px tile is center-cropped 80% and annotated with frame number, capture time, moon distance, and twilight phase
- **Supabase Edge Function Routing** — Routes VLM requests through Supabase edge function (`vlm-check`, 10 checks/day rate limit) with fallback to user's own Claude API key
- **VLM Anomaly Overlay** — Red rectangle border with type/confidence label on flagged tiles (no fill, no cross — tiles stay fully visible)
- **Floating Validation Window** — Group tabs, zoomable mosaic, scrollable anomaly list with jump-to-frame. Re-analyze button, Mark Flagged, Unmark, and Save mosaic JPEG actions

## [5.17.0] — 2026-04-04

### Added
- **Blink Video Export** — Export blink sequence as animated GIF or HEVC .mov video. Film icon button next to blink delay picker opens export popover with:
  - Format selection: GIF (with size limit: 2/5/10 MB, auto frame-dropping) or MOV (HEVC)
  - Scale: 25%/50%/75%/100% of cached preview resolution
  - Loops: 1/2/3/5 walkthroughs
  - Crop to zoom: captures the current zoomed/panned view region
  - Multi-select support: exports only highlighted rows if selected
  - Save panel for sandbox-compatible file access

### Fixed
- **Status Bar Noise** — Removed "Marked for deletion" / "Unmarked" status messages that cluttered the status bar during rapid marking

## [5.16.0] — 2026-04-04

### Fixed
- **M42 H-alpha False Positive** — Rule 0b dome/dark frame detection no longer falsely flags bright nebulae with 10000+ real star detections. Added FWHM + background cross-check: real PSFs (FWHM > 3px) with significant sky background pass through
- **Moon Distance Column Empty** — Now reads `RA`/`DEC` FITS keywords (decimal degrees) as fallback when `CRVAL1`/`CRVAL2` are absent. NINA writes target coordinates as RA/DEC
- **Blink Playback Status Flickering** — Suppressed "Loading..." status message during blink playback to prevent status bar flickering and window resizing

### Changed
- **Catalog Selection Highlight** — Changed from light blue (hard to read) to dark grey for better text readability
- **MoonDist Column Width** — Increased default width from 60 to 75px for better value display

### Added
- **Target Catalog Aliases** — Added 40+ missing alternative designations across all catalogs:
  - Sharpless IDs for Messier nebulae (M1→SH2-244, M8→SH2-25, M16→SH2-49, M17→SH2-45, M20→SH2-30, M42→SH2-281)
  - Caldwell designations for NGC/IC objects (NGC253→C65, NGC891→C23, NGC7023→C4, NGC7293→C63, NGC7331→C30, NGC7380→SH2-142, NGC7635→C11/SH2-162, NGC7789→C56, IC342→C5, IC5146→C19/SH2-125, SH2-155→C9)
  - Common names and cross-references (Leo Triplet→M65/M66/NGC3628, Horsehead→IC434, IC443→SH2-248, NGC6888→C27/SH2-105, Rosette→C49/SH2-275, IC1848→SH2-199/W5, Veil→C33/C34, SH2-240→Simeis 147)

## [5.15.1] — 2026-04-04

### Fixed
- **LSHandlerRank Warning** — Added missing `LSHandlerRank` key to Folder document type in Info.plist. Resolves Xcode build warning 90788 about incomplete document type configuration
- **Direction Filter Transit Logic** — Compass direction filter now uses the primary direction at transit time instead of all directions throughout the night, giving more accurate filtering results

## [5.15.0] — 2026-04-04

### Added
- **Target Catalog Browser** — Supabase-backed catalog of 533+ deep-sky objects. Search by name/catalog ID/alias, filter by type chips (15 types), difficulty picker. Sortable column headers. Detail panel with DSS thumbnail (enlarges on hover), coordinates, filter recommendations, scoring weights
- **Alt/Az Visibility Chart** — Tonight's altitude curve with 25°/30° threshold lines. Moon altitude overlay (dashed yellow). Red dot + vertical rule at current time. Transit time, max altitude, hours above 30°
- **Azimuth Direction Arrows** — Compass arrows showing target direction during the night (↑N →E ↓S ←W). Side-by-side with altitude sparkline in list rows
- **Weather Forecast Bar** — Tonight's forecast from 7Timer + Open-Meteo: cloud cover, seeing (location-relative quality — 2" is normal in Germany, poor in Chile), temperature, humidity, wind. Moon illumination %. 1-hourly cloud bars with midnight gap and current hour highlight
- **FOV Simulation** — Proportional target-in-sensor rectangle using your equipment profiles. Plate scale and fill ratio. Optimal FOV filter toggle (≥30% sensor fill)
- **Filter Gap Analysis** — Compares recommended filter ratios against your actual integration hours (setup-specific, not total). Traffic-light bars. "Need X more hours of FILTER" recommendations. Only shown for previously imaged targets
- **Location & Setup Picker** — Switch imaging locations and equipment setups. Weather, visibility, FOV, and integration hours all recompute automatically
- **Moon Distance** — Angular separation in list (☽ icon, red <30°, orange <60°) and detail panel with illumination %
- **DSS Sky Survey Thumbnails** — NASA/STScI public domain images, disk-cached by RA/Dec. Enlarges on hover in detail panel (120px → 300px)
- **Floating Hover Card** — Mouse over target name shows compact datasheet with all key parameters. Follows mouse position
- **Sortable Column Headers** — Click any header to sort (Name, Mag, Size, Alt, Hours). Active column highlighted with chevron
- **AIsaac v5.14.0 + v5.15.0 Knowledge** — Target-aware scoring, MAD floor, planet exclusion, Target Catalog documented in embedded prompt and Supabase
- **Data Sources** — OpenNGC (CC-BY-SA-4.0), 7Timer, Open-Meteo, NASA/STScI DSS

### Changed
- AIsaac knowledge test validates v5.14.0 concepts (target-aware, MAD floor, planet exclusion, FOV fill)
- AIsaacWeather: hourly cloud data from Open-Meteo stored separately for 1-hourly resolution
- Integration hours filtered by selected equipment setup (setupHash) instead of total across all setups

## [5.14.0] — 2026-04-03

### Added
- **Deep-Sky Target Database** — 229+ embedded deep-sky targets with type classification (galaxy, emission nebula, planetary nebula, globular cluster, IFN, etc.), angular sizes, RA/Dec J2000, magnitude, surface brightness, constellation, and filter recommendations (SHO/HOO/LRGB ratios per target type)
- **Target-Aware Quality Scoring** — Stage 2 metric weights adjust by target type: galaxies weight FWHM 1.4x and trailing 1.2x (resolution-critical), emission nebulae weight noise 1.4x (SNR-critical), IFN weights noise 2.0x with FWHM only 0.4x (every photon counts). Unknown targets use 1.0x (unchanged behavior)
- **FOV Fill Ratio Modulation** — Secondary weight adjustment based on target angular size vs sensor FOV. Small target in large FOV boosts FWHM weight. Target fills frame boosts noise weight
- **Practical Significance MAD Floor** — Prevents z-score amplification of insignificant metric differences in tight sessions. FWHM floor scales with focal length (0.20-0.80px), stars floor 10% of median, noise floor 0.0008, trailing floor 0.04. A human would never reject FWHM 4.6 vs 4.5 — now the scoring agrees
- **Planet/Solar System Exclusion** — Jupiter, Saturn, Moon, Sun, Mars, Venus, Mercury and other solar system objects excluded from quality scoring entirely (fundamentally different imaging technique)
- **Scoring Regression Tests** — 9 golden-set tests with real M82 metric values: trailing detection, chain detection, dark frame isolation, narrowband preservation, cross-setup scoring, tight session sanity, tier distribution. Runs in 0.014s, catches regressions before manual testing
- **Session Sanity Target-Type Thresholds** — FWHM sanity multiplier scales by target type: emission nebulae 1.6x P10 (diffuse targets tolerate seeing), IFN/dark nebula 1.8x, galaxies/clusters unchanged at 1.3x

### Fixed
- **GroupKey Canonicalization** — GroupKey and PoolKey now use `TargetCatalog.canonicalName()` instead of raw strings. "NGC 7000", "NGC7000", and "North America Nebula" now land in the same scoring group
- **GroupKey Setup Separation** — GroupKey includes focal length (±50mm bucket) to prevent cross-setup scoring. RASA 620mm and RC12 1964mm frames of the same target are scored in separate groups (different plate scales, different FWHM expectations)
- **Session Sanity Cross-Setup** — PoolKey deliberately excludes focal length so session sanity can cross-compare setups. January RC12 bad data is still caught by comparing against March data, even at different FL
- **Compare Filter Matching** — Compare with Best now prioritizes: 1) same filter + same setup, 2) same filter any exposure, 3) same filter class (NB↔NB, BB↔BB). Never compares Ha to L or R to L — different channels look completely different
- **R0b Dark Frame FL-Scaling** — Path B star threshold now scales with focal length: wide-field (620mm) threshold ~10000 (many real stars), long FL (2423mm) threshold ~5100 (few real stars). Background threshold tightened from 0.003 to 0.002. Fixes false positive on L-eXtreme filter at low gain

### Changed
- Algorithm version bumped to 14 (from 13). Target-aware weights, MAD floor, FL-aware grouping, R0b FL-scaling

## [5.13.0] — 2026-04-03

### Added
- **User Confidence Rating** — Press 1/2/3 to rate selected frames with 1-3 stars (same key toggles off). Yellow star icons in new ★ column after Quality. Persisted in Frame History DB via GRDB (migration v7). Filter syntax: `rating:1`, `rating:2`, `rating:3`, `rating:>0`. Works with multi-selection
- **Chart Scroll & Zoom** — Frame History date-axis charts (Session Score, Efficiency, Equipment Health) now support horizontal scroll and pinch-to-zoom. 90-day visible window, positioned at most recent data
- **PixInsight Bridge v1.2.0** — Enhanced PI script: "Open in AstroBlink" button launches the app from PI with session folder pre-selected (clipboard handoff + sandbox-safe dialog). "Prepare for WBPP" creates kept-files list. Color-coded quality tiers, sort controls, SNR/Trailing columns. Installable via PI Update Repository
- **astroblink:// URL Scheme** — Registered custom URL scheme for external app communication. Used by PI Bridge for folder handoff

### Changed
- PixInsight Bridge script uses `ExternalProcess.execute` (confirmed PJSR API) and clipboard marker for reliable cross-app communication with sandboxed AstroBlink

## [5.12.0] — 2026-04-02

### Added
- **Elliptical GPU PSF Fitting** — New Metal kernel `psf_fit_elliptical` fits 5-parameter elliptical Gaussian (A, σx, σy, θ, B) via Gauss-Newton with Levenberg-Marquardt damping. Derives eccentricity analytically from σx/σy and position angle from θ — more accurate than image moments for well-fitted stars
- **PSF Flux Z-Score Display** — PSF Flux z-score now visible in Quality Metrics panel (header inspector) and quality column tooltip. Shows how total stellar signal compares to the group
- **Frame History Re-Analysis** — Orange "Re-Analyze" button in History window re-scores all stale records (older algorithm version) using current scoring engine. Handles frames in small groups by preserving existing tier and bumping version
- **Monthly Chart Aggregation** — History window charts automatically switch to monthly buckets when date range exceeds 6 months. Calendar icon indicator shown. Affects Score, Efficiency, and Performance charts
- **PSF Flux Persistence** — psfFlux column added to Frame History DB (migration v6). Enables historical PSF flux comparison across sessions
- **PixInsight Bridge Skeleton** — Separate `pixinsight-astroblink` repo with ES5 PJSR script for importing AstroBlink triage results into PixInsight. CSV parser, TreeBox UI, SSWEIGHT header writing, platform detection

### Fixed
- **FWHM CPU Fallback** — When GPU circular PSF fit produces chi² > 1000 for all stars (poor seeing), CPU-computed FWHM values are now preserved as fallback. Previously, GPU fit cleared all CPU values then failed quality checks, leaving FWHM as nil — causing scoring to miss garbage frames
- **Re-Analysis Completeness** — Frames in groups too small for QualityEstimator (minimum group size not met) now get their algorithm version bumped anyway, preventing stale record count from sticking

### Changed
- Algorithm version bumped to 13 (from 12). Elliptical PSF, psfFlux persistence, FWHM fallback

## [5.11.0] — 2026-04-02

### Added
- **GPU PSF Fitting** — Metal compute kernel (`psf_fit_gaussian`) replaces CPU linearized Gaussian FWHM estimation. Gauss-Newton optimization with Levenberg-Marquardt damping, 8 iterations on 11×11 stamps, 3 free parameters (Amplitude, Sigma, Background). Proper fitted amplitude enables accurate PSF flux computation
- **PSFSignalWeight (PSFSWGHT)** — PixInsight 1.8.9+ compatible weight keyword written alongside SSWEIGHT during export. Computed as `log10(psfFluxSum / noiseMAD²) × 10`. More robust than SNRWeight — PSF-based flux inherently rejects non-PSF sources (hot pixels, satellites)
- **PSF Flux Column** — New hideable column showing total PSF signal per frame (formatted as K/M suffixes). Higher = more total star signal = better. Searchable via `psf:>500000`
- **PSF Flux in Quality Scoring** — PSF flux z-score replaces star count in Stage 2 combinedZ when available. Captures both star count AND brightness — immune to hot pixel inflation
- **Dome/Dark Frame Detection (Rule 0b)** — Detects closed dome images by star count ≥10000 (absolute ceiling after 16σ auto-escalation) or ≥5000 + near-zero background (<0.003). Dark frames excluded from group statistics to prevent contamination
- **SSWEIGHT on Selection** — Export operates on highlighted files if any selected, all scored files otherwise
- **Batch Delete Keyword** — New "Delete Key" scope in Batch Rename removes FITS/XISF header keywords entirely (e.g. SSWEIGHT). C bridge: `delete_fits_keyword` / `delete_xisf_keyword`
- **Filter Search Aliases** — `filter:Ha` now matches H, H2, HII, H-alpha via `canonicalFilterName()` resolution. Fallback raw contains for non-canonical names

### Fixed
- **Session Sanity Multi-Night Guard** — Stage 1.5 now requires ≥2 distinct nights. Single-night multi-filter sessions (NGC7000 H+O) no longer false-trash Ha frames when OIII has lower FWHM
- **Batch Header Case-Insensitive** — Header value replacement uses case-insensitive matching (FILTER "H" matches search "h")
- **Batch Header Crash** — Fixed null pointer crash in `String(cString:)` when reading headers via safe pointer rebinding
- **Batch Rename Selected-Only** — Operations now require files to be highlighted first for safety
- **Dark Frame Group Statistics** — Dome frames excluded from median/z-score computation, preventing real frames from appearing as outliers

### Changed
- Algorithm version bumped to 12 (from 11). Dark frame detection + PSF flux scoring
- SSWEIGHT toolbar button simplified (single Export, removal via Batch Rename Delete Key)

## [5.10.3] — 2026-04-02

### Fixed
- **Trailing Outlier Guard** — All trailing garbage rules (5, 6, 6a) now require the frame to be a trailing outlier (z > 1.0σ) within its group. On long focal length telescopes (RC12 at 1964mm, baseline 0.255), normal optical eccentricity (0.50–0.70) triggered false positives — 112 of 140 frames trashed despite looking identical to the best frame. If a frame's trailing matches the group average, it's the telescope's characteristic, not a tracking defect

## [5.10.2] — 2026-04-01

### Added
- **Severity-Dependent Trailing Multiplier** — Narrowband trailing penalty now escalates with severity: mild trailing (score <0.3) stays reduced at ~0.3×, severe trailing escalates toward full luminance penalty (1.0×). Formula: `baseMult + (1-baseMult) × trailingScore²`. Fixes false-Good ratings on clearly trailed Ha/OIII/SII frames
- **Rule 6a: Absolute Trailing Ceiling** — New filter-independent safety net: trailingScore >0.50 + consensus >0.5 → garbage. Intentionally bypasses FWHM cross-check because tracking error produces normal FWHM + high eccentricity — consensus is the definitive guard
- **Rule 7b: Star Count Drop Detection** — Frames with <65% of group median star count AND <65% median SNR flagged as atmospheric attenuation (cloud/dew/fog). FWHM cross-check confirms it's not defocus. Catches thin-cloud degradation that z-scores can't detect
- **Aggressive Auto-Mark: Weak-Good Frames** — Aggressive culling mode now also marks "Good" frames with <30% SNR contribution (SNR <55% of best). These add negligible signal and degrade the final stack

### Fixed
- **PrefetchCache Race Condition** — Frames with cached preview textures but missing star metrics are now re-analyzed via `needsAnalysis` parameter (both loop-level and operation-level skip checks)
- **MainActor Callback Delivery Race** — Quality scoring now retries up to 3× at 0.5s intervals when frames have metrics but no quality score. Catches out-of-order MainActor Task delivery where `onProgress(total)` fires before all metric callbacks complete
- **Narrowband Trailing Was Mathematically Impossible to Detect** — Previous flat 0.3× narrowband multiplier made garbage threshold 0.7/0.3=2.33, but trailing score capped at 1.0. Severe trailing on Ha/OIII/SII could never be flagged regardless of severity

### Changed
- Algorithm version bumped to 11 (from 10). Frame History DB records carry this version for re-analysis tracking

## [5.10.1] — 2026-04-01

### Added
- **Zoom Overlay** — True pixel zoom percentage displayed bottom-right of image canvas (e.g. "Fit (42%)", "100%", "200%"). Updates live during mouse drag, pinch, and keyboard zoom
- **Zoom Keyboard Shortcuts** — Cmd+0: fit to view, Cmd+1: 100% actual pixels, Cmd+2: 200%. Cmd+/Cmd-: 25% step zoom in/out (replaces font size shortcuts). Font size controls remain in View menu
- **Option+Drag Pan** — Hold Option key and drag to pan image (hand tool). Faster and more precise than scroll wheel panning
- **iCloud Sync Logging** — Diagnostic messages throughout the iCloud sync pipeline visible in Console.app

### Fixed
- **iCloud Sync Race Condition** — Replaced fixed 4-second timer with callback-based iCloud resolution. Sync check now waits until iCloud container is actually resolved (can take 10–30s on new Macs)
- **iCloud Evicted Files** — New Macs with cloud-only file placeholders now trigger `startDownloadingUbiquitousItem` + `NSFileCoordinator` to download before reading. Previously failed silently
- **iCloud Import DB Stale** — Frame History window now reloads immediately after iCloud import (GRDB DatabaseQueue reopened, notification posted). Previously required app restart
- **iCloud Export on Quick Quit** — Synchronous iCloud fallback during `applicationWillTerminate` prevents silent export failure when async resolution hasn't completed

## [5.10.0] — 2026-03-31

### Added
- **Blink Playback** — Play/stop button with delay picker (0.1–2s) in the slider bar. Blinks through all visible (unhidden/filtered) images endlessly. Multi-select blinks only selected frames. ESC or stop button to end. Status bar shows "Blink" pill during playback
- **Convergence Guard** — Autopilot now warns before marking when quality spread is already tight (< 0.3) or SNR loss exceeds integration loss. Confirmation dialog explains diminishing returns. Conservative mode is never guarded (trash is always trash)
- **Session Spread Stats** — Collapsible "Session Spread" section in the Auto-Mark popover shows per-metric distribution: FWHM, Stars, Noise, Trailing with min/max range, z-score spread, and tight/normal/wide labels. Overall quality spread + readiness percentage with color-coded bar
- **ConvergenceDetector activated** — Full convergence analysis (quality spread, SNR stopping, stack readiness) now runs in production. Previously only used in unit tests. Status bar shows quality spread value when session is uniform

### Fixed
- **File > Open menu** — Menu item posted notification but nothing observed it. Cmd+O worked (keyboard handler), menu didn't. Added `.onReceive` for `.openFolderRequest`
- **AIsaac max_tokens** — Increased from 2048 to 4096 for pro mode. Marking 800 files generated a `mark_frames` JSON that exceeded the token limit, truncating the response mid-JSON

### Changed
- **ContentView refactored** — Body extracted into computed properties (`toolbarArea`, `mainContentArea`, `statusBarArea`, etc.) and ViewModifier structs to resolve Swift type-checker timeout. Future UI additions no longer risk compiler limits

## [5.9.0] — 2026-03-30

### Added
- **AIsaac collapsible floating window** — Window starts collapsed showing preset chips + input field, always on top. Click title or type to expand to 80% screen height. Presets fire immediately on click
- **AIsaac always-on weather context** — Weather, seeing, moon phase, and planning data now included in every AIsaac response, not just "Plan Tonight". Any question benefits from local conditions
- **AIsaac Frame History DB access** — AIsaac can answer "What targets have I imaged?", "Which setup do I use most?", "Where do I need more data?" from full session history
- **Mini histogram** — 64-bin luminance histogram in the viewer slider bar, computed from raw pre-stretch data during preview generation
- **Filter Totals in Session Overview** — Per-filter integration hours, %, file count with proportional color bars. Canonical filter order (L R G B Ha OIII SII)
- **Session Detail collapsible** — Integration table collapsed by default, expandable via chevron
- **Clickable Quality Overview** — Filter name and date in Quality Overview jump to first matching image
- **Deletion history tracking** — Frame History DB tracks deleted frames per target. AIsaac planner shows deletion rates
- **Uncertain filter** — Added to quality filter preset dropdown in search bar
- **Canonical filter sort order** — L R G B Ha OIII SII everywhere (Session Overview, Quality Overview, charts)

### Fixed
- **Culling spiral of death** — Removed `recomputeQualityScores()` after pre-delete. Z-scores no longer recalculate on smaller group, preventing iterative over-culling
- **Meridian flip: rotator-aware XOR** — Per-target orientation correction using XOR logic: piersideFlipped XOR rotatorFlipped. Handles same-pierside + rotator change across nights
- **Quality "Why" text** — No longer truncated after 2 lines in header inspector
- **# column width** — Widened from 45→62px so frame IDs are fully visible
- **"Pre-caching" → "Analyzing"** — Renamed in all user-visible strings

## [5.8.3] — 2026-03-30

### Fixed
- **iCloud freshness dialog wired up** — Startup now checks if local and iCloud Frame History databases differ and prompts which to keep. Was defined but never called since v5.1.3
- **iCloud export on quit** — Frame History database exported to iCloud in `applicationWillTerminate`. Previously only exported after session save and archive scan — if user quit without saving, iCloud stayed stale

## [5.8.2] — 2026-03-29

### Added
- **AIsaac remote knowledge refresh** — Knowledge snippets fetched from Supabase `aisaac_knowledge` table. Cached locally (1h refresh), version-gated, priority-sorted. AIsaac's knowledge can now be updated without app releases
- **Bortle VIIRS 2024 in AIsaac knowledge** — AIsaac now knows about fractional Bortle from satellite data, can advise on filter choice based on light pollution
- **Updated chart knowledge** — AIsaac knows about all 6 KPI charts, hover tooltips, time range filter, Conditions factor picker

## [5.8.1] — 2026-03-29

### Added
- **Rich tooltips on all 6 charts** — Every chart data point now shows full context on hover: targets, filters, FWHM, moon %, frame counts. Bad nights get a "Likely:" cause analysis (seeing, bright moon + broadband, few frames)
- **Performance per-setup breakdown** — Hovering "All Setups" Performance chart shows per-setup FWHM with orange highlight on outliers dragging the average
- **Conditions chart redesign** — Toggleable X-axis factor: Moon / FWHM (seeing) / Temperature / Bortle. Nearest-point hover shows all environmental factors at once. Broadband vs narrowband color coding
- **Setups chart tooltip** — Hover shows frame count, date range, trash rate, and target list per setup

### Fixed
- **GRDB reentrant crash** — `perSetupFWHM()` called `allNicknames()` inside `dbQueue.read` block, causing reentrant serialized queue access. Moved outside read block

## [5.8.0] — 2026-03-29

### Added
- **Chart hover tooltips** — Mouse over Score, Efficiency, and Performance charts to see per-night details (score, retention %, FWHM) with dashed crosshair rule mark
- **Time range filter** — All / 3M / 6M / 9M / 12M / 24M / 36M picker in History header filters all charts and summary cards
- **Rolling average picker** — 5 / 10 / 20 session segmented control on Performance chart for configurable FWHM trending window
- **Integration Progress redesign** — Custom row-based view with target names, hours (not frames), per-filter stacked bars, hover detail (filter breakdown, nights, best FWHM), sort toggle (asc/desc)
- **AIsaac Session Planner context** — Plan Tonight preset now includes: tonight's moon phase + guidance, astronomical dark start/end from SunCalculator, per-target integration status with filter gaps, recent 2-3 session performance trends, weather-adaptive exposure advice (wind/humidity/seeing), dome vs portable setup awareness
- **Target catalog expansion** — 300+ named targets covering all Messier objects, major NGC/IC nebulae and galaxies, Sharpless HII regions, Barnard/LDN dark nebulae, vdB reflection nebulae, Abell planetaries and galaxy clusters, with comprehensive cross-references

### Fixed
- **Chart bar overflow** — `.clipped()` on all chart plot areas prevents bars from bleeding into header, tabs, or summary cards
- **Chart flickering** — All chart data structs use stable content-based IDs (night string, target+filter) instead of UUID(). Eliminates animation jitter
- **Flexible catalog matching** — Robust regex-free prefix detection handles any separator: IC1848 = IC 1848 = IC-1848 = iC18 48. Works for NGC, IC, M, SH2, and 20+ catalog prefixes
- **Target deduplication** — TargetCatalog.canonicalName() applied in Progress chart grouping, summary stats, and target picker. "M 82" and "M82" merge correctly
- **Progress chart sort stability** — Alphabetical tiebreaker prevents equal-hours targets from shuffling on re-render. Bar scaling uses absolute max, not first-item

## [5.7.1] — 2026-03-29

### Added
- **Bortle from real satellite data** — Fractional Bortle values (B4.8, not just B5) from NOAA VIIRS 2024 annual composite via Supabase. 136K grid cells at 0.1° resolution. Local Falchi 2015 grid as offline fallback. One Supabase call per unique location, cached forever.

### Fixed
- **Archive Scanner calibration exclusion** — FLAT/DARK/BIAS frames no longer scanned into Frame History DB. Checks full path for calibration keywords. 1,792 existing calibration records cleaned up via DB migration.
- **Bortle accuracy** — Replaced population-based model (±2 near cities) with actual VIIRS satellite radiance data. User suburb: B6→B4.8 (matches lightpollutionmap.app).
- **GRDB migration crash** — Fixed assertion failure from renamed migration (v4→v5). Migrations are now immutable once applied.

## [5.7.0] — 2026-03-29

### Added
- **In-app messaging system** — Server-driven messages from Supabase without app updates. Rich actions (yes/no/email/radio/slider/text), targeting by version/usage/entitlements, repeat modes (once/always/interval), auto-entitlement on email submission (AIsaac boost 50/day)
- **Bortle sky quality column** — Fractional Bortle class (e.g. B4.8) from site coordinates. Primary: VIIRS 2024 satellite data via Supabase. Fallback: embedded Falchi 2015 atlas grid (1.6 MB).
- **Target name normalization** — Canonical target names for consistent cross-session grouping. "NGC 7000" = "NGC7000", "Orion Nebula" = "M42", "IC 63 Ghost" = "IC63". ~150 common name aliases
- **History chart summary cards** — Row of 5 cards above charts: Frames, Nights, Best FWHM, Trash Rate, Targets. Color-coded trash rate
- **Algorithm versioning** — kAlgorithmVersion constant (=10) + ALGORITHM_CHANGELOG.md. DB records carry version for future re-analysis. Stale records indicator in History window
- **App start telemetry** — Anonymous fire-and-forget ping to Supabase (machine hash, version, chip, cores, RAM)
- **Open Database/iCloud Directory** — File menu items to quickly access hidden data directories
- **AIsaac knowledge update** — Comprehensive knowledge about Frame History, Archive Scanner, Charts, Bortle, Target Clustering, Moon data
- **Percentile-clamped Y-axis** — History charts use P2-P98 range, preventing outlier (e.g. 704K star count) from crushing the scale

### Changed
- **Charts fixed to window width** — No more horizontal scrolling, charts always fit the window
- **Night mode in all windows** — FrameHistoryWindow, BenchmarkStats, BenchmarkLeaderboard get full dark-adapted night mode via shared AppColors
- **Font scaling in all windows** — Cmd+/Cmd- now works in QuickStack, ColorCombine, Benchmark, ReleaseNotes windows
- **AIsaac Edge Function** — Dynamic per-device rate limit from device_entitlements table (email-verified users get 50 queries/day)

## [5.5.0] — 2026-03-27

### Added
- **Session-wide sanity check (Stage 1.5)** — Cross-group comparison using P10/P90 benchmarks. When 2+ metrics (FWHM, SNR, stars, eccentricity) are dramatically worse than the session's best-decile, frame is demoted to trash regardless of within-group z-score. Catches uniformly bad nights that z-scores normalize away
- **Uncertain quality tier** — Blue "?" icon for groups with <8 frames and ambiguous z-scores. Indicates low scoring confidence — visual inspection recommended. Treated like borderline for auto-mark
- **Filter-aware twilight detection** — Narrowband (Ha/OIII/SII) tolerates nautical twilight (sun -12° to -6°), RGB/L is garbage at nautical. Quality metrics panel shows "(OK for narrowband)" or "(degraded for R)" context
- **Automated January regression test** — 471-image test verifies zero false-Good classifications on known-bad data. Catches scoring regressions automatically

### Fixed
- **R9 chain detection timing race** — PrefetchCache merged all per-image callbacks (noise, stars, progress) into single MainActor task. Guarantees starChainFraction is populated before scoring runs
- **Compare with Best cross-group fallback** — When the same filter group's "best" frame is also garbage, Compare now searches across all filters and exposures for a genuinely good reference frame
- **Session sanity false positives** — Multi-group guard ensures session sanity only runs when pool has 2+ filter/night groups. Severe single-metric outlier (FWHM >1.4× P10) catches L-filter frames where SNR is acceptable but seeing is catastrophic

### Changed
- **Lighter orange borderline icons** — More visually distinct from red trash icons. HSB values shifted for all 4 severity levels

---

## [5.4.0] — 2026-03-27

### Added
- **Font size scaling (Cmd+/Cmd-/Cmd+0)** — Adjustable UI font size across file list, header inspector, session overview, and compare window. Persisted via iCloud sync. Range 0.7x–1.5x
- **Auto-Mark toolbar button** — Culling autopilot promoted to main toolbar with colorful gradient icon (green→orange→red). One-click access to Conservative/Balanced/Aggressive auto-marking
- **Toolbar reorganization** — Buttons grouped by function with visual dividers: File ops | Actions | Stacking | Display settings | Search. Toggle labels reformatted to two-line layout

### Fixed
- **False satellite trail detection on extended objects** — RANSAC collinear detection falsely triggered on galaxy knots in edge-on galaxies (M82, NGC 4565, NGC 891), dropping star count from ~1150 to ~183 and causing "zero/near-zero stars" garbage classification. New axis ratio verification rejects false positives. Count correction now subtracts only trail detections instead of replacing with center-crop-only count
- **"What's New" button version drift** — Removed hardcoded version from button label. Release notes data is the single source of truth

### Changed
- **Benchmark button color** — Green → blue for visual differentiation from quality indicators

---

## [5.3.0] — 2026-03-23

### Added
- **Community Detection Learning (Phase 1)** — Opt-in anonymous session sharing to improve quality detection across the community. After PRE-DELETE confirm, anonymized metric averages (FWHM, SNR, trailing, retention rate) are uploaded to a shared database. No filenames, images, coordinates, or personal data — ever
- **Community baseline for cold start** — New equipment? No more waiting 30 frames for calibration. If other users with similar pixel scale have contributed data, you get instant quality baselines from the community. Gray lock badge distinguishes community baselines from local calibration (blue)
- **Community status bar toggle** — Clickable person icon next to iCloud indicator. Green when active, dimmed when off. Hover for privacy explanation
- **Server-side data validation** — Supabase trigger rejects physically impossible metrics on upload. Admin RPCs for monitoring and cleanup

---

## [5.2.1] — 2026-03-23

### Fixed
- **Compare window recommendation for trash frames** — Z-score-based trash frames now correctly show "DELETE — below quality threshold" instead of no recommendation. Previously, only garbage-reason trash showed DELETE
- **Compare "best" selection consistency** — Context menu "Compare with Best" now uses fine-grained z-score ranking (matching keyboard shortcut behavior) instead of coarse tier-only ranking
- **Compare window font size** — Quality metrics and recommendation text increased from 10pt to 13pt for better readability

---

## [5.2.0] — 2026-03-22

### Added
- **Filter-aware trailing penalties** — Trailing weight now depends on filter type: narrowband (Ha/OIII/SII) × 0.3, RGB × 0.6, luminance × 1.0, unknown × 0.7. Slight trailing in narrowband no longer over-penalizes precious integration time. Garbage thresholds, z-score weights, rescue rules, and SSWEIGHT all scale with the filter multiplier
- **FL-adaptive eccentricity detection (Rule 5)** — Frames with eccentricity > 2× the focal-length baseline are flagged as garbage regardless of FWHM or consensus. Adapts automatically to any optics: 468mm baseline 0.52, 2455mm baseline 0.23
- **Multi-reason garbage display** — Stage 1 now checks ALL rules independently; frames can show multiple garbage reasons simultaneously (e.g., "zero/near-zero stars" + "target shifted off sensor")
- **Decentered target detection (Rule 1b)** — When plate-solved coordinates (CRVAL1/CRVAL2) show the frame center shifted > 30% of FOV from group median, reports "target shifted off sensor (mount recenter)"
- **Twilight/dawn detection (Rule 10)** — Sun position computed from DATE-OBS (UTC) + site coordinates using NOAA solar algorithm. Civil twilight or daylight → garbage. Twilight phase shown in quality panel for all frames
- **SunCalculator** — New NOAA-based solar position calculator for twilight classification (Night, Astro twilight, Nautical, Civil, Daylight)
- **AIsaac knowledge tests** — Automated test suite validates AIsaac's system prompt covers all garbage reasons, quality tiers, twilight phases, and key pipeline concepts. Catches knowledge drift on any logic change
- **AIsaac prompt updated** — Full Rules 0-10 documentation, multi-reason support, twilight phase in per-frame data, FL-adaptive eccentricity explanation

### Fixed
- **Trailing detection false negatives** — Frames with extreme eccentricity but normal FWHM (e.g., RC12 at 2455mm) were incorrectly rated "Good" because `fwhmRulesOutTrailing` suppressed the trailing check. New Rule 5 bypasses this entirely
- **"Why" redundancy** — Removed duplicate "Why" line that showed identical text to "Garbage" reasons in quality metrics panel

---

## [5.1.3] — 2026-03-22

### Fixed
- **Splash screen checkbox** — "Don't show on startup" checkbox no longer triggers immediate window dismissal; preference saves and persists correctly
- **Background anomaly false positives** — Quality scoring Rule 7 no longer flags frames with lower background (clearer sky, more stars) as "abnormal background"; only elevated background (clouds/gradient/fog) is penalized

---

## [5.1.2] — 2026-03-21

### Added
- **Progress fuel bars** — blue progress bars in the status bar for scanning, header loading, downloading (NAS), and pre-caching with time estimates
- **Interleaved NAS pipeline** — downloads and pre-caching run concurrently; pre-caching starts after first 4 files download instead of waiting for all
- **Split fuel bar** — when both downloading and pre-caching are active, two stacked bars show both progress simultaneously
- **Unmark All (U key)** — clear all deletion marks across the session; also available as AIsaac command
- **Quality filter presets** — dropdown menu next to search field with Quality (q:trash/excellent), Filter (filter:Ha), and Metrics (fwhm:>5) presets
- **Quality tier filter syntax** — `q:trash`, `q:borderline`, `q:good`, `q:excellent`, `q:unscored` + color aliases (`q:red`, `q:orange`, `q:green`)
- **Trailing score filter** — `trail:>0.5` filters by trailing score
- **QuickLook OSC debayer** — Finder previews and thumbnails now show debayered color for one-shot-color (Bayer pattern) FITS/XISF files
- **Scroll to top on folder open** — file list scrolls to first image when opening a new session

### Fixed
- **NAS filter mismatch** — header enrichment deferred to after downloads complete (reads from local SSD cache instead of NAS); uses URL-based lookup instead of index-based to prevent sort-induced header misassignment
- **Slow navigation after caching** — applied stretch/settings now properly synced for interleaved prefetch path; `cacheMatchesCurrentSettings` returns true after caching completes
- **Prefetch main-thread stalling** — replaced `DispatchQueue.main.sync` cache checks with thread-safe `NSLock`-protected URL set; background operations no longer block on main thread
- **Quality icons before analysis** — frames show empty quality icon until actually measured during pre-caching (was falsely showing trash icon for unmeasured frames)
- **Download cancellation** — opening a new folder immediately cancels in-progress NAS downloads and pre-caching
- **Scanning overlay stuck** — loading phase properly cleared for NAS sessions after scan completes
- **Quality scoring race** — interleaved prefetch completion defers quality scoring to header enrichment completion, ensuring full header data is available

### Changed
- **AIsaac context** — loading/downloading/caching status included in session context; quality filter syntax documented in command help
- Progress bars use light blue (pre-caching) and dark blue (download/loading) instead of previous style

## [5.0.0] — 2026-03-20

### Added
- **AIsaac AI Assistant** — in-app AI powered by Claude, with streaming responses, voice input/output, per-frame deep analysis, and app control commands
- **Preset question chips** — Quality Summary, Smart Mark, Filter Advice, About This Object, Nearby Objects, Plan Tonight
- **Two-tier model** — Free Sonnet Buddy (included) or Opus Superexpert (user's own API key stored in macOS Keychain)
- **Equipment learning database** — remembers telescopes, cameras, filters, locations, and imaging history across sessions
- **Voice interaction** — hold mic button to speak, optional TTS for responses
- **App control via chat** — AIsaac can navigate, highlight, mark, filter, compare, open previews, and start stacking
- **Location-aware language** — detects imaging site from FITS headers, offers to respond in local language
- **Bortle zone awareness** — factors light pollution into all filter and target recommendations
- **Session planning** — "Plan Tonight" generates complete imaging plans with targets, filters, exposures, and timeline
- **Quality metrics in Header Inspector** — purple section showing all z-scores, tier, SNR contribution, reasoning
- **SmartCull in Help panel** — comprehensive 6-item FAQ covering all 4 pipeline stages
- **Unique session index** — # column shows stable 1-based index (not NINA frame number) for clear frame identification
- **SITELAT/SITELONG extraction** — supports NINA, LAT-OBS, OBSLAT header variants
- **Microphone + speech recognition entitlements**
- **Supabase Edge Function** — proxy to Claude API with rate limiting, error handling, Pushover alerts, rolling auth token

### Changed
- **App renamed** — "AstroBlink & AIsaac" (display name, About, Help, window title)
- **maxConcurrentDecodes** — 6 → 8 for high-core machines
- **minGroupSize** — 10 → 6 for quality scoring of small filter groups
- **SmartCull in README** — new section in Complete Feature List

## [4.6.0] — 2026-03-19

### Added
- **SmartCull Quality Engine** — Multi-stage scoring with rescue rules for borderline frames
  - Stage 3 Rule A: FWHM + noise within group norm → rescued to good
  - Stage 3 Rule B: Star count dip with good FWHM → rescued (transient event detection)
  - Stage 3 Rule C: FWHM-only trash → promoted to borderline
  - Stage 4: Group-level FWHM sanity check for z-score trash
- **Quality reasoning ("Why?")** — Human-readable explanations in quality tooltips
  - New `reasoningText` field on QualityBreakdown
  - Explains dominant penalty, rescue reasons, and percentile position
- **BatchQualityAnalysisTests** — Ground-truth calibration test suite with annotated thumbnails + CSV export

### Fixed
- **Trailing false positives eliminated** — FWHM cross-check in Rule 5 prevents flagging sharp frames as "elongated" (real trailing always degrades FWHM)
- **noiseZ explosion** — Individual z-scores capped at ±3.0 in QualityBreakdown (was raw, could be 10922 in homogeneous groups)
- **Background anomaly sensitivity** — Threshold scales with group size (small groups < 20 frames use wider threshold)
- **Z-score trash threshold** — Widened from -1.5 to -2.0 (Stage 1 garbage catches truly bad frames; z-score trash now requires 2σ below average)
- **Sort tiebreaker** — Within any sort order, time is always ascending (chronological within the same night). Only grouping columns + first metric used as sort keys; no extra metrics that break time ordering.
- **Direct re-sort after scoring** — Eliminates timing issues with indirect flag mechanism

### Changed
- borderlineSeverity ranges updated for wider threshold (-0.5 to -2.0 span)
- Trailing consensus threshold raised from 0.4/0.7 to 0.5/0.8 for Rule 5b

## [4.5.0] — 2026-03-19

### Added
- **Priority Navigation Queue** — Dual-queue caching architecture for perceived-instant navigation during initial cache. When browsing to an uncached image, a high-priority queue (`.userInteractive` QoS) decodes the current image ±2 neighbors first, while background fill continues at lower priority. Auto-refreshes display when priority preview completes.
- **Async GPU Preview Generation** — Final GPU pass (bin2x → STF → post-process → mipmaps) uses `addCompletedHandler` instead of `waitUntilCompleted()`, freeing worker threads ~2-3ms earlier per image for the next decode.

### Changed
- **Concurrency Increase** — Background queue uses up to 6 workers, priority queue adds 2 more, total max 8 concurrent decode operations on high-core-count machines (was 6 max).

### Fixed
- **File List Focus** — Opening a folder now correctly focuses the file list table for immediate keyboard navigation, instead of focusing the header inspector table.
- **File List Scroll Stutter** — Reduced scroll disruption during caching: soft refreshes (cache checkmarks, quality icons) now reload only visible rows instead of full `reloadData()`. Selection change color updates use lightweight `textColor` property change instead of cell rebuilds.

## [4.4.0] — 2026-03-18

### Added
- **Color Combine** — Combine mono filter stacks into RGB color images directly in the app. Auto-detects filters (Ha, OIII, SII, L, R, G, B with broad alias matching), auto-selects best palette preset (SHO, HOO, LRGB, HSO, HaRGB, Custom). Per-channel weight sliders with on-release recombine. Optional luminance blending for LRGB. Full post-processing (stretch, dark, sharp, contrast, color, denoise, deconvolution). Result window auto-opens when combine completes. Save PNG export.
- **Min/Max Pixel Rejection** — Per-pixel per-channel min/max tracking during warp accumulation. Automatically subtracts the single brightest and darkest values when ≥3 frames contribute. Effectively removes satellite trails (1 bright frame) and hot pixels. No UI toggle needed — always active, transparent to user.
- **Lanczos-3 Interpolation** — Optional 6x6 sinc-windowed interpolation kernel for sharper stacking on large dither offsets. Selectable via segmented picker in stacking progress panel. Default remains bilinear for speed.
- **Adaptive Triangle Matching** — On alignment failure, retries with wider triangle set (25 stars, up from 20) and looser inlier threshold (15px vs 10px). Dramatically reduces alignment failures on wide-dither sessions like M81.

### Changed
- **Triangle Star Limit** — Increased from 15 to 20 (C(20,3) = 1140 triangles vs 455). Better coverage for large dither patterns.
- **V1 NormalStacker Removed** — Deleted QuickStackEngine.swift (781 lines), V1 views (920 lines), V1 toolbar button and all references. LightspeedStacker (V2) is now the sole stacking engine.
- **Dark Slider Position** — Moved between Stretch and Sharp in all result windows (LightspeedStacker, Color Combine, Image Preview).

## [4.3.0] — 2026-03-17

### Added
- **Per-Setup Calibration Database** — Learns from user actions (mark/unmark/commit) to build per-setup quality baselines using Welford's online algorithm. Persistent JSON files in `~/Library/Application Support/AstroBlinkV2/Calibration/`. Keyed by anonymized SHA256 hardware fingerprint (telescope+camera+FL+pixelSize). Designed for future Supabase community learning.
- **Absolute Quality Floor** — Frames within 1 MAD of the learned baseline for ALL metrics are locked as KEEP — z-scores cannot override. Prevents the "death spiral" where relative scoring always finds "the worst" even in excellent sets. Requires ≥30 learned frames per setup.
- **Convergence Detection** — Monitors quality spread (std dev of z-scores). When spread < 0.3, displays "Culling complete — quality is uniform". Also detects SNR stopping: warns when SNR loss % exceeds integration loss %.
- **Stack Readiness Meter** — Status bar health bar (0-100%): 40% uniformity + 35% SNR retention + 25% absolute floor coverage. Green ≥95%, yellow 80-95%, orange 60-80%, red <60%.
- **SSWEIGHT Export** — Toolbar button writes SubframeSelector-compatible SSWEIGHT keyword (float, 0-100) into FITS/XISF headers for WBPP integration. Formula: `clamp(0, 100, 50 + z*20) * (1 - trailing*0.5)`. CSV backup created alongside.
- **Lock Badge** — Blue lock.circle.fill SF Symbol overlay on quality icons for calibration-locked KEEP frames.
- **Calibration Status** — Quality scoring status bar message shows learning progress ("Learning... (N/30 frames)") or calibrated state with frame/session counts.
- **CalibrationDatabaseTests** — 11 tests: fingerprint hashing, Welford's mean/variance, MAD thresholds, profile learning, agreement rate.
- **ConvergenceDetectorTests** — 8 tests: convergence detection, SNR stopping, readiness scoring, edge cases.

### Fixed
- **QualityEstimator test data** — `testBestFrameDetectedAsExcellent` and `testRecommendationLabelNotSetForExcellent` used starCount 800 vs group median 200, triggering starCountAnomaly Rule 6. Changed to 350 (< 1.8× median).

## [4.2.0] — 2026-03-17

### Added
- **Star Trailing Detection (Industry First)** — Orientation consensus analysis using circular statistics on star position angles (PAs). When >50% of stars agree on elongation direction, it's a tracking error — not optical aberration. First astrophotography tool to use this approach.
- **Adaptive Eccentricity Aperture** — FWHM-scaled measurement radius `min(15, max(5, FWHM×2.5))` instead of fixed 3px. Captures PSF wings where trailing is visible. Bright stars measured via annular region (skips saturated core).
- **Focal-Length-Adaptive Thresholds** — Baseline eccentricity model `0.8/sqrt(FL/200)` automatically adjusts for optical setup. Short FL (468mm) allows more optical aberration; long FL (2423mm) expects tighter PSF. Uses FOCALLEN from FITS headers.
- **TrailingAnalyzer Engine** — New module: circular statistics on PAs (doubled-angle method), consensus detection, focal-length baseline model, trailing score [0..1] combining elongation excess + consensus strength.
- **Star Count Anomaly Detection** — Flags frames with >1.8x group median star count as garbage (doubled stars from tracking/dithering jumps).
- **StarAnalyzerTests** — Blackbox test harness for multi-setup validation. Auto-discovers test data folders, generates annotated PNGs with PA direction lines, consensus arrows, and relative color coding. Extracts FITS headers for full hardware context.
- **Position Angle + Axis Ratio** — StarDetail struct now stores PA of elongation axis [0..180°) and minor/major axis ratio [0..1] per star. Used for consensus analysis and compare view visualization.

### Changed
- **Eccentricity Measurement** — 60 measured stars (was 30), 10px crowding distance (was 15px), full-res position refinement via `refinePositions()`. Relaxed saturation threshold (99.5%) for shape measurement to include bright stars.
- **Quality Scoring** — `trailingScore` replaces raw eccentricity in garbage detection and z-score computation. Garbage rule: `trailingScore > 0.7` OR `(>0.4 with >70% PA consensus)`.
- **Quality Tooltips** — "Trail" metric replaces "Ecc" in z-score breakdown.

### Validated
- Tested across 5 optical setups: RC12 (2423mm f/8), refractor 140mm (904mm), refractor 85mm (468mm f/5.5), RASA 11" (620mm f/2.2). Cameras: ASI6200MM, ASI2600MC, ASI6200MC. 1338 good + 117 bad frames.

## [4.1.0] — 2026-03-17

### Added
- **Compare Star Overlay** — Compare window (C key) now shows colored circles on measured stars: green (round), orange (borderline ecc 0.3-0.5), red (elongated >0.5). Toggle on/off with switch. Per-star eccentricity, HFR, and FWHM stored during precache for visualization.
- **"Why Worse" Info Bar** — Compare window bottom bar shows metric-by-metric comparison (Stars, FWHM, HFR, Ecc, SNR % of best) plus recommendation label.
- **Global Quarantine (Q key)** — Move all marked files to `~/Desktop/Astro-Quarantine/` regardless of source folder. Same undo (Cmd+Z) as PRE-DELETE. Sandbox-safe with NSOpenPanel fallback.
- **Freeze-Stamp Processing** — Stack result windows now have Freeze/Unfreeze buttons for sequential processing. Freeze bakes current adjustments into a new base layer, then apply further adjustments on top. Full undo stack.
- **Best Frame Metrics Comparison** — Stack result windows show "Best frame vs N stacked" row with Stars, FWHM, HFR, Ecc, and estimated SNR improvement from stacking.
- **Compare Loading Indicator** — Floating "Preparing Compare..." panel with progress bar while images are decoded. Auto-dismisses when compare window opens.

### Changed
- **Compare Window Zoom** — Opens at fit-to-view (1.0x) when star overlay is present, instead of 300% zoom. Ensures all star circles are visible immediately.
- **Compare Window Focus** — Now receives keyboard/scroll focus immediately on open (makeKeyAndOrderFront).
- **Pre-Delete Dialog** — Better formatting with section headers, indented values, and blank line separators between Integration lost, SNR impact, and Tier breakdown.
- **Quality Tooltips** — Added section headers ("── Metrics ──", "── Recommendation ──"), better column alignment, and blank line separators for improved readability.
- **Stack Save Filename** — Now includes `_stacked-N` suffix (e.g., `M81_2026-03-12_H_stacked-14.png`).
- **Stack Preview Aspect Ratio** — Mini preview in stacking progress overlay now matches image aspect ratio instead of hardcoded 200×200 square.

### Fixed
- **Hide-Marked Selection** — Pressing H to hide marked files now correctly selects exactly 1 image (nearest to current). Previously left multiple files highlighted, which was confusing.
- **Stale Stack Preview** — Running a second stack no longer shows the previous stack's mini preview. Preview texture and star positions cleared at start.

## [4.0.0] — 2026-03-15

### Added
- **Star Eccentricity Detection** — 2D image moment analysis (SExtractor/DAOPHOT method) detects star elongation from tracking errors, wind shake, mount issues. Eccentricity > 0.6 = immediate trash. Weight 1.5x in quality scoring (highest — elongation can't be fixed by stacking).
- **SNR Contribution Score** — New "Contrib" column shows how much each frame adds to a weighted stack: `(SNR_i / SNR_best)^2 × 100%`. Hidden for trash frames. Placed next to Q column for quick assessment.
- **Per-Metric Quality Tooltip** — Hover any quality icon for z-score breakdown per metric (Stars, FWHM, HFR, Noise, Ecc) with arrows, SNR contribution %, and bold KEEP/DELETE recommendation based on stacking physics.
- **Orange Gradient Icons** — Borderline tier split into 4 visual sub-levels: light amber (nearly good) to deep orange (nearly trash), using hollow/filled exclamation marks.
- **Live SNR Retention Bar** — Status bar health bar showing real-time SNR retention % as you mark frames. Green (>95%) → Yellow (90-95%) → Orange (80-90%) → Red (<80%). Per-group breakdown on hover.
- **Deletion Impact Summary** — Enhanced pre-delete dialog shows integration time lost, SNR impact %, and quality tier breakdown before moving files.
- **Smart Keep/Delete Recommendations** — Research-backed labels: round stars = always KEEP (even with worse seeing). Elongated = DELETE. Based on Svalgaard comparison tests and stacking SNR physics.
- **Ecc column** — Visible by default after SNR. Shows median star eccentricity [0..1] with metric bar (lower = better).

### Changed
- **Compare with Best** — Now picks the truly best frame by continuous z-score, not an arbitrary one from the same quality tier.
- **Quality Sort** — Re-applies after every quality recomputation (not just initial load). Sort persists correctly after Reset.
- **QualityBreakdown struct** — Replaces old `(tier, zScore)` tuple. Pre-computes per-metric z-scores, SNR contribution, cached SNR^2, garbage reason, and recommendation label.
- **Status bar** — Removed pixel dimension/RGB info and filter display. Added SNR retention bar.

### Fixed
- **Metric bar scroll bug** — Fixed constraint accumulation causing all cell values to disappear after repeated scrolling. Proportional width constraints now properly removed from parent view on cell reuse.
- **Stretch slider sync** — Slider initial value now loads from saved UserDefaults instead of hardcoded 0.25.
- **compareWithBest selection** — Used `qualityTier.rawValue` (0-3 enum) instead of continuous z-score, picking arbitrary frames among same-tier images.

## [3.13.0] — 2026-03-14

### Added
- **Help: Background Tab** — Comprehensive FAQ-style documentation covering quality scoring (4-tier system with z-scores), metric bars, smart 4-case column sorting, STF stretching algorithm, debayering, denoise, deconvolution, triage tips.
- **4-Tier Quality Icons** — Full green (excellent), half-green (good), orange (borderline), red (garbage). Z-score shown on hover. Fine-grained sorting within tiers via raw z-score.
- **Compare with Best (C key)** — Side-by-side comparison with synchronized zoom/pan against the best frame in group. Opens maximized at 300% zoom. ESC to close.
- **Metric Bar Indicators** — Per-group red-to-green bars below Stars, FWHM, HFR, SNR values showing relative ranking within the same target+filter+exposure group.
- **Context Menu Enhancements** — Open With... (PixInsight, etc.), Show in Finder, Compare with Best.
- **Pitch-Black Frame Detection** — Frames with no stars and no noise data (camera failure, shutter stuck) marked as garbage.
- **Splash "Don't show on startup"** — Checkbox to suppress splash screen on launch.

### Changed
- **Smart Column Sorting** — 4-case auto-sort by session type with exposure as grouping element. Sort fires once after initial precache using recommended order (not saved layout).
- **Quality Scoring Refinements** — Two-stage detection, star weight 1.2x, narrowband 25% garbage threshold, FWHM/HFR sort ascending.

### Fixed
- **FITS Special Characters** — `fits_open_diskfile` replaces `fits_open_file` for bracket/parenthesis support.
- **Initial Sort Timing** — Sort correctly fires after first precache completes, regardless of saved UserDefaults column order.
- **PNG Export Colors** — RGBA vs BGRA pixel format check prevents R/B channel swap.
- **vDSP STF Bug** — Fixed `vDSP_vsadd` scalar parameter misuse in preview STF computation.

## [3.12.0] — 2026-03-14

### Added
- **Double-Click Image Preview**: Open any image in a floating window with Stretch, Sharp, Contrast, Dark, Color, Denoise, and Deconvolution sliders. Multiple windows for side-by-side comparison.
- **GPU Bilateral Denoise**: Two-pass noise reduction — bilateral filter (pixel noise) + chrominance denoise in YCbCr (color patches). 0-200% slider.
- **Richardson-Lucy Deconvolution**: Iterative GPU deconvolution with Gaussian PSF. Toggle between RL and multi-scale Unsharp Mask (USM). 5-20 iterations.
- **OSC Debayer in Stacking**: Color camera images debayered (GPU bilinear) before stacking — full-color stacked results.
- **Hot/Cold Pixel Rejection**: GPU cosmetic correction before stacking — sigma-clipped median detects and replaces hot/cold pixels.
- **Color Saturation Slider**: 0-3x saturation control in all result windows (RGB images only).
- **Leaderboard Latest Badge**: Most recent personal entry highlighted with bold fonts and green "LATEST" badge.

### Changed
- **True Star Count**: Stars column shows actual total detected stars (GPU atomic counter), not capped at 50.
- **Dynamic Column Order**: Auto-reorder columns based on single vs multi-object sessions after header enrichment.
- **Center-Crop Quality (70%)**: HFR, FWHM, noise stats measured from center 70% of image — excludes edge optical effects.
- **Per-Channel STF Stretch**: Unlinked per-channel c0/mb with Linked toggle. Precomputed from full-res data via STFCalculator.
- **Benchmark Icon**: Medium dark green speedometer icon.
- **Benchmark Default Tab**: Session Load tab shown by default when no stacking data.
- **File List Auto-Focus**: Keyboard focus set to file list after initial load for immediate arrow key navigation.

### Fixed
- **PNG Export Colors**: Correct RGBA/BGRA handling — red channel no longer swapped with blue.
- **vDSP STF Bug**: Fixed vDSP_vsadd API misuse (&scalar vs [scalar]) that corrupted MAD computation in preview STF.
- **Splash Dismiss**: Splash screen dismisses on any click (inside or outside window).
- **Stretch Slider**: Precomputed STF params only used at default 25% — slider adjustments now recompute correctly.

## [3.10.0] — 2026-03-13

### Added
- **About / Splash Screen**: Custom About window replacing standard macOS panel. Shows app icon, version, social links, Tell a Friend share sheet, What's New button, and App Store link. Displays as splash on launch (auto-dismiss after 6s or click outside).
- **Tell a Friend**: Native macOS share sheet for recommending AstroBlinkV2 — available in About window and Release Notes.

### Changed
- **Quality Scoring**: Cross-night comparison by default. Groups by filter + target + exposure only (removed night grouping). Consistently bad nights now score lower overall instead of being judged only within their own night.
- **Toggle Order**: Toolbar toggles reordered to Apply All → Debayer → Lock STF → MeridianFlip for consistent left-to-right workflow.
- **Benchmark Icon**: Light blue speedometer, positioned right of Night toggle.
- **Leaderboard Chip Column**: Left-aligned header to match textual column content.
- **Toolbar Cleanup**: Removed MEM/CPU system stats from toolbar row 1.

### Fixed
- **Star Column Empty**: `displayStarCount` now includes GPU-computed star count (`computedStarCount`), not just NINA-sourced `starCount`.
- **Spacebar Marking**: Keyboard-highlighted rows now correctly toggle pre-delete marks. Works with multi-selection and filtered views (hideMarked, showOnlyMarked, search filter).
- **Benchmark Total Ready Time**: `totalSessionDuration` is now a frozen stored value instead of a computed property. Stops counting once both caching and header enrichment complete.
- **Lock STF Darkening**: Locking STF while showing a cached preview no longer causes images to go dark. Current image is decoded first to capture correct STF params.
- **Stretch Slider + Lock STF**: Moving the stretch slider while STF is locked now recalculates STF params AND re-freezes the lock, so the change is visible.
- **Reset Sliders**: Reset now restores `applyAllEnabled = true`, matching the exact state after initial folder load.

## [3.9.0] — 2026-03-13

### Added
- **Anti-Moiré Trilinear Filtering**: GPU mipmap generation + trilinear sampler eliminates moiré artifacts when images are zoomed out on lower-resolution screens (MacBook 13"/14"). Pixel-accurate nearest-neighbor zoom preserved when zoomed in.
- **Leaderboard Copy Button**: Copy entire leaderboard as tab-separated text for pasting into spreadsheets or forums.

### Changed
- **Leaderboard Layout**: Proper column alignment with consistent spacing, increased font sizes (10→11pt), divider between headers and data, wider window (920px). All numeric columns right-aligned, chip name left-aligned.
- **Leaderboard Limit**: Fetch up to 1000 entries (was 200), ordered by newest first.

### Fixed
- **Calibration Frame Filtering**: Flexible case-insensitive substring matching for DARK/FLAT/BIAS in filenames and folder names. No longer requires strict NINA `_DARK_` underscore pattern.

## [3.8.0] — 2026-03-13

### Added
- **Lights-Only Folder Scan**: When opening a folder, calibration frames (DARK, FLAT, BIAS) are now automatically excluded. Detection works via both NINA filename tokens (`_DARK_`, `_FLAT_`, `_BIAS_`) and calibration subfolder names (`DARK/`, `FLAT/`, `BIAS/`, `DARKS/`, `FLATS/`, etc.). Individual file selection bypasses this filter so you can still open any file type directly.

## [3.7.0] — 2026-03-13

### Added
- **Benchmark Sharing & Leaderboard**: Share your stacking and session load benchmarks anonymously with the community. See how your machine ranks against others. Powered by Supabase with privacy-first design (only hardware specs and timing shared, machine identity is a non-reversible SHA256 hash).
- **Session Load Benchmarks**: New "Session Load" tab in the leaderboard — compare file scanning, first image display, header reading, and pre-caching performance across machines. Ranked by MB/s throughput, auto-detects local SSD vs network storage.
- **Sortable Leaderboard Columns**: Click any column header to sort ascending/descending. Active sort column highlighted with chevron indicator. Secondary sort by primary metric on ties.
- **Release Notes in Help Menu**: "What's New" menu item shows release notes for each version directly inside the app.
- **Share & Compare Button**: Green prominent button in Quick Stack result windows and Benchmark Stats window. Uploads benchmark and opens the community leaderboard.
- **Speedometer Toolbar Icon**: Quick access to Benchmark Stats from the main toolbar.
- **Duplicate Prevention**: Identical benchmarks are detected before upload and silently skipped.

### Changed
- **Toolbar Layout**: Thin separator line between toolbar icons and image settings row. Image settings (stretch, sharp, contrast, dark) are now centered. MeridianFlip toggle moved to toolbar row 1 between Lock STF and Apply All.
- **Reset Button**: Now shows icon + "Reset" label for clarity.
- **Toolbar Spacing**: Slightly increased padding between main toolbar icons.
- **Leaderboard Ranking**: Stacking benchmarks ranked by t/frame (seconds per frame) instead of absolute time for fair comparison across different frame counts. Added ms/MP/frame metric for cross-resolution comparison.

## [3.6.0] — 2026-03-12

### Added
- **GPU-Accelerated Star Metrics**: HFR (Half-Flux Radius) and FWHM (Full Width at Half Maximum) are now automatically computed for every image during session loading using GPU star detection + CPU Gaussian fitting. No external software or FITS header data required.
- **ROTATOR-based Meridian Flip Detection**: For mounts without PIERSIDE header (e.g. ZWO ASIAIR on AM5), AstroBlinkV2 now detects meridian flips from the ROTATOR angle (~180° change).
- **"Night" column**: New default-visible column showing the astronomical observing night (evening date). Images captured after midnight are correctly attributed to the previous evening's session.
- **Header Inspector: Copy support**: Multi-row selection with Cmd+Click/Shift+Click, Cmd+C to copy selected rows as "KEY = VALUE" lines, plus a "Copy All" button.
- **Quality score tooltips**: Hovering over the Q column now explains the score meaning or why it's empty (e.g. "needs ≥20 images per group").

### Changed
- **Column order**: Quality metrics (Q, SNR, FWHM, HFR) now grouped together right after Filter for quick scanning. "Date" column moved to hidden-by-default (replaced by "Night").
- **Observing night grouping**: Quality scoring and Session Overview now group by astronomical night (evening date) instead of calendar date. Sessions spanning midnight are no longer split into two groups.
- **Star detection shared**: Extracted star detection into shared `StarDetector` utility used by both QuickStack engines and the new star metrics pipeline.

### Fixed
- **FWHM computation**: Replaced coarse 0.5px annuli radial profile (always returned ~2.50) with linearized Gaussian fit for accurate, per-star FWHM values.
- **Star metrics coverage**: Relaxed star filtering criteria (saturation 95%→98%, edge margin 15→12px, crowding distance 20→15px, min stars 3→2) so more images get computed metrics.
- **Stars column**: No longer shows internal measurement count (capped at 30). Only displays header/filename-sourced star counts to avoid confusion.

## [3.5.1] — 2026-03-12

### Fixed
- UTI declarations: removed exported UTIs, use standard identifiers.

## [3.5.0] — 2026-03-11

### Added
- **Quality Estimator**: Automatic frame quality scoring using z-scores within filter/object/night/exposure groups (min 20 frames). Metrics: FWHM, HFR, StarCount. Filter-aware weighting for narrowband (Ha/OIII/SII). Three tiers: good (green checkmark), uncertain (orange minus), trash (red X).
- **SNR Column**: Signal-to-noise ratio computed from noiseMedian/noiseMAD, sortable and searchable (`snr:<10`).
- **Quality column**: Color-coded SF Symbol icons in file list.
- **noiseMAD metric**: Robust noise estimation for quality scoring.

### Changed
- **Column order**: Filename moved right in default layout. Quality metrics (Q, SNR) promoted to early positions.
- **4-level sort**: Column sorting now supports 4 sort levels (was 3).

## [3.4.0] — 2026-03-10

### Added
- **LightspeedStacker (V2)**: GPU-accelerated stacking engine — ~15s for 16 frames vs ~102s with NormalStacker. GPU warp+accumulate Metal kernel, parallel star detection via TaskGroup, hash-based triangle matching O(1), vDSP normalization.
- **Dual Stacker UI**: NormalStacker (turtle icon) and LightspeedStacker (bolt icon) side by side in toolbar.
- **Benchmark Stats Window**: Horizontal bar chart showing file scanning, first image, header reading, caching, Quick Stack durations plus live memory/swap usage (Window menu).
- **Photoshop-style Zoom**: Click-drag horizontal zoom in Quick Stack result window, plus pinch-to-zoom and scroll-to-pan.

## [3.3.0] — 2026-03-10

### Added
- **SNR Column**: Signal-to-noise ratio in file list, computed from noise statistics, sortable and searchable.
- **Memory Budget Warning**: Warns before caching if session exceeds 70% of physical RAM, with reduction percentage and safe image count recommendation.
- **Quality Overview Help**: Embedded example screenshot, enlarged window (600×750), real-world example data walkthrough.

### Changed
- **Status bar stats**: Replaced pixel dimensions with cache/file size stats (e.g. "108 cached (6.0 GB) — Raw: 10.2 GB").
- **Session overview panel**: Top-aligned layout (was vertically floating).

### Fixed
- **File list focus**: Fixed Shift+Space multi-mark and keyboard nav stealing focus to header inspector table.

## [3.2.0] — 2026-03-10

### Added
- **Quick Stack**: Select 3+ subs and stack with triangle star matching + affine alignment. GPU bin2x pre-processing, blue star crosses, full result window with 4 sliders + Save as PNG. Same-target validation (name + RA/DEC).
- **Save as PNG**: Export stacked results with current adjustments, smart filename from session metadata.

### Changed
- **Doubled slider ranges**: Stretch 0–100%, Sharpening -4/+4, Contrast -2/+2, Dark Level 0–1.0.
- **vDSP-optimized rendering**: Quick Stack result slider adjustments ~5-10x faster.
- **Quality Overview**: Interactive ? help button with beginner-friendly walkthrough. Brown replaces yellow for readability. Expanded quality section, compact fact sheet.

### Fixed
- Zoom +/- keys no longer lose file list focus.
- Header inspector scroll position preserved across image navigation.

## [3.0.0] — 2026-03-09

### Added
- **Spotlight-style Search**: Real-time toolbar filtering with `column:value` syntax (e.g. `filter:Ha`, `fwhm:>4`, `file:Veil`). Plain text searches across all columns. Column aliases (`fil`, `obj`, `cam`). Numeric operators (`>`, `<`, `>=`, `<=`, `=`).
- **Cmd+M Move to Folder**: Move checkmarked files to any destination folder with "Create New Folder" dialog. Full undo via Cmd+Z.
- **H Cycles 3 View States**: All files → hide marked → show only marked → all. Orange "Only Marked" pill in status bar.
- **Lock STF (S key)**: Freeze STF stretch params from current image for brightness comparison across frames.
- **Apply All**: Bake current stretch + post-processing into all cached previews for instant navigation.
- **GPU Post-Processing**: Real-time sharpening (unsharp mask), contrast (S-curve), and dark level sliders via Metal compute.
- **Mark/Unmark Filtered**: Batch checkmark all search results for quick triage.
- **Persistent Settings**: Sliders, toggles, column order remembered across sessions via UserDefaults.
- **19 default-visible columns**: Date, Time, Type, Camera promoted to default-visible.

### Fixed
- OSC debayer: proper mono/color toggle with correct stretch for both modes.
- Keyboard focus stays on table after clicking image/sliders.

## [2.2.0] — 2026-03-09

### Added
- **Lock STF toggle** (S key): Freeze exact c0/mb stretch params for brightness comparison.
- **Apply All toggle**: Bake stretch + post-processing into all cached previews.
- **GPU post-processing pipeline**: Sharpening, contrast, dark level sliders via Metal compute.
- **Persistent settings**: All sliders and toggles saved via UserDefaults.

### Changed
- Redesigned toolbar with SF Symbol toggles + status bar pills.
- Debayer pill hidden when session has no OSC images.
- Real-time CPU/memory stats in status bar.

### Fixed
- updateNSView now respects debayerEnabled + stretchStrength (was overriding user).
- Red-on-blue selection readability in night mode.

## [2.1.0] — 2026-03-08

### Added
- **QuickLook Preview Extension**: Spacebar preview in Finder shows STF auto-stretched FITS/XISF images. CPU rendering with 65536-entry LUT per channel, parallel row processing. Bin2x for images >4096px.
- **QuickLook Thumbnail Extension**: Thumbnail provider for FITS/XISF in Finder.

## [2.0.1] — 2026-03-08

### Fixed
- PRE-DELETE sandbox permission when files opened individually (request folder access via NSOpenPanel).

## [2.0.0] — 2026-03-08

### Added
- **8-Phase Performance Optimization**: Up to 5x faster on local SSD, 8x faster on NAS/10GbE.
  - Concurrent FITS decode via cfitsio `_REENTRANT` (4x throughput)
  - Zero-copy Metal buffers via `posix_memalign` + `bytesNoCopy` (-116 MB/image)
  - GPU bin2x compute kernel (30–150 ms → <1 ms per image)
  - Sliding window prefetch via OperationQueue (50% less stall)
  - Parallel header reading via `concurrentPerform` (6x faster)
  - Vectorized STF median via `vDSP_vsort` (3x faster)
  - Combined GPU command buffers (single submission)
  - Parallel network file copy (4 concurrent streams)
- **Ambient/focuser temperature columns** in file list.
- **Page Up/Home, Page Down/End** jump to first/last image.

### Changed
- Status bar rearranged: selections left, general info right.
- Navigation: arrow keys stop at boundaries (no wrap-around).
- Column order: checkbox, #, filename, object, filter, exp, amb, foc, temp, gain, size, fwhm, hfr, stars, subfolder.

## [1.4.0] — 2026-03-23 (iOS AstroFileViewer)

### Added
- **File history & swipe navigation** — Files are cached locally in Documents/FileCache/ (max 10 files, 2 GB). Swipe left/right to navigate between previously opened files. Works even after app restart. Translucent chevron arrows indicate available navigation.
- **Enhanced status bar** — Shows position in history, date/time (DATE-OBS), filter, and dimensions: "1/5 2025-11-12 20:53 | Ha | 9576 x 6388 Mono"
- **Dark point slider** — Raises the black point to clip faint background noise. Range 0–100%, applied after STF stretch. Same algorithm as macOS AstroBlink.
- **GPU bilateral denoise** — Edge-preserving 5x5 bilateral noise reduction (0–300%). Smooths background noise while keeping stars and edges sharp.
- **Gradient correction slider** — Adjustable removal of linear light pollution gradients (0–300%). Fits a plane to an 8x8 grid of 20th-percentile background samples.
- **Auto-rotate** — Landscape images are automatically rotated to fill the screen in portrait mode. Zero-cost UIImage orientation metadata. Toggle in adjustments panel.
- **Swipeable adjustments panel** — Drag down to dismiss the slider panel. Drag handle at top.
- **Persistent settings** — All sliders and toggles saved via UserDefaults and restored on next launch.
- **Help & About view** — Comprehensive help section with "Play Around!" encouragement, all controls documented, tips, and about info. "Buy me a coffee" support link at top.

## [1.3.0] — 2026-03-08

### Added
- **Bin2 display** for large sensor images (>8192px) — prevents crash on ZWO ASI6200MM (9576×6388).
- **Stretch slider** from 0% (fully linear) to 100%.

## [0.9.7] — 2026-03-08

### Added
- **Debayer toggle** (D key): OSC Bayer pattern detection (RGGB/GRBG/GBRG/BGGR) from headers, GPU bilinear interpolation, default OFF for speed.
- **Night mode** (N key): Red-on-black UI for dark-adapted vision.
- **Stretch slider**: Adjustable 0–100% stretch strength per image.
- **Splash screen**: About panel on launch, auto-dismiss after 2 seconds.
- **Cache indicator**: Checkmark next to cached filenames.
- **App Nap prevention**: Background processing continues during caching.
- **Two-phase loading**: Fast filename scan + background header enrichment in parallel.

### Fixed
- Image navigation for uncached images.
- Debayer toggle refreshes currently displayed image immediately.

## [0.9.4] — 2026-03-07

### Added
- **Initial public release**: Fast visual culling tool for astrophotography sessions on macOS.
- Metal GPU rendering with PixInsight-compatible STF auto-stretch.
- FITS/XISF decoding via libxisf + cfitsio (all compression formats).
- NINA filename token parsing (date, target, time, filter, exposure, gain, temp, HFR, stars, etc.).
- Integrated side panels: Header Inspector + Session Overview with Fact Sheet generator.
- Pre-delete workflow: mark with Space, move to `_predel/` subfolder with Cmd+Backspace, full undo stack.
- Multi-level column sorting (click to sort, drag to reorder, 20+ columns).
- Keyboard-first navigation with key repeat for rapid blinking.
- Smart folder scanning with subfolder auto-detection.
- Individual file selection support.
- Network volume caching with 4 parallel streams.

### iOS — AstroFileViewer v1.0.0
- FITS/XISF viewer for iPhone/iPad with STF auto-stretch, pinch-to-zoom, header inspector, Save to Photos.
