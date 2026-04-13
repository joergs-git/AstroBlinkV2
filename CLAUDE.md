# AstroTriage – macOS Image Culling Tool
## Claude Code Master Document

---

## Project Summary

Standalone macOS App für schnelles visuelles Culling von Astrofoto-Sessions.
Ersetzt PixInsight Blink durch purpose-built Triage-UI mit Pre-Delete-Staging,
FITS/XISF-Header-Metadaten-Spalten, NINA-Filename-Token-Parser, Wildcard-Filter
und konsistenter STF-kompatiblen Auto-Stretch für visuelle Vergleichbarkeit.

**Primäres Zielgerät:** Mac Studio M2/M3 Ultra (24-32 CPU-Kerne, 60-80 GPU-Kerne,
bis 192 GB Unified Memory, 800 GB/s Memory Bandwidth). Lauffähig ab MacBook M1.

---

## Tech Stack

| Layer              | Technology                          | Grund                                               |
|--------------------|-------------------------------------|-----------------------------------------------------|
| UI                 | SwiftUI + AppKit hybrid             | NSTableView für 1000+ Zeilen ohne Stutter           |
| Rendering          | Metal Compute + MTKView             | GPU STF-Stretch; 50MP < 8ms auf M2 Ultra            |
| XISF               | libxisf (C++17, static)             | Einzige reife Open-Source XISF 1.0 Impl             |
| FITS               | cfitsio (C, static)                 | NASA Referenz, fpack transparent                    |
| C++ Bridge         | SPM C/C++ Target                    | Sauber, kein fragiles ObjC Bridging                 |
| DB                 | SQLite via GRDB.swift               | Metadaten-Cache, Pre-Delete-State                   |
| Thumbnail          | HEIF via ImageIO (on-disk)          | Schnelles Re-Open, pre-stretched                    |
| Min macOS          | 14 Sonoma                           | SwiftUI Charts zoom, onChange new syntax             |
| CPU Parallelismus  | GCD + Swift async/await             | P-Core vs E-Core QoS-Steuerung                     |
| GPU Parallelismus  | MTLHazardTrackingModeUntracked      | Echter concurrent GPU Kernel Dispatch               |

---

## Apple Silicon Parallelismus – Strategie

### Hardware-Realität (verifiziert, nicht geraten)

**Apple GPU ≠ NVIDIA. Kritische Unterschiede:**

1. **Max. 2 concurrent Command Buffer Lanes** auf Apple GPU.
   Mehr als 2 MTLCommandQueues bringen keinen Gewinn.

2. **Echter GPU-Parallelismus ERFORDERT `MTLResourceHazardTrackingModeUntracked`.**
   Standard Hazard Tracking serialisiert alle Buffers. Ohne dieses Flag: keine Parallelität.

3. **Unified Memory = Zero-Copy.** CPU schreibt in `MTLStorageModeShared` Buffer,
   GPU liest direkt – kein memcpy zwischen CPU/GPU-Speicher.

4. **GCD QoS → Core-Typ-Steuerung:**
   - `.userInitiated` → P-Cores (Decode, Compute)
   - `.utility` → E-Cores (I/O, DB, Thumbnails)
   - `.background` → E-Cores (Disk-Cache schreiben)

5. **Memory Bandwidth = eigentlicher Bottleneck** für 50MP Images auf M2 Ultra.
   Ziel: Texture-Copies minimieren, Zero-Copy wo immer möglich.

### Parallelismus-Architektur

```
CPU-DECODE PIPELINE (GCD, P-Cores, qos: .userInitiated):

  PrefetchQueue
  ├── Worker 0: decode Image[i-1]  → MTLBuffer (StorageModeShared)
  ├── Worker 1: decode Image[i]    → MTLBuffer (StorageModeShared)  ← current
  ├── Worker 2: decode Image[i+1]  → MTLBuffer (StorageModeShared)
  └── Worker 3: decode Image[i+2]  → MTLBuffer (StorageModeShared)

  Concurrent Decode Count = min(performanceCoreCount, 4)
  [M2 Ultra: 16 P-Cores → cap at 4, I/O bound anyway]

GPU PIPELINE (2 MTLCommandQueues, concurrent via Untracked):

  Queue A (display): Aktuelles Bild STF → MTKView drawable
  Queue B (prefetch): Nächstes Bild STF → Cached MTLTexture
  → Beide laufen GLEICHZEITIG auf GPU

THUMBNAIL BATCH (GCD, E-Cores, qos: .background):
  concurrentPerform(iterations: count) {
    // STF-Params aus Cache → render → HEIF schreiben
    // Max 4 concurrent (SSD I/O Limit)
  }
```

