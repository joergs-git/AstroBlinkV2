# Target Catalog Browser

The Target Catalog Browser (v5.15.0) is a built-in deep-sky object database with 533+ targets, backed by Supabase with offline disk caching. It helps you plan imaging sessions, track integration progress, and discover new targets for your equipment.

Open it from the menu bar: **Window > Target Catalog**, or via AIsaac's "Nearby Objects" preset.

## Overview

The browser is a split-view window:
- **Left pane** — search, filters, weather, and a scrollable target list
- **Right pane** — full detail panel for the selected target

Each target includes coordinates, photometry, angular size, filter recommendations, difficulty rating, imaging notes, and your personal integration history from the Frame History Database.

## Browsing & Filtering

### Search

Type in the search bar to find targets by:
- Catalog ID (e.g. `NGC 7000`, `M42`, `IC 1396`)
- Common name (e.g. `Orion Nebula`, `Whirlpool`)
- Constellation abbreviation (e.g. `Cyg`, `Ori`)

The search matches canonical names, common names, aliases, and constellation fields simultaneously. Results update as you type.

### Type Filter Chips

A horizontal scrollbar of type chips lets you filter by object type. Each chip shows the count of matching targets. Types include:

| Type | Icon |
|------|------|
| Galaxy / Galaxy Group | Hurricane |
| Emission Nebula / HII Region | Cloud |
| Reflection Nebula | Cloud outline |
| Planetary Nebula | Dashed circle |
| Dark Nebula | Fog |
| Supernova Remnant | Sparkles |
| Open Cluster | Half-star |
| Globular Cluster | Grid circle |
| IFN (Integrated Flux Nebula) | Waveform |
| Star Forming Region | Flame |
| Wolf-Rayet Nebula | Wind |
| Quasar | Bolt |

Click a chip to filter; click again to clear the filter.

### Constellation Picker

A dropdown to filter by IAU constellation abbreviation (e.g. Cyg, Ori, Cas). Shows all constellations present in the catalog.

### Difficulty Picker

Filter by imaging difficulty level:
- **Beginner** — bright, large targets with short integration requirements
- **Intermediate** — moderate brightness or size, good for developing skills
- **Advanced** — faint or small targets requiring longer integration and better equipment
- **Expert** — extremely faint (IFN, galaxy groups) or technically demanding

### Toggle Filters

- **Tonight visible** — show only targets that reach at least 30 degrees altitude tonight (requires observer location from FITS headers or user profile)
- **Has filter gap** — show only targets where your actual integration is less than 40% of the proportional share for at least one recommended filter

### Optimal FOV Filter

- **Optimal FOV (>=30%)** — toggle to show only targets whose angular extent fills at least 30% of your selected equipment's sensor field of view. Requires an equipment setup to be selected.

### Sorting

Sort the list by clicking any column header. Supported sort columns:
- Name, Type, Magnitude, Angular Size, Constellation
- **Tonight Alt** — maximum altitude tonight (highest first)
- **Your Hours** — total integration hours from your Frame History (most imaged first)

Click a header once for ascending, again for descending. The active sort column is indicated by an arrow glyph.

## Target List

Each row in the list shows:
- **Session indicator** — blue dot if the target is in your currently loaded session
- **Type icon** — color-coded by object type
- **Canonical name** — monospaced for easy catalog ID reading
- **Common name** — if known (e.g. "Orion Nebula")
- **Constellation** — IAU abbreviation
- **Magnitude** — visual magnitude (V band)
- **Angular size** — major axis in arcminutes (or degrees for large targets)
- **Tonight altitude** — max altitude in degrees (green >= 30, orange >= 15, dim otherwise)
- **Moon distance** — angular separation from the moon (red < 30 degrees, orange < 60 degrees)
- **Integration hours** — your total hours from Frame History, shown as a blue pill badge. When an equipment setup is selected, hours are filtered to show only integration from that specific setup.
- **Filter gap indicator** — orange warning triangle when you need more integration in some filters

### Hover Card

Hovering the mouse over a target name in the list shows a floating compact datasheet with key facts at a glance: type, magnitude, angular size, tonight's max altitude, moon distance, and your integration hours. The card appears after a short delay and follows the cursor, disappearing when you move away.

## Detail Panel

Selecting a target opens a scrollable detail panel on the right with these sections:

### Header

