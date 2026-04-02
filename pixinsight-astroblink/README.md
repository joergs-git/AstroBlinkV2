# AstroBlink Importer for PixInsight

Import [AstroBlink](https://github.com/joergs-git/AstroBlinkV2) triage results into PixInsight.

## Features

- Import `AstroBlinkV2_SSWEIGHT.csv` from any session folder
- Sortable triage table with quality tiers, SSWEIGHT, and PSFSignalWeight
- Write SSWEIGHT/PSFSWGHT keywords into FITS/XISF headers
- Ready for WeightedBatchPreProcessing (WBPP) weighted integration

## Requirements

- **PixInsight 1.8.9+** (PJSR scripting engine)
- **AstroBlink** (macOS) for generating triage CSV — [Mac App Store](https://apps.apple.com/) / [GitHub](https://github.com/joergs-git/AstroBlinkV2)

## Installation

### Via PI Update Repository (Recommended)

1. Open PixInsight
2. Go to **Resources > Updates > Manage Repositories**
3. Add: `https://raw.githubusercontent.com/joergs-git/pixinsight-astroblink/main/`
4. Click **Check for Updates** and install

### Manual Installation

1. Download `AstroBlinkImporter.js` from `src/scripts/AstroBlinkImporter/`
2. Copy to your PixInsight scripts folder:
   - macOS: `~/Library/PixInsight/scripts/`
   - Windows: `C:\Users\<you>\AppData\Roaming\PixInsight\scripts\`
3. Restart PixInsight

## Usage

1. Run your imaging session through AstroBlink first
2. Export SSWEIGHT (the CSV is created automatically)
3. In PixInsight: **Script > Batch Processing > AstroBlink Importer**
4. Browse to your session folder
5. Review the triage table
6. Click **Write Keywords to Headers** to embed SSWEIGHT into your files
7. Run WBPP — it will automatically use SSWEIGHT for frame weighting

## Workflow

```
NINA Capture → AstroBlink Triage → SSWEIGHT CSV
                                       ↓
                           AstroBlink Importer (PI Script)
                                       ↓
                              FITS/XISF Headers
                                       ↓
                           WBPP (weighted integration)
```

## License

MIT
