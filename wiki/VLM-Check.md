# VLM Check — Visual Anomaly Detection (ALPHA)

> **Warning:** This feature is an experimental thesis test. Current LLM vision models (Claude, GPT-4V, Gemini, and others) have not yet demonstrated sufficient accuracy for reliable detection of instrumental artifacts like ice, frost, or optical defects in astronomical sub-exposures. The feature remains available for experimentation and further testing. Results should not be relied upon for culling decisions.

VLM Check uses Claude Vision (Opus with extended thinking) to analyze chronological mosaic wallpapers for visual anomalies. It attempts to catch physical optical defects such as ice crystals, dew buildup, passing clouds, obstructions, and focus shifts — however, current LLMs tend to focus on brightness differences (e.g. twilight) rather than subtle instrumental patterns, and struggle when the majority of frames are affected.

## How It Works

### 1. Mosaic Generation

Click the **VLM Check** toolbar button (eye icon with exclamation mark). An ALPHA warning dialog appears — click **Continue Anyway** to proceed. The app:

1. Collects preview textures from the cache
   - **No selection (< 2 highlighted):** Uses all remaining (non-marked) frames
   - **2+ highlighted files:** Uses the highlighted selection regardless of mark status
2. Groups frames by target + filter + setup (ignoring observing night)
3. Sorts each group chronologically by capture time
4. Composites center-cropped tiles (80% center, removing edge aberrations) into tiled JPEG mosaics
5. Generates a **deviation map** alongside each mosaic
6. Runs **computational anomaly detection** (instant, no API call needed)

The generation can be **cancelled** at any time via the Cancel button on the overlay.

Each tile is annotated with:
- **Top-left:** Session frame number (#N)
- **Top-right:** Capture time + moon distance (degrees)
- **Bottom-left:** Twilight phase (N=Night, A=Astro, Na=Nautical, C=Civil, D=Day) + pier side (E/W)
- **Bottom-edge:** Twilight color bar (blue=astro, orange=civil, red=daylight; none=night)

Mosaic pages hold up to 36 tiles in a 6x6 grid (480x360 pixels per tile). Groups with more frames are split across multiple pages.

### 2. Deviation Map

Each mosaic page has a companion **deviation map** — a heat map showing per-pixel deviation from the group median:

- **Bright areas** = significant deviation from the group median (anomaly indicator)
- **Dark/black areas** = tile matches the median (normal)
- **Uniformly bright tile** = overall brightness anomaly (cloud, transparency change)

Toggle it in the mosaic window to visually inspect the evidence yourself.

### 3. Computational Center-Anomaly Detection

Before any AI analysis, the app automatically runs two computational detectors on bin4 (4x4 downsampled) tile data:

1. **Total deviation detector** — flags tiles that deviate significantly from a "clean reference" built from the top 25% tiles by star count. Catches any large-scale anomaly regardless of position.
2. **Center-vs-edge detector** — flags tiles where the center region deviates much more than the edges (centered optical defects like ice/frost).

These results appear **immediately** in the mosaic window. No API call needed.

> **Known limitation:** Auto-stretch normalizes each tile independently, which can mask the contrast of ice/frost shadows in the post-stretch pixel data. The computational detectors may miss subtle defects when the majority of frames are affected (contaminated median problem). Future versions may add raw-data analysis in the scoring pipeline for more reliable detection.

### 4. Claude Vision Analysis (Optional)

Click **Analyze** in the mosaic window to send the mosaics to Claude Vision. The AI receives:

- The original mosaic (chronological tile sequence)
- The deviation map (heat map evidence)
- Session context (target, filter, focal length, exposure, time range, twilight breakdown, moon distance)
- Per-tile numeric metrics (FWHM, star count, eccentricity, noise, trailing score)
- Reference tile identification (cleanest frame for comparison)

The prompt uses an **invariance-based** approach: the model is instructed to first check for structures that persist at the same pixel position across multiple frames, then classify by behavior (position/shape/intensity stability), and only flag dominant systematic patterns — not transient events or brightness differences.

## Interactive Curation

The mosaic window supports both AI-driven and manual curation:

- **Red overlay** — Tiles flagged by anomaly detection (computational or VLM)
- **Blue overlay** — Tiles manually marked by clicking
- **Click a tile** — Toggle manual mark on/off (marks the frame for deletion in the main file list)
- **Double-click a tile** — Jump to that frame in the main viewer for detailed inspection
- **Mark All Flagged** — Apply all detections as pre-delete marks in one click
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
- Rate limit errors from the edge function do NOT trigger fallback (prevents bypassing the daily cap)

## Requirements

- At least **4 cached frames per group** (target+filter+setup) — groups with fewer frames are skipped
- Frames must have preview textures in the cache (run through the session first)
- Internet connection required for Claude Vision analysis (mosaic generation and computational detection work offline)
- Meridian flip orientation is applied automatically per tile

## Tips

- **Check the deviation map first** — Before running the AI analysis, toggle the deviation map view. Visual inspection of the deviation map is often more reliable than the AI analysis.
- **Use computational detections** — The instant center/anomaly detections appear as soon as the mosaic is generated. These are free and fast.
- **Manual click-to-mark** — The most reliable approach: visually inspect the mosaic yourself and click tiles that look wrong.
- **Don't rely on AI results for culling** — VLM Check is experimental. Use it as a second opinion, not a decision maker.