- DSS sky survey thumbnail (120px, enlarges to 300px on hover; from NASA/STScI Digitized Sky Survey)
- Canonical name and common name
- "IN SESSION" badge if the target is in the currently loaded session
- Type badge (color-coded)
- Difficulty badge (green/blue/orange/red)

### Coordinates

- RA (J2000) in hours/minutes/seconds
- Dec (J2000) in degrees/arcminutes/arcseconds
- Constellation name

### Alt/Az Visibility Chart

A SwiftUI Charts area+line chart showing tonight's altitude curve for the target:

- **Target altitude** — solid blue line with gradient fill from horizon to zenith
- **Moon altitude** — dashed yellow/gray line overlay, so you can see when the moon interferes
- **30-degree line** — green dashed reference (practical lower limit for quality imaging)
- **Current time marker** — red vertical rule + red dot on the target curve (when within the chart's time range)
- **Azimuth direction arrows** — compass arrows along the altitude curve showing where the target is headed (N/NE/E/SE/S/SW/W/NW). These indicate the target's cardinal direction at each time point, so you can tell at a glance which part of the sky to point at and whether you need to plan for a meridian flip.
- **Y-axis** — 0 to 90 degrees altitude
- **X-axis** — time in 2-hour intervals through the night

Summary stats above the chart:
- Max altitude tonight
- Hours above 30 degrees
- Transit time (meridian crossing)
- Moon distance and illumination percentage

### Size & FOV Simulation

- **Angular size** — major x minor axis in arcminutes or degrees
- **Proportional rectangle** — visual representation of the target's aspect ratio
- **FOV simulation** — when an equipment setup is selected, shows a proportional diagram with:
  - Outer rectangle = your sensor's field of view
  - Inner ellipse = the target's angular extent
  - Fill ratio percentage
  - Plate scale (arcsec/pixel) and FOV dimensions
- **Recommended focal length range** — from the catalog (e.g. "200-600 mm")

### Photometry

- Visual magnitude (V band)
- Surface brightness (mag/arcsec-squared)
- Minimum recommended integration hours

### Filter Recommendations

Shows the catalog's recommended filter sets with ratio bars:
- **Primary filter set** — e.g. SHO with ratios Ha:3, OIII:2, SII:1
- **Secondary filter set** — alternative palette (e.g. HOO)
- **Filter notes** — specific guidance from the catalog (e.g. "Ha dominant, OIII for rim detail")

Each filter is shown as a proportional colored bar with the ratio number.

### Your Imaging History

When you have Frame History data for this target:
- Total integration hours, session count, last imaged date
- Per-filter hour breakdown with color-coded filter labels
- Median FWHM from your best sessions
- **Filter gap analysis** — progress bars per filter comparing your actual hours to the recommended proportions:
  - Green = 80%+ of expected
  - Yellow = 40-80% of expected
  - Red = below 40% of expected
  - "Need X more hours of FILTER" recommendation for the worst gap

### Imaging Notes

Free-text description and imaging tips from the catalog.

### Aliases

Scrollable row of alternate names (e.g. "North America Nebula", "Caldwell 20", "LBN 373").

### Quality Scoring Weights

Shows how this target type affects SmartCull's quality scoring:
- FWHM weight (e.g. galaxies get 1.4x — sharpness matters more)
- Stars weight (e.g. nebulae get 0.5x — star count less critical)
- Noise weight (e.g. IFN gets 2.0x — faint targets need low noise)
- Trailing weight

Each shown as a horizontal bar with the multiplier value.

## Weather Forecast Bar (Meteoblue)

The weather bar appears below the location picker and shows tonight's conditions, powered by [Meteoblue](https://www.meteoblue.com/) via a Supabase Edge Function with caching and rate limiting:

- **Cloud cover** — total percentage with color coding (green < 30%, orange < 60%, red > 60%). High cloud percentage shown when > 10% (critical for seeing)
- **Seeing estimate** — derived from visibility, high clouds, wind speed, and humidity. Multi-factor heuristic: visibility is the primary driver (low vis = moisture/aerosols = bad seeing)
- **Visibility** — atmospheric transparency in km. Color: green > 20km, orange 10-20km, red < 10km
- **Temperature, Humidity, Wind** — averaged over the first 8 nighttime hours. Humidity turns red > 85% (dew risk). Wind turns red > 30 km/h (mount stability)
- **Fog probability** — shown when > 5% (red warning)
- **Moon illumination** — percentage with color coding
- **Hourly cloud cover bars** — 1-hourly bar chart for the nighttime window (18:00-06:00):
  - **Past hours** — greyed out (already happened)
  - **Current hour** — bold **NOW** marker with accent border
  - **Future hours** — normal color bars (forecast)
  - Night boundaries shown with thick separator lines between dates
  - **Hover tooltip** — float your mouse over any bar to see a detailed card with:
    - Full date/time + "past" or "forecast" badge
    - Cloud breakdown: low / mid / high cloud layers
    - Visibility (km) + seeing estimate
    - Temperature + humidity + wind speed
    - Fog risk and rain probability if applicable

## Target Hierarchy (Major/Minor Targets)

A unique feature not found in any other astrophotography tool. When you select a target in the catalog:

- **Sub-targets show "Part of"** — e.g., Melotte 15 shows "Part of IC1805 (Heart Nebula)". Clickable to navigate to parent.
- **Parents show "Sub-targets"** — e.g., M42 shows 11 sub-targets (M43, NGC1977, NGC2024, IC434, M78, etc.) as clickable pills.
- **List rows** show hierarchy indicators: blue "Part of" text for sub-targets, orange "N sub-targets" for parents.
- **Hover tooltip** includes aliases, parent/child relationships for quick reference.

This helps beginners understand that, for example, Melotte 15 is the central star cluster of the Heart Nebula, or that the Horsehead (IC434) is part of the Orion complex. 120+ mappings across 30+ complexes including Orion, Heart & Soul, Veil, Carina, Rho Ophiuchi, Andromeda, Leo Triplet, Virgo/Markarian's Chain, Stephan's Quintet, and more.

In the Frame History database, sub-target integration time rolls up to the parent — when you select "IC1805" in the target dropdown, you see all frames including those specifically targeting Melotte 15 or the Fish Head Nebula.

## Location & Setup Picker

### Location Picker

If you have imaging locations in your AIsaac user profile (learned from FITS headers over time), a dropdown lets you switch between them. Changing the location:
- Recomputes all target visibility curves
- Fetches fresh weather data for the new coordinates
- Auto-selects the equipment setup most recently used at that location

Shows current coordinates in the bar (e.g. "50.9 degrees N, 6.9 degrees E").

### Equipment Setup Picker

Switch between your known telescope+camera setups. This affects:
- FOV simulation in the detail panel (plate scale, sensor coverage)
- Fill ratio calculations
- **Integration hours** — the "Your Hours" column and per-filter breakdown in the detail panel are filtered to show only hours captured with the selected equipment setup, so you can track progress per rig

Equipment profiles are learned automatically from your session FITS headers and stored in the AIsaac user profile.

## DSS Sky Survey Thumbnails

The detail panel shows a thumbnail image from NASA's Digitized Sky Survey (STScI):
- Public domain images, no API key required
- Field of view adapts to target angular size (5-15 arcminutes)
- Red POSS-II plates for good deep-sky visibility
- **Disk-cached** to `~/Library/Caches/AstroBlinkV2/dss_thumbnails/` — downloaded once, loaded from disk on subsequent views
- **Memory-cached** via NSCache (up to 600 thumbnails) for instant scrolling

## Data Source

The catalog is powered by a Supabase `target_catalog` table containing 533+ deep-sky objects. The app uses a TTL (time-to-live) caching strategy identical to other Supabase services:
- On launch, the cached JSON is loaded from disk for instant display
- In the background, a refresh is attempted against Supabase
- If the cache is empty (first launch), a synchronous fetch is triggered
- The `TargetCatalogService.didRefreshNotification` triggers a UI reload when fresh data arrives

The embedded `DeepSkyTargetDatabase` (229 targets) remains the source for quality scoring — the Supabase catalog extends this with additional targets, detailed filter recommendations, imaging notes, and photometry data.

## Tips

- **Sort by "Your Hours"** to see which targets you've invested the most time in — useful for prioritizing follow-up sessions
- **Enable "Has filter gap"** to find targets that need specific filters — great for planning a session around what's missing
- **Check "Tonight visible" + sort by altitude** to quickly find the best targets for tonight's session
- **Compare the FOV simulation** across different equipment setups to choose the right scope for a target
- **Red moon distance** (< 30 degrees) means the target is too close to the moon for quality broadband imaging — consider narrowband instead
- The weather forecast updates when you switch locations, so you can compare conditions at different imaging sites