### Memory Budget

```
Beispiel: Mac Studio M2 Ultra, 64 GB RAM

Pixel-Größen (ZWO ASI6200MM, 9576×6388, 16-bit mono):
  uint16 raw decoded:    ~116 MB / Bild
  float32 im Shader:     berechnet on GPU, kein CPU float32 buffer
  BGRA8 display texture: ~23 MB / Bild

App RAM-Budget (konservativ für 64 GB System):
  Raw MTLBuffer Cache:   4 GB → ~34 Bilder gecacht
  Texture Cache:         2 GB → ~86 Display-Texturen
  DB + UI:               ~200 MB
  Total App:             ~6.5 GB

Auf 128 GB System: Cache-Limits automatisch verdoppeln
→ ProcessInfo.processInfo.physicalMemory zur Laufzeit abfragen
```

---

## Directory Structure

```
AstroTriage/
├── Package.swift
├── Sources/
│   ├── AstroTriage/
│   │   ├── App/AstroTriageApp.swift
│   │   ├── UI/
│   │   │   ├── ContentView.swift           # HSplitView root
│   │   │   ├── FileListView.swift          # NSTableView wrapper
│   │   │   ├── ImageViewerView.swift       # MTKView + info overlay
│   │   │   ├── PreDeletePanelView.swift    # _predel/ Tab
│   │   │   ├── FilterBarView.swift         # Wildcard + Range Filter
│   │   │   └── ColumnPickerView.swift
│   │   ├── Engine/
│   │   │   ├── TriageEngine.swift          # Swift Actor (central state)
│   │   │   ├── PrefetchQueue.swift         # GCD parallel decode
│   │   │   ├── STFProcessor.swift          # CPU reference impl (tests)
│   │   │   ├── MetadataExtractor.swift     # FITS/XISF header parse
│   │   │   ├── NINAFilenameParser.swift    # Regex token parser
│   │   │   ├── NINACSVReader.swift         # ImageMetaData.csv
│   │   │   ├── FileOperationLog.swift      # Undo stack
│   │   │   ├── ThumbnailCache.swift        # Disk + RAM cache
│   │   │   ├── SessionScanner.swift        # Folder scan + FSEvents
│   │   │   ├── TargetCatalogService.swift  # Supabase fetch + 24h disk cache
│   │   │   └── AltAzCalculator.swift       # Alt/Az computation + visibility curves
│   │   ├── Model/
│   │   │   ├── ImageEntry.swift
│   │   │   ├── TriageState.swift           # .active/.preDelete/.deleted
│   │   │   ├── FilterSpec.swift
│   │   │   └── ColumnDefinition.swift
│   │   └── Metal/
│   │       ├── Shaders.metal               # STF compute + debayer kernel
│   │       ├── MetalRenderer.swift         # Dual-Queue, MTKView delegate
│   │       └── TexturePool.swift           # MTLTexture reuse
│   │
│   ├── ImageDecoderBridge/
│   │   ├── include/ImageDecoderBridge.h    # C API
│   │   └── ImageDecoderBridge.cpp          # libxisf + cfitsio wrapper
│   │
│   ├── libxisf/                            # vendored
│   └── cfitsio/                            # vendored
│
├── Tests/
│   ├── STFProcessorTests.swift
│   ├── MetadataExtractorTests.swift
│   ├── DecoderTests.swift
│   └── FileOperationTests.swift
│
└── TestImages/                             # 1 Datei pro Format-Variante
    ├── test_xisf_uncompressed.xisf
    ├── test_xisf_lz4.xisf
    ├── test_xisf_lz4hc.xisf
    ├── test_xisf_zlib.xisf
    ├── test_xisf_zstd.xisf
    ├── test_xisf_shuffle_lz4.xisf         # ByteShuffle + LZ4
    ├── test_fits_plain.fits
    ├── test_fits_fpack.fits
    ├── test_fits_osc_rggb.fits             # ZWO ASI676MC
    └── test_xisf_osc_rggb.xisf
```

