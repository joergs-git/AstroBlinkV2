# AstroTriage – TODO

Status: [ ] offen | [~] in Arbeit | [x] fertig

Current version: **v6.0.3** (build 93) — in flight 2026-05-11 (OSC measurement overhaul, kAlgorithmVersion 27 → 29)

---

## v6.x Post-Launch Backlog

Welle-3 work from the 2026-05-03 launch-readiness audit. Three patch
releases planned (v6.0.x → v6.1.x → v6.2.x), priority order top to bottom.
Working file with full context: `tasks/launch-readiness-2026-05.md` (gitignored).

### Patch 1 — Service hygiene + safety nets

- [~] **Pre-launch verifications**:
  - [ ] PrefetchCache stress test (500+ FITS, fast ←/→ nav) —
        manual on Release build, repro steps in
        `tasks/launch-readiness-2026-05.md` § "M1"
  - [x] Manipulated FITS bounds test — automated as
        `testFITSBoundsCheck_RejectsAbsurdDimensions` in
        `Tests/DecoderTests.swift`
  - [ ] Golden-Set regression (7 setups × 1638 frames, ±2%) —
        `Tests/ScoringRegressionTests.swift` covers the synthetic
        portion; full real-data sweep stays manual,
        repro steps in `tasks/launch-readiness-2026-05.md` § "M3"

- [x] **`SupabaseClient` → real service layer**
  - Retry with exponential backoff on transient 5xx (502/503/504) +
    recoverable URLErrors (timedOut, networkConnectionLost, dns…)
  - Per-call timeout via `send(_, timeout:, retries:)` parameter
  - Typed `SupabaseError` (notConfigured / network / cancelled /
    invalidResponse). 4xx / non-transient 5xx pass through as
    `(data, response)` so callers retain their own status-code
    handling (e.g. 429 → first-class result)
  - `X-App-Version` header now on every request (e.g.
    "AstroBlinkV2/6.0.0 (89)")
  - All 10 callers migrated; SSE-streaming callers stay raw
    (AIsaacService + Claude-API fallback in VisualAnomalyDetector)
  - Commits: 0a26281 (helper), 6780797 (BenchmarkSharing),
    b40ca29 (remaining 8)

- [x] **CI: enforce `kAlgorithmVersion` bump** on quality-critical edits.
  Workflow `.github/workflows/algorithm-version-check.yml` diffs PR/push
  against the seven scoring files, blocks if `kAlgorithmVersion` did
  not bump, warns if `ALGORITHM_CHANGELOG.md` was not updated alongside.

- [x] **Force-Unwrap-Sweep** — audit complete 2026-05-03,
  deliverable at `tasks/force-unwrap-audit.md` (gitignored). 100 sites:
  71 system-guaranteed | 18 internal-invariant | 11 Category C real
  risks. **Category C cleared 2026-05-04**: all 11 sites verified gone
  during Patch 3 wave 4 follow-up. The TriageViewModel-shaped sites
  (best!.qualityTier × 2, sessionRootURL!, cropRect! × 2) were swept up
  by Patch 2's TVM split. The standalone sites
  (SessionCache.swift:35, AppMessageService.swift:43,
  AIsaacWindowController.swift:346, QualityEstimator.swift:1343,
  StarMetricsCalculator.swift:667–670) had also been refactored to
  if-let / guard-let in earlier maintenance. The audit doc itself
  remains useful as a Category B style-cleanup backlog.

### Patch 2 — TriageViewModel split + QualityEstimator stages

The big one. Snapshot tag before each step (`pre-refactor-<slice>`), build
+ smoke test between every commit.

- [x] **`SessionOrchestrator`** (shipped, commits d3e471b → 371d14b):
  Session loading, prefetch + caching pipeline, header enrichment,
  scoring trigger, post-scoring cascade (SNR retention, convergence,
  Frame History persistence, moon, Bortle), VLM mosaic + Claude Vision,
  and community session-commit hook all live on
  `SessionOrchestrator` (+Headers, +Prefetch, +Scoring, +VLM
  extensions). TriageViewModel.swift trimmed 6118 → 4219 LOC (-31%).
  SessionHost protocol owns the narrow seam back into TriageViewModel
  for state mutation + a few orientation/display bridges
  (detectMeridianFlip, applyWCSAlignment, updateMeridianRotation,
  checkForMixedDimensions, applySortByColumnOrder,
  shouldRotateForMeridian) that stay on the view model.
  Snapshot tags pre-refactor-orchestrator-{protocol,load,prefetch,
  enrich,scoring,vlm,community} cover rollback.

- [x] **`TriageState`** (shipped, commit a45db93): Selection /
  filter / marked / sort UI-state extracted to a dedicated
  TriageState class. View model keeps thin forwarder properties of
  the same name; sub-object's `objectWillChange` is forwarded into
  the view model's so SwiftUI bindings continue to repaint
  unchanged. Scope: selectedIndex, hideMarked, skipMarked,
  showOnlyMarked, pendingColumnOrder, pendingColumnVisibility,
  needsQualityResort. `filterText` deliberately stays on the view
  model (Binding-projection constraint).

