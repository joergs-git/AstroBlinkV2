# Privacy Policy

**Effective Date:** May 3, 2026
**Developer:** joergsflow
**Contact:** joergsflow@gmail.com

This privacy policy applies to the following apps by joergsflow:

- **AstroBlink & AIsaac** (macOS) — formerly AstroBlinkV2
- **AstroFileViewer** (iOS / iPadOS)

---

## Summary

The core image-viewing, culling, and stacking functions run entirely on your device. No personal information (name, email address, account, Apple ID) is collected during normal use.

A few optional features send anonymized technical data to our servers (Anthropic for AIsaac, Supabase for benchmarks and community learning). These are listed in detail below. All transmitted identifiers are non-reversible SHA256 hashes. There are no advertising, analytics, or tracking SDKs in either app.

Anthropic operates from the United States. Supabase data for this project is stored in the EU region (Ireland, `eu-west-1`). By using AIsaac you accept transfer of anonymized query data to Anthropic in the US. By enabling Community Learning you accept storage of anonymized telemetry in the EU.

---

## What runs locally only

The following always stays on your device:

- File viewing, culling, pre-delete staging
- Auto-stretch (STF), debayer, sharpening, denoise
- Stacking, color combine, mosaic generation
- Quality scoring, frame history database
- Calibration baselines, AIsaac local profile
- Image thumbnails, session caches

No file contents, file paths, file names, or full-resolution pixel data leave your device for any of these features.

---

## Anonymous Telemetry (Default ON, Opt-out)

**What is sent:** When the app launches, a short ping with technical context is recorded. When you use Community Learning features, additional anonymized metadata is shared.

| Event | Payload | Purpose |
|---|---|---|
| `app_started` (per launch) | machine hash, app version, chip name, CPU cores, RAM size | Aggregate platform statistics |
| Session benchmarks | machine hash, app version, hardware specs, timing data | Public stacking-performance leaderboard |
| Curated frame ratings | machine hash, telescope name, camera name, filter, target name, capture date, quality metrics, your 1–3 star rating | Improves quality-scoring algorithm for everyone |
| Community sessions | machine hash, equipment fingerprint, session aggregates (no per-frame detail) | Cross-user baseline learning for outlier detection |

**Where it goes:** A Supabase project hosted in the EU region (Ireland, `eu-west-1`).

**Identifier:** A non-reversible SHA256 truncation of your hardware UUID. Cannot be traced back to your identity. There is no user account.

**Note on equipment fingerprinting:** While no plain-text username is sent, an unusual telescope + camera + filter + target + date combination could in theory be linked to a public observation. If you publish image metadata (e.g. AstroBin), this is the same risk you already accept by publishing.

**Opt-out:** Click the "Community" indicator in the status bar (bottom right of the main window). A popover lets you toggle each telemetry category independently:

- **Performance Benchmarks** — anonymous hardware specs (chip, cores, RAM) and timing for stacking + session-load benchmarks. Powers the leaderboard and the `app_started` event.
- **Frame Quality Ratings** — equipment + target metadata (telescope, camera, filter, target, date) sent with each star rating.
- **Community Baselines** — aggregate-only quality metrics for community calibration (skip-the-30-frame-learning-phase shortcut for new equipment).

"Disable all" / "Enable all" buttons at the bottom of the popover toggle every category at once. The first-launch onboarding screen offers the same single-click master opt-out before any data is sent.

---

## Approximate Location

When you use AIsaac, the in-app weather forecast (Target Catalog), Bortle-class lookup, or visibility computations, your imaging coordinates are read from the FITS headers (`SITELAT` / `SITELONG`) that your equipment writes.

| Property | Value |
|---|---|
| Source | FITS-header `SITELAT` / `SITELONG` (written by your mount/imaging software) |
| Rounding | 0.1° (~11 km) before transmission |
| Recipients | Anthropic (AIsaac queries), Supabase Edge (weather proxy to Meteoblue / Open-Meteo), Bortle-class service |
| Use | Light-pollution context, weather forecast, sky visibility, moon-distance scoring |

These features are functionally dependent on having approximate coordinates. If your FITS files do not contain `SITELAT`/`SITELONG`, the related features fall back gracefully (no upload, but features become unavailable). There is no separate "location off" toggle for these features themselves.

---

## In-App Messages with Email Input (Optional)

The app may occasionally show an in-app message banner. Most messages are read-only. A small subset offers an action that requires entering your email — for example, redeeming a free AIsaac boost.

When you actively respond to such a message and submit your email:

- Your email is stored in the `message_interactions` table at Supabase
- An entitlement token may be issued and stored in `device_entitlements` (linked to your machine hash)
- Purpose is exclusively that entitlement (e.g. an extra batch of free AIsaac queries)