---

## Star Trailing Detection — Orientation Consensus (v4.2.0)

**Industry first: no other astrophotography tool uses this approach.**

### Problem
Traditional eccentricity measurement (fixed 3px aperture, global threshold) fails:
- Misses star trails (measures only bright core, not wings)
- False positives on fast optics (f/2.2 RASA produces naturally non-circular PSFs)
- No distinction between tracking errors and optical aberrations

### Solution: Three-Layer Detection

```
Layer 1: Adaptive Aperture (StarMetricsCalculator.swift)
  - Eccentricity radius: min(15, max(5, medianFWHM × 2.5))
  - Captures PSF wings where trailing is visible
  - Extracts position angle (PA) and axis ratio per star
  - Bright stars: annular measurement (skip saturated core)
  - 60 measured stars, 10px crowding, full-res refinement

Layer 2: Orientation Consensus (TrailingAnalyzer.swift)
  - Circular statistics on star PAs (doubled-angle method)
  - Consensus = fraction of stars with PA within ±20° of mean
  - >50% consensus = systematic tracking error
  - Random PAs = optical aberration (don't penalize)

Layer 3: Focal-Length Baseline (TrailingAnalyzer.swift)
  - baseline_ecc = 0.8 / sqrt(focalLength / 200)
  - 468mm → 0.52 (short FL, more aberration normal)
  - 2423mm → 0.23 (long FL, tight PSF expected)
  - trailingScore = excessEcc × consensusMultiplier

Layer 4: Filter-Aware Penalty (QualityEstimator.swift, v5.2.0)
  - Detection is filter-independent (physics is the same)
  - PENALTY RESPONSE scales by filter type:
    Narrowband (Ha/OIII/SII/Hbeta/NII): × 0.3 — slight trailing
      barely affects diffuse emission, don't waste precious integration
    RGB broadband (R/G/B):               × 0.6 — moderate strictness
    Luminance (L):                        × 1.0 — full strictness
    Unknown / exotic:                     × 0.7 — conservative default
  - Scales: z-score weight, garbage thresholds, rescue rules, SSWEIGHT
  - Rationale: narrowband PSFs already bloated, science target is nebula
    emission not point sources, 300-600s exposures are expensive
```

### Key Files
- `AstroTriage/Engine/StarMetricsCalculator.swift` — Adaptive aperture, PA + axis ratio
- `AstroTriage/Engine/TrailingAnalyzer.swift` — Consensus engine, FL baseline (filter-independent)
- `AstroTriage/Engine/QualityEstimator.swift` — Filter-aware trailing penalty, trailingScore scoring
- `Tests/StarAnalyzerTests.swift` — Multi-setup validation harness

### Validation Results (5 setups, 1455 frames)
- NGC7635 (RASA 620mm): excellent separation (good <0.39, bad >0.54)
- IC63 (RC12 2423mm): good separation (most bad >0.55)
- M81 (140mm 904mm): moderate (worst bad=1.00, some overlap)
- NGC3184 (85mm 468mm): correctly 0.00 (bad=defocus not trailing)
- ngc7000 (RASA 620mm): moderate (bad 0.19-0.63)

---

## Session Metrics & History Improvements (v5.20.5)

### Temperature vs HFR Scatter Plot (Metrics Tab)
- New "Metrics" tab in Frame History window
- X-axis: ambient temperature (°C), Y-axis: HFR (px)
- Per-filter colored scatter points with 1°C-binned rolling average trend line
- Night picker: "All Nights" (nightly medians) or specific night (per-frame detail)
- Filter scope: All / Narrowband / Broadband / per-filter
- Shows focus drift correlation with temperature changes

