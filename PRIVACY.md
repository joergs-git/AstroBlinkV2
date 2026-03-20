# Privacy Policy

**Effective Date:** March 20, 2026
**Developer:** joergsflow
**Contact:** joergsflow@gmail.com

This privacy policy applies to the following apps by joergsflow:

- **AstroBlink & AIsaac** (macOS) — formerly AstroBlinkV2
- **AstroFileViewer** (iOS / iPadOS)

---

## Summary

**We do not collect, store, or share any personal data.** Both apps work fully offline by default. The optional AI assistant (AIsaac) and Benchmark Sharing features send only anonymous technical metadata — never personal information.

---

## Core App — No Data Collection

The core app (image viewing, culling, stacking, quality scoring) operates entirely on your device:

- No personal information collected (name, email, phone number)
- No usage analytics or telemetry
- No crash reports sent to us
- No cookies, fingerprinting, or tracking
- No accounts required

---

## AIsaac AI Assistant (Optional, macOS only)

AIsaac is an optional AI-powered assistant. It only activates when you explicitly ask a question. When used, the following technical data is sent to process your query:

### Data Sent Per Query

- **Session metadata** — equipment names (telescope, camera), filter names, exposure settings, quality scores. No file paths or personal information.
- **Image thumbnail** — 800px JPEG of the currently displayed frame. Never full-resolution. Not stored server-side after processing.
- **Device identifier** — anonymous, non-reversible SHA256 hash of hardware UUID. Used only for rate limiting. Cannot be traced to your identity.
- **Imaging coordinates** — SITELAT/SITELONG from FITS headers, rounded to 0.1 degrees (~11 km precision). Used for light pollution and visibility context only.
- **Conversation text** — your questions and AI responses. Not stored after the session ends.

### Data NOT Sent

- Full-resolution images
- File names or file paths
- Your real name, email, or Apple ID
- Your Anthropic API key (in Opus mode, calls go directly from your device to Anthropic)
- Raw pixel data

### Free vs Opus Mode

- **Free Sonnet mode** — queries are routed through a Supabase Edge Function proxy. The proxy forwards your query to the Anthropic Claude API and returns the response. The proxy does not log or store queries.
- **Opus Superexpert mode** — queries go **directly from your device to Anthropic**. Your API key is stored in macOS Keychain (Apple's secure credential storage) and never transmitted to our servers.

### Rate Limiting

Free tier uses the anonymous device hash for rate limiting (20 queries per day). This hash is not stored persistently and resets on server restarts.

---

## Benchmark Sharing (Optional, macOS only)

When you upload a stacking benchmark:

- Hardware specs (chip model, RAM, core count) and timing data are shared anonymously
- Machine identity is a non-reversible SHA256 hash
- No personal data is included
- Benchmarks are stored in a Supabase database and visible on the public leaderboard

---

## File Access

Both apps only access files that **you explicitly choose** to open:

- **AstroBlink & AIsaac** accesses folders and files you select via the Open dialog (Cmd+O). It may move files to a `_predel/` subfolder when you use the pre-delete feature. No files are ever permanently deleted by the app.
- **AstroFileViewer** accesses individual files you open via the file picker, share sheet, or file association.

No file contents are transmitted anywhere (except 800px thumbnails via AIsaac, as described above).

---

## Local Data Storage

| Data | Location | Purpose |
|------|----------|---------|
| App settings | UserDefaults | Slider values, column order, toggles |
| Calibration data | ~/Library/Application Support/AstroBlinkV2/ | Per-setup quality baselines |
| AIsaac profile | ~/Library/Application Support/AstroBlinkV2/ | Equipment, filters, imaging history |
| API key (Opus) | macOS Keychain | Encrypted, app-only access |

None of this data is transmitted unless you explicitly use AIsaac or Benchmark Sharing.

---

## Photo Library (AstroFileViewer only)

AstroFileViewer can optionally save a stretched JPEG to your Photo Library. This requires your explicit permission via the standard iOS dialog. The saved image stays on your device.

---

## Third-Party Services

| Service | Purpose | Privacy Policy |
|---------|---------|----------------|
| Anthropic (Claude API) | AI responses for AIsaac | [anthropic.com/privacy](https://www.anthropic.com/privacy) |
| Supabase | Edge Function proxy, benchmark storage | [supabase.com/privacy](https://supabase.com/privacy) |

No advertising, analytics, or tracking SDKs are used.

---

## Children's Privacy

Our apps do not collect data from children under 13. The apps are designed for adult astrophotography enthusiasts.

---

## Changes to This Policy

Updates will be posted on this page with an updated effective date.

---

## Contact

If you have questions about this privacy policy:

- **Email:** joergsflow@gmail.com
- **GitHub:** [github.com/joergs-git/AstroBlinkV2](https://github.com/joergs-git/AstroBlinkV2)

---

*This privacy policy is hosted on GitHub and linked directly from the Apple App Store listings.*