- [x] **`QualityEstimator` stages → separate files** (shipped,
  commit aa53d42, kAlgorithmVersion 24 → 25): pure mechanical move,
  byte-for-byte preservation. Split into +Helpers (227 LOC),
  +SessionSanity (250 LOC), +Historical (387 LOC).
  QualityEstimator.swift 2112 → 1292 LOC. ALGORITHM_CHANGELOG entry
  in v25 documents the rationale + the no-logic-change guarantee.
  Synthetic ScoringRegressionTests green; full real-data
  BatchQualityAnalysis stays manual per launch-readiness M3.

- [x] **`FrameHistoryDatabase` iCloud-Sync extraction** (shipped,
  commit 9956e7a): iCloud rotating-backup workflow moved into a
  dedicated FrameHistoryICloudSync class. Database keeps its
  storageURL + dbQueue private; helper holds iCloud directory
  state and reaches into the database via a weak ref + narrow
  internal `reopenAfterImport(replacingWith:)` API. All four
  external call sites work unchanged via thin DB forwarders.

- [x] **`FrameHistoryModel`** (shipped, commit accad72): 20 nested
  domain types split into a FrameHistoryModel+Domain.swift
  extension. Pure mechanical move — every reference site keeps
  working unchanged because Swift looks nested types up by
  enclosing type, not by declaration file. FrameHistoryModel.swift
  1289 → 1099 LOC.

### Patch 3 — Cross-platform + tests + concurrency

- [x] **Decoder sharing macOS ↔ iOS** (commit f16a659):
  AstroFileViewer-iOS/Packages/ImageDecoder/ retired (-610 MB from iOS
  subtree). iOS now references `../Packages/ImageDecoder` via project.yml.
  C++ bridge unified — macOS canonical (superset). cfitsio thread-safety
  stays platform-specific via CFITSIO_LOCK macro: macOS no-op + _REENTRANT
  cSettings.when(platforms:[.macOS]); iOS std::lock_guard on a static
  std::mutex. Both apps build clean. **Manual verification before next
  iOS App Store submission**: smoke-test FITS+XISF decoding on actual iOS
  hardware — simulator can mask page-alignment / mutex contention issues.

- [x] **Granular telemetry toggles** (commit 990c4f2):
  communityLearning master toggle split into telemetryPerformanceBenchmarks
  / telemetryFrameQualityRatings / telemetryCommunityBaselines. One-time
  migration in AppSettings.migrateLegacyTelemetryToggle() preserves opted-out
  users' choice across all three new keys. Status-bar Community indicator
  now opens a popover with three checkboxes + descriptions + "Enable all" /
  "Disable all" master buttons. Onboarding splash keeps the single master
  toggle. PRIVACY.md updated. Privacy bug fix in passing: BenchmarkSharing +
  CurationService previously gated only on BenchmarkConfig.isConfigured —
  the granular split closes that opt-out gap.

- [x] **Test coverage** (commit 0eff9b8):
  - QualityEstimatorTests +13 tests: R6 star anomaly (4), R7 background
    incl. negative-deviation invariant (5), isLockedKeep absolute floor (4),
    Stage 1.5b narrowband (1 deliberate XCTSkip — needs DI seam refactor)
  - ScoringValidationTests +12 tests: aliasing (5), type weight modifiers (7)
  - DecoderTests testMetalBufferCreation: pre-existing wrong-assertion bug
    fixed (buffer.length is page-aligned for bytesNoCopy, not == totalBytes)
  - Total: 24 active + 1 skip = 25 new tests, all passing
  - Golden-Set in CI: still listed as a future item (synthetic golden set
    is automated; full real-data sweep stays manual per launch-readiness M3)

- [~] **Strict Concurrency / Swift 6 migration** — partial.
  - **Shipped (waves 1-3, kAlgorithmVersion 25 → 26):**
    Cleared the 89 default-mode warnings the compiler shows without
    `SWIFT_STRICT_CONCURRENCY=complete`. Three commits, snapshot tags
    `pre-patch3-{wave2,wave3,flip}`:
    - Wave 1 (chore: 23 sites, commit fe12406): `onChange(of:perform:)`
      → macOS-14 two/zero-parameter syntax across 9 view files.
    - Wave 2 (refactor: 32 sites, commit 9b93cf2): snapshot mutable
      arrays/dicts to `let` before crossing into MainActor.run; add
      explicit `[weak self]` to inner closures so `self` is not
      aliased back to the outer detached-Task's captured-var.
    - Wave 3 (refactor: 28 sites, commit 23be223): `@unchecked Sendable`
      on PreviewGenerator / DisplayAligner / SessionCache (already
      thread-safe via internal locks); `nonisolated(unsafe)` on
      PrefetchCache.cachedURLsSet (already lock-protected) and on the
      bufferAlias inside SessionOrchestrator's withUnsafeMutableBufferPointer
      (concurrentPerform writes only its own index per worker);
      AIsaacSpeech polling moved off DispatchQueue.global onto a Task
      that hops to MainActor; QuickLookDebayer's local `func pix`
      lifted to a static helper; QuickStackEngineV2.waitUntilCompleted()
      → `withCheckedContinuation { addCompletedHandler }` (Swift 6
      hard error from async); one real dangling-pointer bug fixed in
      BatchOperations.swift's XISF write-keyword error path; misc
      cleanup (redundant `??`, unused `let T` / `summaries`,
      redundant `nonisolated(unsafe)` on Sendable static).
    Plus: the unstaged `.xcscheme` revert that has been carried through
    every recent session is unrelated and was not committed.
  - **Deferred (wave 4):** flipping `SWIFT_STRICT_CONCURRENCY=complete`
    in project.yml exposes **531 additional warnings**. Categories
    sized to plan around (top of the distribution):
    - 31× "sending 'self' risks data races" — Swift 6 sendable inference
      across SwiftUI/AppKit boundaries.
    - 12× `MTLTexture` non-Sendable captures — the Metal API itself
      doesn't conform; needs wrapper types or `@unchecked Sendable`
      shims everywhere a texture crosses a Sendable closure.
    - ~120× "main actor-isolated property X cannot be referenced from
      nonisolated context" — AppKit `NSView` / `NSWindow` ergonomics
      (centerXAnchor, addSubview, makeKeyAndOrderFront, etc.) all
      `@MainActor`. Most call sites need `@MainActor` annotations or
      `MainActor.assumeIsolated { … }` shims.
    - 11× `ArchiveScanner` self-capture in @Sendable closures — needs
      `@unchecked Sendable` or an actor refactor.
    - 6× `FileListView.Coordinator` non-Sendable parameter passing.
    - Plus a long tail (passing closure as 'sending', main-actor
      property mutation through nonisolated NSTableView delegate
      methods, etc.).
    This is genuinely multi-day work, not a single slice. Right
    sequencing is probably: actor boundaries first
    (ArchiveScanner / Coordinators), then Metal wrappers (MTLTexture
    Sendable shim), then the AppKit @MainActor sweep, then flip the
    flag and clear the residual.

