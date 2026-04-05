# VLM Check — Visual Anomaly Detection

VLM Check uses Claude Vision (Opus with extended thinking) to analyze chronological mosaic wallpapers for visual anomalies that quantitative metrics (FWHM, star count, noise, trailing) cannot detect. It catches physical optical defects: ice crystals, dew buildup, passing clouds, obstructions, light leaks, and focus shifts.

## How It Works

### 1. Mosaic Generation

Click the **VLM Check** toolbar button (eye icon with exclamation mark). The app:

1. Collects preview textures from the cache for all remaining (non-marked) frames
2. Groups frames by target + filter + setup (ignoring observing night)
3. Sorts each group chronologically by capture time
4. Composites center-cropped tiles (80% center, removing edge aberrations) into tiled JPEG mosaics
5. Generates a **deviation map** alongside each mosaic

Each tile is annotated with:
- **Top-left:** Session frame number (#N)
- **Top-right:** Capture time + moon distance (degrees)
- **Bottom-left:** Twilight phase (N=Night, A=Astro, Na=Nautical, C=Civil, D=Day) + pier side (E/W)
- **Bottom-edge:** Twilight color bar (blue=astro, orange=civil, red=daylight; none=night)

Mosaic pages hold up to 36 tiles in a 6x6 grid (480x360 pixels per tile). Groups with more frames are split across multiple pages with cross-page context provided to the AI.

### 2. Deviation Map

Each mosaic page has a companion **deviation map** — a heat map showing per-pixel deviation from the group median:

- **Bright areas** = significant deviation from the group median (anomaly indicator)
- **Dark/black areas** = tile matches the median (normal)
- **Bright centered blob** = centered optical defect (ice crystal / frost shadow on sensor window)
- **Bright streak** = transient artifact
- **Uniformly bright tile** = overall brightness anomaly (cloud, transparency change)

The deviation map is the primary evidence tool for the AI. Toggle it in the mosaic window to visually inspect the evidence yourself.

### 3. Claude Vision Analysis

Click **Analyze** in the mosaic window to send the mosaics to Claude Vision. The AI receives:

- The original mosaic (chronological tile sequence)
- The deviation map (heat map evidence)
- Session context (target, filter, focal length, exposure, time range, twilight breakdown, moon distance)
- Per-tile numeric metrics (FWHM, star count, eccentricity, noise, trailing score)

Claude Opus with extended thinking (10,000 token thinking budget) performs systematic tile-by-tile analysis, walking through the chronological sequence to detect progressive or sudden changes.

## Detected Anomaly Types

| Type | Description |
|------|-------------|
| **ICE_CRYSTAL** | Centered dark shadow from frost/ice on sensor window. Appears/disappears with dew heater cycles. Highest priority. |
| **DEW** | Progressive star softening across consecutive frames. Contrast drops monotonically as moisture accumulates. |
| **CLOUD** | Sudden star count reduction, washed-out background. May come and go (unlike ice which persists). |
| **OBSTRUCTION** | Dark shadow appearing suddenly from one edge (dew shield shift, cable snag, equipment interference). |
| **LIGHT_LEAK** | Bright patch from edge/corner not present in other tiles. |
| **FOCUS_SHIFT** | Stars suddenly much softer (not gradual like dew). Mechanical or thermal focus change. |

Each detection includes a confidence score (0.0-1.0), a description, and an optional temporal note (e.g. "progressive from #34", "sudden at #47", "clears after #52").

## Interactive Curation

The mosaic window supports both AI-driven and manual curation:

- **Red overlay** — Tiles flagged by Claude Vision anomaly detection
- **Blue overlay** — Tiles manually marked by clicking
- **Click a tile** — Toggle manual mark on/off (marks the frame for deletion in the main file list)
- **Double-click a tile** — Jump to that frame in the main viewer for detailed inspection
- **Mark All Flagged** — Apply all VLM detections as pre-delete marks in one click
- **Unmark All** — Remove all marks applied from this window
- **Toggle Overlay** — Show/hide the red anomaly overlays
- **Toggle Deviation** — Switch between original mosaic and deviation map view

## API Routing

VLM Check uses a dual-route architecture:

### Supabase Edge Function (default, no setup needed)
- Works out of the box for all users
- **10 checks per day per device** (device identified by anonymous machine hash)
- Global daily cap of 500 checks across all devices (safety limit)
- Returns remaining check count in the response header
- Uses Claude Opus with 10,000 token extended thinking budget

### Own API Key (fallback)
- If the Supabase edge function fails or is rate-limited, falls back to the user's own Anthropic API key
- Configure in AIsaac Settings (key stored in macOS Keychain, never transmitted to our servers)
- No daily limit — you pay Anthropic directly per check
- Same model and parameters as the edge function
- Rate limit errors from the edge function do NOT trigger fallback (prevents bypassing the daily cap)

## Requirements

- At least **4 cached frames per group** (target+filter+setup) — groups with fewer frames are skipped
- Frames must have preview textures in the cache (run through the session first)
- Internet connection required for Claude Vision analysis (mosaic generation works offline)
- Meridian flip orientation is applied automatically per tile

## Tips

- **Run after SmartCull** — VLM Check works on remaining (non-marked) frames. Let SmartCull remove obvious statistical outliers first, then use VLM Check to catch visual defects the numbers missed.
- **Check the deviation map first** — Before running the AI analysis, toggle the deviation map view. Bright centered blobs or progressive brightening across tiles often tells you everything you need to know.
- **Use for ice crystal sessions** — VLM Check excels at detecting the subtle centered shadows that ice/frost deposits on the sensor window. These are nearly invisible in FWHM metrics but clearly visible in the deviation map.
- **Multi-page groups** — Large filter groups (36+ frames) are split across pages. The AI receives cross-page context so it knows where each page fits in the overall sequence.