### Rain Forecast in Target Catalog
- Hourly precipitation probability bars below cloud cover chart
- Blue/cyan/indigo color scale, same past/current/future styling as cloud bars
- Only shown when any hour has precipitation > 0%

### Setup Management (Gear Icon)
- Rename (nickname), fix focal length (override bad plate-solve values)
- Merge Into: combine one setup into another (fixes duplicates)
- Delete Setup: permanently remove bad entries with confirmation
- Orphaned sessions auto-cleaned on History window load

### Destroy All DB Data (Advanced Menu)
- Window → Advanced → Destroy All DB Data
- Two safety confirmations before execution
- Destroys: local SQLite, iCloud backups, calibration files

### History Chart Improvements
- Removed X-axis scrollbars from Score, Efficiency, Performance charts (fit to window)
- Educational tooltip text on all 6 chart types explaining metrics and caveats
- Overall average/median/MAD stats shown in tooltips for numerical comparison
- Tooltips flip to left side when cursor near right window edge
- Tooltip font scaled 1.2x for readability
- Rolling average options: 5/10/20/50/100 (was 5/10/20)
- Fuzzy hover detection: nearest-point within 30 days (was exact day match)

### FOCPOS Header Extraction
- `focusPosition: Double?` extracted from FOCPOS/FOCUSPOS FITS header
- Stored on ImageEntry for autofocus event detection

### Key Files
- `AstroTriage/Engine/FrameHistoryModel.swift` — Metrics data, trend line, chart stats
- `AstroTriage/UI/FrameHistoryWindow.swift` — Scatter chart, setup management, tooltip improvements
- `AstroTriage/UI/TargetDatabaseWindow.swift` — Rain forecast bars
- `AstroTriage/Engine/FrameHistoryDatabase.swift` — Setup merge/delete/fix FL, destroy all data

---

## Pre-Caching Pipeline Optimization (v4.5.0)

### Dual-Queue Architecture
```
PrefetchCache:
  priorityQueue (max 2 concurrent, .userInteractive QoS)
    → current image, ±1, ±2 neighbors (on navigation to uncached image)
  backgroundQueue (max 6 concurrent, .userInitiated QoS)
    → all other images (bulk fill)
```

- Priority queue cancels previous ops on each navigation, submits uncached neighbors
- Background queue checks for priority-filled entries to skip duplicates
- `onPriorityPreviewReady` callback triggers `displayCurrentImage()` auto-refresh

### Async GPU Preview
- `PreviewGenerator.generatePreviewAsync()` uses `addCompletedHandler` on final command buffer
- Worker thread freed immediately after GPU dispatch (~2-3ms saved per image)
- Synchronous `generatePreview()` preserved for backward compatibility

### Key Files
- `AstroTriage/Engine/PrefetchCache.swift` — Dual queue, prioritizeCaching(), async pipeline
- `AstroTriage/Metal/PreviewGenerator.swift` — generatePreviewAsync() with completion handler
- `AstroTriage/Engine/TriageViewModel.swift` — Priority queue wiring, focusTableAfterDelay fix
- `AstroTriage/UI/FileListView.swift` — Visible-row-only reload, lightweight selection color update

---

## Stacking Improvements (v4.4.0)

### Min/Max Pixel Rejection
- `warp_accumulate` shader tracks per-pixel per-channel min/max via buffers 7,8
- Normalization: `(sum - min - max) / (count - 2)` when count >= 3, simple mean otherwise
- Removes satellite trails (1 bright frame) and hot pixels automatically

### Lanczos-3 Interpolation
- `warp_accumulate_lanczos` kernel: 6x6 sinc-windowed interpolation, 3px margin
- `InterpolationMode` enum on `QuickStackEngineV2` (.bilinear/.lanczos)
- Selectable via segmented picker in stacking progress view

### Adaptive Triangle Matching
- `triangleStarLimit` 15→20 (1140 triangles)
- On failure: retry with limit=25, inlier threshold 15px (was 10px)
- Dramatically reduces alignment failures on wide-dither sessions

