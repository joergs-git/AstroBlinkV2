# AstroBlink Importer for PixInsight

Import [AstroBlink](https://github.com/joergs-git/AstroBlinkV2) triage results into PixInsight.

## Features

- Import `AstroBlinkV2_SSWEIGHT.csv` from any session folder
- Color-coded quality tiers (Excellent/Good/Borderline/Trash)
- Sortable triage table (SSWEIGHT, Quality, FWHM, Stars, SNR, Trailing)
- Write SSWEIGHT/PSFSWGHT keywords into FITS/XISF headers
- Ready for WeightedBatchPreProcessing (WBPP) weighted integration

## Requirements

- **PixInsight 1.8.9+** (PJSR scripting engine)
- **AstroBlink** (macOS) for generating triage CSV — [Mac App Store](https://apps.apple.com/) / [GitHub](https://github.com/joergs-git/AstroBlinkV2)

## Installation via PI Update Repository (Recommended)

1. Open PixInsight
2. Go to **Resources > Updates > Manage Repositories**
3. Click **Add** and enter:
   ```
   https://raw.githubusercontent.com/joergs-git/AstroBlinkV2/main/pixinsight-astroblink/
   ```
4. Click **OK**, then **Check for Updates**
5. Install "AstroBlink Importer" when it appears
6. Restart PixInsight

## Manual Installation

1. Download `AstroBlinkImporter.js` from `src/scripts/AstroBlinkImporter/`
2. Copy to your PixInsight scripts folder:
   - macOS: `~/Library/PixInsight/scripts/AstroBlinkImporter/`
   - Windows: `C:\Users\<you>\AppData\Roaming\PixInsight\scripts\AstroBlinkImporter\`
3. Restart PixInsight

## Usage

1. Run your imaging session through AstroBlink first
2. Export SSWEIGHT (the CSV is created automatically)
3. In PixInsight: **Script > Batch Processing > AstroBlink Importer**
4. Browse to your session folder
5. Review the color-coded triage table
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

## Repository URL

For PI Update Repository:
```
https://raw.githubusercontent.com/joergs-git/AstroBlinkV2/main/pixinsight-astroblink/
```

## License

MIT
