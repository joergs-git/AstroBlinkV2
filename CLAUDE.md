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
| Min macOS          | 13 Ventura                          | Metal stabil, Swift Concurrency stabil              |
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
│   │   │   └── SessionScanner.swift        # Folder scan + FSEvents
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
| Double-click     | Reset zoom to fit-to-view                           |

---

## Phasen-Übersicht

| Phase | Inhalt                              | Ziel-Dauer |
|-------|-------------------------------------|------------|
| 1     | Skeleton + Decoder + Basis-Render   | 2 Tage     |
| 2     | STF Metal Pipeline + RAM Cache      | 2 Tage     |
| 3     | File List + Metadaten + DB          | 2 Tage     |
| 4     | Triage Workflow (Pre-Delete, Undo)  | 1 Tag      |
| 5     | Filter System                       | 1 Tag      |
| 6     | Disk Cache + FSEvents + Polish      | 2 Tage     |

---

## Nicht-Verhandelbare Regeln

1. Keine permanente Löschung ohne Bestätigung + macOS Trash
2. Pre-Delete = physikalischer Filesystem-Move (crash-safe)
3. STF wird nie in Originaldateien geschrieben
4. libxisf + cfitsio: statisch gelinkt (kein dylib für Enduser)
5. `MTLHazardTrackingModeUntracked` auf allen Prefetch-Ressourcen
6. `MTLStorageModeShared` für alle Decode-Buffers (Zero-Copy)
7. Min macOS 13 Ventura – keine macOS 14+ APIs
8. Performance-Gate: < 200ms First Display (Cold), < 32ms nach Cache-Hit