### Color Combine
- `ColorCombineEngine.swift` — orchestrates sequential per-filter stacking via QuickStackEngineV2
- Filter alias mapping: "H"→"Ha", "O"→"OIII", "S"→"SII", bandwidth suffix stripping
- Presets: SHO, HOO, HSO, LRGB, HaRGB, Custom (auto-detected from available filters)
- vDSP weighted linear combination for channel mapping (<100ms)
- Luminance blending: ratio-preserving (RGB *= L/Y) for LRGB palettes
- `ColorCombineWindow.swift` — setup panel + result view with per-channel weight sliders

### V1 NormalStacker Removed
- `QuickStackEngine.swift` deleted (781 lines)
- V1 views removed from QuickStackWindow.swift (920 lines)
- V1 toolbar button, overlay, properties, methods removed

---

## Self-Calibration & Convergence (v4.3.0)

### Calibration Database
- **Location:** `~/Library/Application Support/AstroBlinkV2/Calibration/` (one JSON per setup hash)
- **SetupFingerprint:** SHA256(telescope+camera+focalLength+pixelSize), anonymized for Supabase
- **Learning:** Welford's online algorithm for incremental mean/variance/MAD per metric
- **Threshold:** ≥30 frames before absolute quality floor activates
- **Recording:** `recordAction()` on every mark/unmark, `commitSession()` on PRE-DELETE confirm (learns from retained frames)

### Convergence Detection
- Quality spread (std dev of retained z-scores) < 0.3 → "Culling complete"
- SNR stopping: flags when SNR loss % > integration loss %
- Stack readiness: 40% uniformity + 35% SNR retention + 25% floor coverage

### Absolute Quality Floor
- Frames within 1 MAD of learned baseline for ALL metrics → locked KEEP
- Z-scores cannot override locked frames (bumped to at least .good)
- Blue lock badge on quality column icons
- `isLockedKeep` field on QualityBreakdown

### SSWEIGHT & PSFSignalWeight Export
- SSWEIGHT formula: `clamp(0, 100, 50 + qualityZScore*20) * (1 - trailingScore*0.5*filterTrailingMult)`
- PSFSWGHT formula: `clamp(0, 100, log10(psfFluxSum / noiseMAD²) × 10)` — PixInsight 1.8.9+ compatible
- filterTrailingMult: 0.3 (narrowband), 0.6 (RGB), 1.0 (luminance), 0.7 (unknown)
- Locked KEEP frames get minimum SSWEIGHT of 50
- Writes via `write_fits_keyword` / `write_xisf_keyword` (C bridge)
- Deletion via `delete_fits_keyword` / `delete_xisf_keyword` (C bridge, Batch Rename "Delete Key" scope)
- CSV backup: `AstroBlinkV2_SSWEIGHT.csv` in session root (includes both SSWEIGHT and PSFSWGHT)
- Export operates on highlighted files (or all scored if none selected)

### GPU PSF Fitting (v5.11.0 circular, v5.12.0 elliptical)
- Metal compute kernel `psf_fit_gaussian` in Shaders.metal
- Circular Gaussian: I(r) = A·exp(-r²/2σ²) + B, 3 free params
- Gauss-Newton with Levenberg-Marquardt damping, 8 iterations, 11×11 stamps
- Replaces CPU linearized Gaussian FWHM when GPU available
- Fitted amplitude A → accurate PSF flux = 2πAσ²
- **Elliptical Gaussian** (v5.12.0): `psf_fit_elliptical` kernel, 5 free params (A, σx, σy, θ, B)
- 12 iterations, 5×5 Gaussian elimination with partial pivoting
- Eccentricity derived analytically: √(1 - σy²/σx²), PA from θ
- Preferred over image moments when chi² < 1000 (more accurate for well-fitted stars)
- Elliptical PSF flux: 2π·A·σx·σy (more accurate than circular)
- PSF flux z-score replaces star count in Stage 2 combinedZ (fallback to stars when nil)
- PSF Flux column in file list (hideable, formatted as K/M suffixes)

### Dome/Dark Frame Detection (v5.11.0)
- Rule 0b: stars ≥ 10000 + NOT(FWHM>3 AND bg≥0.002), or stars ≥ FL-threshold + noiseMedian < 0.002
  - FWHM + background cross-check prevents false positives on bright nebulae (M42 H-alpha: 14800+ real stars)