### Smaller observations (quick wins, anytime)

- [x] Status-bar Community Learning indicator: sibling `info.circle`
      button opens PRIVACY.md on GitHub (commit 5c58729). Lives
      outside the toggle tap-area to avoid accidental opt-out flips.
- [x] `AIsaacUserProfile.delete()` posts `Notification.Name.aisaacProfileDeleted`
      (commit 5c58729). `TargetDatabaseViewModel` observes it and
      refreshes its cached `equipmentSetups` / `allLocations`
      mirrors. Other callers freshly `.load()` each time, so they
      already see the blank profile — no observer needed.

---

## Shipped (v1.0–v5.2.0)

All original implementation phases are complete:

- [x] **Phase 1** — Core Skeleton (Xcode/XcodeGen, libxisf, cfitsio, MTKView, Texture Pool)
- [x] **Phase 2** — STF + Metal Pipeline (CPU reference, Metal STF shader, debayer, dual-queue GPU, RAM cache, PrefetchCache)
- [x] **Phase 3** — File List + Metadata (SessionScanner, FITS/XISF header parsing, NINA filename tokens, NINA CSV reader, NSTableView)
- [x] **Phase 4** — Triage Workflow (Pre-Delete move/undo, Pre-Delete panel, keyboard shortcuts)
- [x] **Phase 5** — Filter System (wildcard + numeric filters, quality tier syntax, filter presets)
- [x] **Phase 6** — Disk Cache + Polish (thumbnail cache, settings, error handling, performance monitoring)
- [x] **SmartCull Engine** — 4-stage quality pipeline (z-scores → deep analysis → pattern rules → calibration floor)
- [x] **Star Trailing Detection** — Adaptive aperture, orientation consensus, FL-adaptive baseline (v4.2.0)
- [x] **Self-Calibration** — Per-setup Welford learning, absolute quality floor, convergence detection (v4.3.0)
- [x] **SSWEIGHT Export** — Writes weight keyword to FITS/XISF headers + CSV backup (v4.3.0)
- [x] **Color Combine** — Mono filter stacks → RGB with presets (SHO/HOO/LRGB/etc.), per-channel weights (v4.4.0)
- [x] **LightspeedStacker V2** — Min/max rejection, Lanczos-3, adaptive triangle matching (v4.4.0)
- [x] **Priority Navigation Queue** — Dual-queue caching with async GPU preview (v4.5.0)
- [x] **AIsaac AI Assistant** — Claude-powered in-app assistant with voice, app control, equipment memory (v5.0.0)
- [x] **NAS Support** — Interleaved download + pre-caching pipeline (v5.1.2)
- [x] **Quality Filter Presets** — `q:trash`, `filter:Ha`, `fwhm:>5` syntax (v5.1.2)
- [x] **Filter-Aware Trailing** — Trailing penalty scales by filter: NB 0.3×, RGB 0.6×, L 1.0× (v5.2.0)
- [x] **FL-Adaptive Eccentricity** — Rule 5: extreme ecc > 2× baseline = garbage (v5.2.0)
- [x] **Multi-Reason Garbage** — All rules checked independently, multiple reasons shown (v5.2.0)
- [x] **Decentered Target Detection** — Rule 1b: CRVAL1/CRVAL2 shift > 30% FOV (v5.2.0)
- [x] **Twilight Detection** — Rule 10: NOAA solar position from DATE-OBS + site coords (v5.2.0)
- [x] **Star Count Anomaly** — Rule 6: doubled stars from dithering/guiding jumps (v4.2.0)
- [x] **Compare with Best** — Synchronized zoom/pan side-by-side, PA overlay (v3.12.0)
- [x] **Image Preview Window** — Double-click floating window with full post-processing (v3.12.0)
- [x] **QuickLook Plugin** — Finder previews with OSC debayer for FITS/XISF (v5.1.2)
- [x] **PixInsight Bridge** — PJSR script for importing triage results (separate repo)