You will never be emailed automatically. Removal: send a request to joergsflow@gmail.com (a self-service deletion endpoint may be added in a later release).

If you never interact with such a message, no email leaves your device.

---

## AIsaac AI Assistant (Optional, macOS only)

AIsaac is an optional AI-powered assistant. It only activates when you explicitly ask a question.

### Data Sent Per Query

- **Session metadata** — equipment names (telescope, camera), filter names, exposure settings, quality scores. No file paths, no real names.
- **Image thumbnail** — 800px JPEG of the currently displayed frame. Never full-resolution. Not stored server-side after processing.
- **Device identifier** — anonymous, non-reversible SHA256 hash of hardware UUID. Used only for rate limiting.
- **Imaging coordinates** — `SITELAT`/`SITELONG` from FITS headers, rounded to 0.1° (~11 km).
- **Conversation text** — your questions and AI responses. Not stored after the session ends.

### Data NOT Sent

- Full-resolution images
- File names or file paths
- Your real name, email, or Apple ID
- Your Anthropic API key (in Opus mode, calls go directly from your device to Anthropic)
- Raw pixel data

### Free vs Opus Mode

- **Free Sonnet mode** — queries are routed through a Supabase Edge Function proxy. The proxy forwards your query to the Anthropic Claude API and returns the response. The proxy does not log queries.
- **Opus Superexpert mode** — queries go **directly from your device to Anthropic**. Your API key is stored in macOS Keychain (Apple's secure credential storage) and never transmitted to our servers.

### Rate Limiting

Free tier uses the anonymous device hash for rate limiting (20 queries per day).

### AIsaac Profile

A local JSON profile (equipment, filters, imaging history) is stored at `~/Library/Application Support/AstroBlinkV2/`. The profile is included in AIsaac queries but never uploaded as a standalone artifact. You can delete the profile by removing the file directly; an in-app "Export / Delete profile" UI is on the roadmap.

---

## Benchmark Sharing (Optional, macOS only)

When you upload a stacking benchmark:

- Hardware specs (chip model, RAM, core count) and timing data are shared anonymously
- Machine identity is the same non-reversible SHA256 hash described above
- Benchmarks are stored at Supabase and visible on the public leaderboard

Same opt-out as Community Learning (Settings toggle).

---

## File Access

Both apps only access files that **you explicitly choose** to open:

- **AstroBlink & AIsaac** accesses folders and files you select via the Open dialog (Cmd+O). It may move files to a `_predel/` subfolder when you use the pre-delete feature. No files are ever permanently deleted by the app.
- **AstroFileViewer** accesses individual files you open via the file picker, share sheet, or file association.

Image content stays local except for the 800px thumbnail used by AIsaac queries.

---

## Local Data Storage

| Data | Location | Purpose |
|---|---|---|
| App settings | UserDefaults / iCloud Key-Value Store | Slider values, column order, toggles |
| Frame History database | `~/Library/Application Support/AstroBlinkV2/` (+ rotating iCloud backup) | Per-frame quality metrics across sessions |
| Calibration baselines | `~/Library/Application Support/AstroBlinkV2/Calibration/` | Per-setup quality reference |
| AIsaac profile | `~/Library/Application Support/AstroBlinkV2/` | Equipment, filters, imaging history |
| API key (Opus mode) | macOS Keychain | Encrypted, app-only access |
| Thumbnail cache | `~/Library/Caches/AstroBlinkV2/` | Pre-stretched HEIF previews |

None of this data is transmitted unless you explicitly use AIsaac, Benchmark Sharing, or Community Learning.

---

## Photo Library (AstroFileViewer only)

AstroFileViewer can optionally save a stretched JPEG to your Photo Library. This requires your explicit permission via the standard iOS dialog. The saved image stays on your device.

---

## Third-Party Services

| Service | Purpose | Privacy Policy |
|---|---|---|
| Anthropic (Claude API) | AI responses for AIsaac | [anthropic.com/privacy](https://www.anthropic.com/privacy) |
| Supabase | Edge Functions, benchmark + community storage, in-app messages | [supabase.com/privacy](https://supabase.com/privacy) |
| Meteoblue / Open-Meteo / 7Timer | Weather forecast (proxied via Supabase Edge) | provider sites |

No advertising, analytics, or tracking SDKs are used.

---

## Children's Privacy

Our apps do not collect data from children under 13. The apps are designed for adult astrophotography enthusiasts.

---

## Changes to This Policy

Updates will be posted on this page with an updated effective date.

---

## Contact

If you have questions about this privacy policy or want your data removed:

- **Email:** joergsflow@gmail.com
- **GitHub:** [github.com/joergs-git/AstroBlinkV2](https://github.com/joergs-git/AstroBlinkV2)

---

*This privacy policy is hosted on GitHub and linked directly from the Apple App Store listings.*