- Dark frames excluded from group statistics (medians, z-scores) in pre-pass
- Stage 1 garbage excluded from session sanity P10/P90 benchmarks
- Session sanity requires ≥2 distinct nights (single-night multi-filter is optics, not bad night)

### Target-Aware Quality Scoring (v5.14.0)
- **DeepSkyTargetDatabase** — 229+ deep-sky targets with type classification (galaxy, nebula, cluster, etc.)
- Target name resolution via canonical lookup (handles aliases, catalog prefixes, common names)
- GroupKey uses canonical target names for consistent grouping across naming variations
- **Type-Based Metric Weight Modifiers** — Adjusts metric importance per target type:
  - Galaxies: star count less critical (small angular size), FWHM/trailing more important
  - Nebulae/SHO: star count weight reduced (extended emission dominates)
  - Star clusters: star count highly weighted (stars ARE the target)
- **FL-Aware MAD Floor** — Prevents z-scores from exploding on uniform sessions:
  - FWHM floor: max(0.3px, 0.15 * medianFWHM) — tighter at long FL
  - Stars floor: max(5%, 3% of median) — prevents tiny variations from dominating
- **Planet Exclusion** — Solar system objects (Moon, planets) excluded from quality scoring entirely
  (fundamentally different imaging: short exposures, lucky imaging, no deep-sky metrics apply)

### Key Files
- `AstroTriage/Engine/DeepSkyTargetDatabase.swift` — 229+ targets, type classification, canonical name lookup
- `AstroTriage/Engine/CalibrationDatabase.swift` — Persistence, Welford, fingerprinting
- `AstroTriage/Engine/ConvergenceDetector.swift` — Spread analysis, readiness formula
- `AstroTriage/Engine/QualityEstimator.swift` — Absolute floor, isLockedKeep, GroupKey canonical names, target-aware weights, MAD floor
- `Tests/CalibrationDatabaseTests.swift` — 11 tests
- `Tests/ConvergenceDetectorTests.swift` — 8 tests
- `Tests/ScoringValidationTests.swift` — Target-aware scoring validation

---

## STF Auto-Stretch Algorithmus

**Quelle: PixInsight AutoSTF Script (Juan Conejero, PTeam) – verifizierte Implementierung**

```
Konstanten:
  SHADOWS_CLIP = -1.25    // Sigma-Faktor unterhalb Median
  TARGET_BKG   =  0.25    // Ziel-Background [0,1]

Pro Kanal (RGB unlinked für OSC; mono = single channel):
  1. Subsample: 5% der Pixel zufällig (Seed=42, reproduzierbar)
     → ~2.5M Samples bei 50MP, statistisch korrekt
  2. med  = median(samples)
  3. MAD  = 1.4826 * median(|samples - med|)   // normalized → σ-Schätzung
  4. c0   = clamp(med + SHADOWS_CLIP * MAD, 0.0, 1.0)
  5. mb   = MTF(TARGET_BKG, c0)

MTF(x, m):    // Midtones Transfer Function
  if x == 0: return 0
  if x == 1: return 1
  if x == m: return 0.5
  return (m-1)*x / ((2*m-1)*x - m)

Pixel stretch (Metal Shader, per pixel, parallel auf GPU):
  x   = float(raw_uint16) / 65535.0
  x   = clamp((x - c0) / (1.0 - c0), 0.0, 1.0)
  out = MTF(x, mb)
```

**Metal Kernel Thread-Konfiguration (Apple GPU optimal):**
```swift
let tg = MTLSize(width: 32, height: 32, depth: 1)   // SIMD width 32
let g  = MTLSize(width: (w+31)/32, height: (h+31)/32, depth: 1)
encoder.dispatchThreadgroups(g, threadsPerThreadgroup: tg)
```

**Stretch-Modi:**
- `auto` (default): Jedes Bild individuell → Qualitäts-Vergleich (Schärfe, Sterne)
- `locked`: Parameter vom aktuellen Bild → alle anderen gleich → Helligkeits-Vergleich
- `global`: Session-Median → für Gesamtübersicht (optional)

---