- [x] **Font Size Scaling** — Cmd+/Cmd-/Cmd+0 across all panels (v5.4.0)
- [x] **Auto-Mark Toolbar Button** — Culling autopilot in main toolbar with gradient icon (v5.4.0)
- [x] **Toolbar Reorganization** — Grouped with dividers, two-line toggle labels (v5.4.0)
- [x] **False Satellite Trail Fix** — Axis ratio verification on extended objects (v5.4.0)
- [x] **Session-Wide Sanity Check** — Cross-group P10/P90 comparison catches uniformly bad groups (v5.5.0)
- [x] **Uncertain Tier** — Blue ? for small groups with low confidence (v5.5.0)
- [x] **Filter-Aware Twilight** — Narrowband tolerates nautical twilight (v5.5.0)
- [x] **R9 Timing Race Fix** — Merged MainActor callbacks in PrefetchCache (v5.5.0)
- [x] **Compare Cross-Group Fallback** — Finds genuinely good reference across filters (v5.5.0)

---

## Shipped — v5.14.0

- [x] **Deep-Sky Target Database** — 229+ targets with type classification, angular sizes, RA/Dec, filter recommendations
- [x] **Target-Aware Quality Scoring** — Metric weights adjust by target type (galaxy FWHM 1.4x, IFN noise 2.0x, etc.)
- [x] **FOV Fill Ratio** — Secondary weight modulation based on target size vs sensor FOV
- [x] **Practical MAD Floor** — Prevents z-score amplification of insignificant differences in tight sessions
- [x] **FL-Aware FWHM Floor** — MAD floor scales with plate scale (long FL = wider pixel floor)
- [x] **Planet/Solar Exclusion** — Solar system objects excluded from quality scoring
- [x] **GroupKey Canonicalization** — "NGC 7000" = "NGC7000" = "North America Nebula"
- [x] **GroupKey Setup Separation** — FL bucket prevents cross-setup scoring (RASA vs RC12)
- [x] **Session Sanity Cross-Setup** — PoolKey without FL allows cross-setup bad-night detection
- [x] **Compare Filter/Setup Matching** — Same filter priority, same FL, NB↔NB only
- [x] **R0b FL-Dependent Threshold** — Wide-field higher star threshold, tightened background
- [x] **Session Sanity Target-Type Thresholds** — Emission nebula FWHM 1.6x, IFN 1.8x
- [x] **Scoring Regression Tests** — 9 golden-set tests catching M82 trailing, R0b, cross-setup issues
- [x] **Float32/Float64 FITS Support** — BITPIX-aware decoder for APP/PixInsight/GraxPert output
- [x] **Blink Video Export** — GIF/MOV export with scale, loops, crop-to-zoom, size-constrained GIF (v5.17.0)
- [x] **R0b FWHM Cross-Check** — Bright nebulae (M42 H-alpha) no longer falsely flagged as dome/dark (v5.16.0)
- [x] **Moon Distance RA/DEC Fallback** — Reads RA/DEC keywords when CRVAL1/CRVAL2 absent (v5.16.0)
- [x] **Target Catalog Aliases** — 40+ Sharpless, Caldwell, common name aliases added (v5.16.0)
- [x] **VLM Check** — Visual anomaly detection via Claude Vision API. Deviation map (pixel-by-pixel median comparison) + absolute anomaly checks for ice, dew, condensation, obstruction. Supabase Edge Function for VLM inference. Tile-based evaluation with explicit per-tile visual evidence. Filter-aware (narrowband vs broadband sensitivity) (v5.18.0)

---

## Open — Planned Features

### Target Database UI
- [x] Browsable target catalog window (`AstroTriage/UI/TargetDatabaseWindow.swift`,
      `TargetDatabaseViewModel.swift`, `TargetDetailView.swift` — sortable
      table, type/size/magnitude/filter recommendations, weather + FOV
      preview; shipped v5.15.0).