## FITS/XISF Kompression – Vollständige Support-Matrix

| Format | Kompression         | Library   | Notes                              |
|--------|---------------------|-----------|------------------------------------|
| XISF   | Uncompressed        | libxisf   | Standard                           |
| XISF   | LZ4                 | libxisf   | NINA default (schnell)             |
| XISF   | LZ4HC               | libxisf   | NINA Option (besser, langsamer)    |
| XISF   | zlib                | libxisf   | NINA Option                        |
| XISF   | zstd                | libxisf   | PixInsight geplant, libxisf 0.2+   |
| XISF   | ByteShuffle + any   | libxisf   | Kombiniert mit obigen              |
| XISF   | Checksum (SHA-1)    | libxisf   | Transparent beim Lesen             |
| FITS   | Uncompressed        | cfitsio   | Standard                           |
| FITS   | fpack (ZTILE Rice)  | cfitsio   | cfitsio handlet transparent        |
| FITS   | fpack (ZTILE GZIP)  | cfitsio   | cfitsio handlet transparent        |
| FITS   | float32 (BITPIX=-32)| cfitsio   | APP, PixInsight, GraxPert output   |
| FITS   | float64 (BITPIX=-64)| cfitsio   | PixInsight output                  |

**FITS Float Support (v5.14.0):** Decoder checks BITPIX keyword to determine data type.
Integer FITS (BITPIX=16/32) read as TUSHORT. Float FITS (BITPIX=-32/-64) read as TFLOAT
with auto-range detection: values in [0,1] scaled to uint16 range, values >1 assumed
pre-scaled. Fixed in both macOS (`Packages/ImageDecoder/`) and iOS
(`AstroFileViewer-iOS/Packages/ImageDecoder/`) decoders.

---

## NINA Metadaten-Quellen

### FITS/XISF Header Keywords (NINA schreibt diese Standard-Keywords)
```
STARFWHM    – FWHM von angeschlossenem Wetterdatensensor (nicht autofocus HFR!)
CCD-TEMP    – Aktueller Sensort-Temp
FILTER      – Aktiver Filter
FOCPOS      – Fokussierer-Position
FOCTEMP     – Fokussierer-Temperatur
GAIN, OFFSET, EXPOSURE, EXPTIME, OBJECT, DATE-LOC, BAYERPAT, XBINNING
INSTRUME, TELESCOP, CLOUDCVR, HUMIDITY, WINDSPD, DEWPOINT
```

### NINA Filename Tokens (NUR im Dateinamen, NICHT im Header)
```
$$HFR$$       → Regex: HFR(\d+\.\d+)       – Autofokus Half-Flux Radius
$$STARS$$     → Regex: Stars(\d+)           – Detektierte Sterne
```
**WICHTIG:** HFR und StarCount sind bewusst NICHT im FITS Header,
weil es keinen Standard-Keyword gibt (NINA-Entwickler bestätigt).
Primäre Quelle: NINA SessionMetadata Plugin CSV.

### NINA ImageMetaData.csv (SessionMetadata Plugin)
```
Suche nach: ImageMetaData.csv in Session-Ordner oder Parent
Spalten: File, HFR, DetectedStars, GuidingRMSArcSec, ADUMean, ADUStDev
Join: Dateiname (Basename ohne Extension)
Fallback: Filename-Token-Parsing
```

---

## Keyboard-Shortcuts

| Taste            | Aktion                                              |
|------------------|-----------------------------------------------------|
| ← / →            | Prev / Next (stops at boundaries)                   |
| Page Up / Home   | Jump to first image                                 |
| Page Down / End  | Jump to last image                                  |
| Space            | Toggle Pre-Delete mark (single or multi-selection)  |
| Cmd+Backspace    | Move marked files to PRE-DELETE folder              |
| Cmd+Z            | Undo last pre-delete                                |
| S                | Toggle stretch mode (auto/locked)                   |
| K                | Toggle skip-marked during navigation                |
| H                | Toggle hide-marked from file list                   |
| I                | Toggle FITS/XISF header inspector                   |
| D                | Toggle debayer for OSC images                       |
| N                | Toggle night mode (red-on-black)                    |
| Cmd+O            | Open folder                                         |
| 1 / 2 / 3       | Set confidence rating (1-3 stars, same key clears)  |
| A                | Cycle quality feedback (agree/disagree/partly/clear)|
| Double-click     | Reset zoom to fit-to-view                           |