- [x] FOV fill ratio visualization (per release notes: "FOV Simulation —
      proportional target-in-sensor rectangle using your actual equipment
      profile. Shows plate scale and fill ratio. Switch between equipment
      setups.").
- [ ] Show which target matched the current session + active weight
      modifiers (open — needs UX choice on placement; per CLAUDE.md
      "Type-Based Metric Weight Modifiers" the data is already computed,
      just not surfaced to the user).

### Unattended Night-After Auto-Triage (NINA → AstroBlink hand-off)

End-to-end "I wake up, the cull is done" pipeline. AstroBlink polls one or
more configured drop folders for an `astroblink-session-*.json` manifest
written by a small NINA plugin at session end, then auto-triages the
shoot, dumps the garbage, and pushes a Pushover summary — all without
the user touching the app.

- [ ] **NINA plugin** (separate repo / project) writes a session manifest
      JSON at "session ended" time. Schema captures session root path,
      target name(s), filter list, total frame count per filter,
      capture-window start/end, equipment fingerprint hint (telescope +
      camera + focal length), and an `astroblink_state` field initially
      `"pending"`. Manifest filename includes a UTC timestamp so multiple
      sessions in one folder don't collide.
- [ ] **Background poller in AstroBlink** — `SessionDropWatcher` (new
      `AstroTriage/Engine/`). Watches N user-configured directories via
      `DispatchSourceFileSystemObject` (FSEvents-style) for `*.json`
      files matching the manifest schema. Validates the schema before
      acting. Settings UI: list of watch folders + per-folder enable
      toggle.
- [ ] **Idempotency safeguards** — never run twice on the same manifest:
      - on pickup, atomically rename to `*.processing.json` (lock); on
        success rename to `*.finished.json`; on failure rename to
        `*.failed-<reason>.json` with a short error tag
      - keep an internal SQLite ledger of `(manifestHash, fileHash,
        timestamp, status)` so a manifest renamed back by the user can't
        re-trigger
      - skip manifests older than a configurable max-age (default 7 d)
- [ ] **Auto-triage preset** — three-level menu (`conservative` /
      `balanced` / `aggressive`) reusing the existing Auto-Mark
      autopilot logic. Configurable per watch folder, with a global
      default. Aggressive preset additionally moves marked frames to
      PRE-DELETE (or even Trash, behind a separate "auto-empty"
      double-confirm setting that is OFF by default — see CLAUDE.md
      non-negotiables on permanent deletion).
- [ ] **Headless run mode** — load session, finish prefetch + scoring,
      apply autopilot, optionally move-to-PRE-DELETE, run / refresh
      Frame History DB, fire community telemetry, write a per-session
      report. No window pops to front; macOS app stays unobtrusive
      (LSUIElement-style behaviour for unattended runs only).
- [ ] **Pushover report at end** — uses the existing `BenchmarkSharing`
      Pushover credentials path. Body content: target + filter + total
      frames, kept vs trashed counts, mean / median FWHM and HFR,
      best-and-worst frame thumbnails (optional — Pushover supports
      images), AIsaac-generated 1-sentence summary ("Decent night —
      FWHM tight at 6.1 px median, three Ha 300 s frames lost to wind
      gust at 03:14"). Failure path also pushes ("AstroBlink couldn't
      score session X — reason: …") so silent failures don't pile up.
- [ ] **AIsaac comment** — short generated paragraph from the session's
      QualityBreakdown distribution, group counts, and any sanity-check
      flags. Re-uses the existing AIsaac system prompt / community
      baseline context. Cap response at ~400 chars to fit Pushover.
- [ ] **Console / log artefact** — alongside `*.finished.json`, write a
      sibling `*.report.txt` with the full triage breakdown for the
      user's records (in case they want more detail than the Pushover
      blob).
- [ ] **Manual "run now" trigger** — settings panel button to point at
      a specific manifest and run the full pipeline against it (useful
      for re-runs and debugging the JSON schema).
- [ ] **Throttle / serialise** — only one unattended run at a time even
      if multiple manifests appear simultaneously (NAS folder with
      backlog). FIFO queue. Visible in a small status badge in the
      window if/when the user does open the app.

### Imaging Calendar / Planner
- [ ] Monthly calendar view with moon phases and darkness hours
- [ ] Target altitude curves per night from user's location
- [ ] Moon proximity warnings per target
- [ ] "Best targets tonight" ranking
- [ ] Requires: altitude/azimuth calculator (RA/Dec + lat/lon + LST)

### WBPP File Organizer
- [ ] Auto-organize triaged files into WBPP-compatible directory structure
- [ ] Naming convention enforcement for PixInsight WeightedBatchPreProcessing
- [ ] One-click export after culling

### Built-in Plate Solving
- [ ] Superfast local plate solve for all loaded frames
- [ ] Enables accurate decentered-target detection without pre-existing CRVAL headers
- [ ] Must run during prefetch without blocking navigation
- [ ] Approaches: index-based solver (astrometry.net style) or GPU-accelerated star pattern matching
- [ ] Would enable mosaic planning and astrometric quality checks

### UI Polish — v5.25.1 (SHIPPED)

**Blink Controls:**
- [x] Blink delay dropdown widened (60→72pt) + 0.05s option added. Default stays 0.1s
- [x] P key to toggle play/pause auto-blinking

**Zoom:**
- [x] Minus key zoom goes down to 5% (was 25%), 5% steps below 25%
- [x] Compare window: Cmd+1 (100%) and Cmd+2 (200%) quick zoom, +/- zoom keys, 0 to reset

**Compare Window:**
- [x] C key toggles star circle overlay on/off (shared state with UI toggle)
- [x] Metadata redesign: BEST (green) / SELECTED (orange) bold labels, one-line summary (Filter, Exposure, Cam-Temp, Night, Time), smaller filename below. Centered metric comparison bar (Stars, FWHM, HFR, Ecc, SNR) with green vs orange coloring.

### Tilted-Plane Background in GPU PSF Fit — ABANDONED R&D

Investigated 2026-04-17 against the external user's moonlit-B-filter
NGC 2251 issue. Adding the tilted-plane background to `psf_fit_gaussian`
+ gradient pre-subtraction in `computeFWHMGaussian` made FWHM *worse*
(11.88 → 13.20). Root cause turned out to be star-detection
contamination (noise peaks on bright background), not a gradient bias
in the Gaussian fit — fixed via the v21 full-res saturation filter +
peak-SNR gate (commit 3d506b4) instead.

The technique is theoretically sound for genuine gradient-only cases
(non-crowded fields, moderate moon) but our existing pipeline already
covers those well. Re-opening would need a real test corpus where the
existing approach demonstrably fails — and so far we don't have one.
Closing this slot to declutter the planned-features list. The 2026-04-17
git stash and the v21 fix commit (3d506b4) cover the alternative path
that actually worked. (Note: the original plan codename
`mutable-singing-glacier.md` has since been re-used for the
Curation-Driven Threshold Learning Phase 2 plan, so don't expect that
file to still describe the tilted-plane work.)

### History Window Chart Improvements
- [x] Y-axis percentile clamping — P2/P98 range, outliers clamped
- [x] Fixed window-width charts — no horizontal scrolling
- [x] Summary cards row (Frames, Nights, Best FWHM, Trash Rate, Targets)
- [x] X-axis chronological sorting — Date-based, not categorical strings
- [x] Filter name normalization — L/LE/Lext → "L", H→Ha, etc.
- [x] "All Setups" = scatter dots (no spaghetti lines)
- [x] 6 KPI charts: Score, Efficiency, Performance, Conditions, Progress, Setups
- [x] Legends on all charts explaining colors
- [x] Target name enrichment — 300+ targets (all Messier, major NGC/IC/SH2/Barnard/Abell/vdB/LDN)
- [x] Moon impact split by broadband vs narrowband
- [x] Equipment Health per-setup warning
- [x] **Hover tooltips** — chartOverlay + GeometryReader on Score/Efficiency/Performance charts
- [x] **Time range selector** — All/3M/6M/9M/12M/24M/36M filter in header bar
- [x] **Rolling average window picker** — 5/10/20 sessions (segmented on Performance chart)
- [x] **Integration Progress rethink** — hours not frames, per-filter stacked bars, detail annotations
- [x] **Chart clipping** — `.clipped()` on all chart plot areas prevents bar overflow
- [x] **Rich tooltips** — Score/Efficiency show targets, filters, FWHM, moon%, "Likely:" cause for bad nights
- [x] **Performance tooltip** — per-setup FWHM breakdown when "All Setups" selected, orange highlight on outliers
- [x] **Conditions redesign** — multi-factor X-axis: Moon/FWHM/Temp/Bortle segmented picker, nearest-point hover with full breakdown
- [x] **Setups tooltip** — frame count, date range, trash rate, targets per setup on bar hover
- [x] Monthly aggregation when date range >6 months
      (`FrameHistoryModel.useMonthlyAggregation` + per-chart wiring;
      visible indicator at `FrameHistoryWindow.swift:131` "Showing
      monthly averages (date range >6 months)").
- [x] Historical median reference line (dashed horizontal) on
      Session Score chart. `FrameHistoryModel.allTimeMedianSessionScore`
      computes the median of the current filtered selection (≥5 sessions
      gate). `SessionScoreChart` renders a `RuleMark` with annotation
      `"median N"` when available. Legend updated to call out the line.

### AIsaac Session Planner
- [x] "Plan Tonight" context — moon phase, twilight times, target integration status, filter gaps
- [x] Astronomical twilight timing from SunCalculator (15min sampling)
- [x] Filter recommendation based on moon phase + target history
- [x] Recent performance trend (last 2-3 sessions FWHM/retention in prompt)
- [x] Weather-adaptive advice (wind→shorter exp, humidity→dew warning, moon→narrowband)
- [x] Setup awareness (dome vs portable guidance in system prompt)
- [x] Meteoblue weather integration via Supabase Edge Function
      (`AstroTriage/AIsaac/AIsaacWeather.swift` — `fetchMeteoblue(lat:lon:)`
      is the sole weather path; 7Timer + Open-Meteo retired in the v6.x
      migration per `ReleaseNotesWindow.swift:118`). Cloud layers
      (low/mid/high), visibility, fog probability, 7-day hourly forecast
      with NOW marker and per-hour hover detail card. Powered-by credit
      shown in `TargetDatabaseWindow.swift:435`. Open-Meteo is NOT a
      fallback in the live path — Meteoblue failure returns nil; if a
      fallback is desired later, the helper that does the network call
      is the place to add it. Clear Outside seeing forecast remains an
      option but Meteoblue's multi-factor heuristic
      (`AIsaacWeather.swift:60`) covers the same ground today.

### Frame History Re-Analysis
- [x] Detect stale records: `FrameHistoryDatabase.staleRecordCount()` /
      `fetchStaleRecords()` use `algorithmVersion < kAlgorithmVersion`
- [x] UI indicator in History window: banner with count + currently-running
      v\(kAlgorithmVersion) (FrameHistoryWindow.swift:91)
- [x] "Re-analyze" button that re-runs quality scoring on stale records:
      `FrameHistoryModel.reAnalyzeStaleRecords()` reconstructs ImageEntries
      from stored metrics, runs `QualityEstimator.computeScores`, batch-writes
      tier + zScore + version. Frames in too-small groups get a
      version-only bump via `bumpAlgorithmVersion(fileHashes:)` so they
      stop showing as stale. Progress reporting: 33% conversion / 66%
      scoring / 100% writeback.
- [x] Batch re-analysis for Archive Scanner results (background, resumable):
      `reAnalyzeStaleRecords()` now writes results in 500-record chunks so
      a mid-pass crash loses at most the in-flight chunk; remaining chunks
      resume on next run because their records still satisfy
      `algorithmVersion < kAlgorithmVersion`. Scoring stays one-shot to
      preserve cross-group invariants (Stage 1.5 session sanity, calibration
      floor) — chunking applies only to the post-scoring DB writes.
- [ ] Auto-prompt on session load if DB has older-version scores for
      frames in the just-loaded session: query `staleRecordCount` filtered
      by the session's file hashes and surface a small notice or status-bar
      hint pointing at History → Re-Analyze. Needs a new DB query
      `staleRecordCount(forFileHashes:)`.

### SSWEIGHT Reset / Removal
- [x] Option to remove or reset SSWEIGHT keywords from FITS/XISF headers
      — Batch Rename (Cmd+Shift+R) → scope "Delete Key" → keyword
      "SSWEIGHT" or "PSFSWGHT" wipes the keyword in-place via the
      `delete_xisf_keyword` / `delete_fits_keyword` C bridge
      (`AstroTriage/Engine/BatchOperations.swift:395`/`:410`,
      `TriageViewModel.swift:1179` documents the path).
- [x] Undo path: re-running the same Batch Rename "Delete Key" pass is
      idempotent — keywords absent stay absent, no error. Equivalent to
      "I want this gone; do it again if I'm not sure" without dedicated
      undo state.
- [x] Batch (whole session) works via the existing Batch Rename UI.
- [ ] Per-file context menu — open. Would be one-line trivial to add but
      the Batch Rename path with a one-row selection already covers the
      single-frame case, so deferring until there's a real ergonomic
      complaint.
- [ ] CSV backup file cleanup (`AstroBlinkV2_SSWEIGHT.csv`) — open.
      Removing keywords from the headers does NOT delete the CSV. The
      CSV records what was written at scoring time and serves as a
      forensic record; keeping it is arguably correct ("here's what we
      wrote, regardless of whether it's still in the headers"). Decision
      pending — leave as-is OR auto-delete on Batch-Rename-Delete-Key
      with confirmation prompt.

### PSFSignalWeight Compatibility — SHIPPED
- [x] PSFSWGHT keyword written alongside SSWEIGHT in FITS / XISF headers
      (`TriageViewModel.swift:1131` / `:1137`).
- [x] Formula: `clamp(0, 100, log10(psfFluxSum / noiseMAD²) × 10)` — uses
      ΣPSFFlux from GPU psf_fit_gaussian (Shaders.metal) and noiseMAD
      already computed by STFCalculator.measureNoise. PixInsight 1.8.9+
      SubframeSelector compatible (`AIsaacContextBuilder.swift:716`).
- [x] CSV backup column in `AstroBlinkV2_SSWEIGHT.csv` next to SSWEIGHT
      (`TriageViewModel.swift:1095`).
- [x] Removable via Batch Rename (Cmd+Shift+R) → scope "Delete Key" →
      keyword "PSFSWGHT" (same path as SSWEIGHT — uses
      `delete_xisf_keyword` / `delete_fits_keyword` C bridge).
- [x] Release notes call-out: "PixInsight 1.8.9+ compatible PSFSWGHT
      keyword written alongside SSWEIGHT. More robust than SNRWeight —
      PSF flux inherently rejects hot pixels and satellites."
      (`ReleaseNotesWindow.swift:179`).

### False Positive Reporting
- [ ] Right-click → "Report Wrong Detection" on any garbage/trash frame
- [ ] Upload to Supabase: full QualityBreakdown (z-scores, garbage reasons, tier), setup fingerprint, filter, exposure, FL, pixel size, all metrics, algorithm version
- [ ] Include 512px JPEG thumbnail (STF-stretched preview, downscaled, ~50-100KB) for visual verification
- [ ] Anonymous — setup fingerprint is already anonymized SHA256, no filenames/paths
- [ ] Dashboard/admin view to analyze reports: which rules produce most false positives, per-setup patterns
- [ ] Feeds into Community Detection Phase 2 (agreement learning) and future ML training data
- [ ] Could also allow reporting false negatives (good frames that should have been flagged)

### ~~Benchmark Sharing~~ ✓ (shipped)
- [x] Upload/compare stack benchmarks via Supabase
- [x] Community leaderboard for stacking performance

### Community Detection Learning
- [x] **Phase 1: Upload & Bootstrap** — shipped v5.3.0
  - [x] `CommunityBaseline.swift` — model structs
  - [x] `CommunityDetectionService.swift` — upload/download/caching
  - [x] `QualityEstimator` — `isCommunityFloorLocked`, community floor
  - [x] `TriageViewModel` — wire upload + fetch
  - [x] `AppSettings` — `communityLearning` toggle (opt-in)
  - [x] `FileListView` — gray lock badge
  - [x] `ContentView` — clickable status bar icon with tooltips
  - [x] Supabase: table + RPC + validation trigger + admin RPCs
  - [x] `Tests/CommunityDetectionTests.swift` — 15 tests
  - [x] AIsaac — community context in system prompt
        (`AIsaacContextBuilder.communityBlock(for:)`,
        `CommunityDetectionService.cachedCommunityBaseline(fingerprint:)`).
        Telemetry-gated, sync-only (no network from the prompt path),
        skips silently when the in-memory baseline cache has no match
        for the current setup's pixel-scale class. Includes pixel-scale
        center, contributing-session + machine counts, and per-filter
        community medians (FWHM / stars / SNR / trailing / retention)
        for whichever filters the user is shooting tonight.
- [ ] **Phase 2: Agreement Learning** — future (adjust thresholds from community override rates)
- [ ] **Phase 3: Contextual Priors** — future (empirical Bayesian metric weights)

### Curation-Driven Threshold Learning (Phase 2) — SHIPPED 2026-05-04 (kAlgorithmVersion 27)

**Problem (from 2026-04-16 curation baseline):** 192 of 417 false
positives (46%) were z-score-only trash — combinedZ < -2.0 with no
Stage 1 reason. The static -2.0 threshold was too aggressive for
some setups.

**Solution:** Grid search on the user's curated star ratings finds
per-setup soft offsets to two QualityEstimator tier cutoffs.

- **Borderline offset** ∈ [-0.8, +0.8] adjusts thresholdBorderline
  (-2.0). Asymmetric cost: FP × 1.5 + FN × 2.5 (false negatives —
  keeping a 1★ frame — punished harder). Tie-break favors offset=0.
- **Trailing ceiling offset** ∈ [-0.15, +0.20] adjusts
  absoluteTrailingCeilingScore (0.60).
- Activation gate: `LearnedThresholds.learningThreshold = 50` with ≥10
  at 1★ and ≥10 at 3★ for borderline; ≥20 trailing-flagged frames for
  trailing. Below the gate the static defaults apply.
- Non-learnable: decentered / backgroundAnomaly / twilight reasons are
  excluded from the search regardless of star rating (the curator can't
  reliably judge those from the zoomed thumbnail we present).

**Hard backstops preserved:** Stage 1 garbage rules and the
isLockedKeep calibration floor are untouched. The z-score COMPUTATION
(median / MAD / metric weights) is unchanged.

**Provenance:** Status bar appends
`[thresholds adapted from N curated frames]` after a session is scored
using non-default offsets so the user can tell whether the cutoffs are
coming from their curation or from QualityEstimator's defaults.

**Implementation actually shipped (vs the original 8-step plan):**
- [x] Step 1: `CalibrationDatabase.swift` — `LearnedThresholds` struct
      + `CalibrationProfile.learnedThresholds` field +
      `updateLearnedThresholds(_:for:)` method.
- [x] Step 2: `ThresholdLearner.swift` (NEW, ~240 LOC) — grid search
      engine with non-learnable exclusions and tunable cost weights.
- [x] Step 3: `FrameHistoryDatabase.curatedFrameRecords(setupHash:)`.
- [x] Step 4: `QualityEstimator.swift` — `learnedThresholds:
      LearnedThresholds? = nil` parameter; effective thresholds applied
      in Rule 6a (trailing ceiling) and the borderline tier assignment.
- [x] Step 5: `SessionOrchestrator.commitSession()` triggers learning
      off the main thread; `SessionOrchestrator+Scoring.recomputeQualityScores()`
      pulls + passes the thresholds. (Plan said TriageViewModel; the
      Patch 2 split moved both call sites to SessionOrchestrator.)
- [x] Step 6: `FrameRecord.swift` — kAlgorithmVersion 26 → 27 (plan
      said 20 → 21; we'd accumulated 6 versions of intermediate work).
- [x] Step 7: `ALGORITHM_CHANGELOG.md` — v27 entry with full rationale,
      activation gates, non-learnable exclusions, and hard-backstop
      guarantees.
- [x] Step 8: `Tests/ThresholdLearnerTests.swift` (NEW, 6 tests) —
      optimal-offset detection, minimum-data gating, max-offset clamp,
      non-learnable exclusion, tie-break-toward-zero,
      trailing-grid-search bounds. 293 tests / 1 skipped / 0 failures.

**Full plan reference:** `~/.claude/plans/mutable-singing-glacier.md`
**Curation data:** 4,550 blind-curated frames in Supabase; baseline
analysis at `project_curation_baseline_2026_04_16.md`.

### Onboarding / Welcome Screen
- [x] First-launch onboarding splash — 4 marketing pillars (Speed Demon, Data Nerd, Community Learner, Power User) with hover details (v5.19.1)
- [x] Accessible via About menu, non-dismissable on first launch, "Don't show on startup" checkbox (v5.19.1)
- [ ] Interactive tutorial: "Open a folder → review quality → mark bad frames → pre-delete"
- [ ] Equipment profile setup (telescope, camera, focal length) during onboarding for immediate calibration

### Community Calibration — Site-Aware Comparison
- [ ] **Location/Bortle metadata** — Store observing site Bortle class, lat/lon, altitude alongside calibration data. Setup fingerprint stays equipment-only, but comparisons can be filtered by observing conditions.
- [ ] **Raw-data ice/frost detection** — Radial brightness profile analysis in the scoring pipeline (before auto-stretch). Far more reliable than post-stretch VLM/mosaic analysis. Star count is the best metadata proxy for optical cleanliness.

### PixInsight Integration Plugin
- [x] **PJSR Bridge Script** — imports triage results (separate repo, shipped)
- [ ] Deeper integration: launch PixInsight WBPP directly from AstroBlink with pre-configured file list
- [ ] Two-way sync: read PixInsight SubframeSelector weights, write AstroBlink SSWEIGHT back
- [ ] PixInsight process icon export for batch processing pipelines

---

## Performance Gates (verified)

| Scenario                             | Target        | Method                   |
|--------------------------------------|---------------|--------------------------|
| First Display (cold, 50MP XISF LZ4) | < 200ms       | Stopwatch from key press |
| Next Image (Cache-Hit)               | < 32ms        | MTLCommandBuffer.gpu*Time|
| Session Load 500 Files (scan + meta) | < 3s          | os_signpost              |
| Thumbnail Batch 100 Files            | < 30s         | Timer                    |
| GPU Utilization during Prefetch      | > 80%         | Metal System Trace       |
| RAM at 1000-File Session             | < 10 GB       | Activity Monitor         |