---

## Nicht-Verhandelbare Regeln

1. Keine permanente Löschung ohne Bestätigung + macOS Trash
2. Pre-Delete = physikalischer Filesystem-Move (crash-safe)
3. STF wird nie in Originaldateien geschrieben
4. libxisf + cfitsio: statisch gelinkt (kein dylib für Enduser)
5. `MTLHazardTrackingModeUntracked` auf allen Prefetch-Ressourcen
6. `MTLStorageModeShared` für alle Decode-Buffers (Zero-Copy)
7. Min macOS 14 Sonoma – SwiftUI Charts, onChange new syntax
8. Performance-Gate: < 200ms First Display (Cold), < 32ms nach Cache-Hit

---

## Quality Gates — Scoring Invariants
Jede Änderung an Quality-kritischen Dateien erfordert /validate-scoring vor Commit.
Quality-kritische Dateien: QualityEstimator.swift, TrailingAnalyzer.swift,
CalibrationDatabase.swift, ConvergenceDetector.swift, StarMetricsCalculator.swift,
STFCalculator.swift, ColorCombineEngine.swift (Filter-Mapping).

**Algorithm Versioning (MANDATORY):**
When ANY quality-critical file above is modified (scoring logic, detection algorithms,
metric calculations — NOT UI/display changes), you MUST:
1. Bump `kAlgorithmVersion` in `FrameRecord.swift`
2. Add a detailed entry to `ALGORITHM_CHANGELOG.md` (what changed, why, impact)
3. Commit both together with the logic change
Frame History DB records carry this version — it enables re-analysis of stale records.
Scoring-Richtung (NIEMALS invertieren)
MetrikMesswertRichtungZ-Score Vorzeichen in combinedZFWHMPixelsniedrig = gutNEGIERT (−z)HFRPixelsniedrig = gutNEGIERT (−z), nur Fallback wenn kein FWHMStarsAnzahlhoch = gutDIREKT (+z)Noise MAD[0,1]niedrig = gutNEGIERT (−z)Trailing[0,1]niedrig = gutNEGIERT (−z)
SNR = noiseMedian / noiseMAD — höher = besser.
noiseMedian (Hintergrund-Level) ist KEIN Rauschen. Hoher Hintergrund bei niedrigem MAD = hoher SNR.
Harte Invarianten

isLockedKeep == true → Tier kann NICHT unter .good fallen
Stage 3 Rescue Rules → NUR Promotion, NIE Demotion
FWHM und HFR NIE gleichzeitig in combinedZ (95% korreliert)
fwhmRulesOutTrailing: FWHM ≤ median×1.15 → kein Trailing-Garbage möglich
R7 Background Anomaly: NUR positive Abweichung. Dunklerer Himmel = BESSER
Calibration Floor: ≥30 Frames UND ≥2 Metriken UND ALLE müssen passen
Star Count Anomaly R6: FWHM/HFR-Cross-Check pflicht (Satelliten-Schutz)
Z-Score Cap ±3.0 — einzelne Metrik kann nicht allein Trash erzwingen

Golden Set Regression (7 Setups, 1638 Frames)
Maximale erlaubte Abweichung: ±2% pro Setup ohne explizite Begründung.
Referenzdaten: wiki/quality-testing-log.md
Vor jedem Release
/pre-release ausführen. Alle 5 Phasen müssen PASS sein.

## Projekt-Dokumentation

Bei Bedarf diese Dateien im Projekt-Root lesen:
- `CAVEATS.md` — Bekannte Einschränkungen und Workarounds
- `LESSONS_LEARNED.md` — Vergangene Fehler, die nicht wiederholt werden dürfen
- `RESOURCES.md` — Externe Referenzen und Abhängigkeiten
- `TODO.md` — Offene Aufgaben und geplante Features
- `PERFORMANCE.md` — Performance-Benchmarks und Optimierungen
