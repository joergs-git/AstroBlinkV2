# AIsaac — Your AI Astrophotography Assistant

![AIsaac Quality Summary](https://raw.githubusercontent.com/joergs-git/AstroBlinkV2/main/screenshots/AstroBlink_v5_quality_aisaac.png)

## Meet AIsaac

AIsaac is named after **Isaac Newton** — astronomer, physicist, optics pioneer, and inventor of the reflecting telescope. Newton didn't just observe the stars, he built the tools to understand them. AIsaac carries that spirit: an AI that doesn't just look at your data, but understands it, explains it, and helps you make better decisions.

AIsaac is powered by [Claude](https://anthropic.com) (Anthropic's AI) and has deep access to your session data — every frame's FWHM, HFR, star count, noise, eccentricity, trailing score, quality reasoning, and even the FITS headers of the image you're looking at.

## How It Works

AIsaac starts as a compact floating window showing preset chips and an input field — always on top. You can interact with it via:
- **Preset chips** — click any chip for instant answers without typing
- **Type or speak** — start typing in the input field to expand the window to full chat view
- **Title bar toggle** — click "AIsaac's AstroBlink" to collapse/expand the window
- The **Ask AIsaac** sparkles button in the toolbar opens the window if closed

AIsaac always includes your local weather conditions, seeing forecast, and moon phase in every response — not just for "Plan Tonight".

## Preset Questions

Click any preset chip for instant answers. No typing needed.

| Preset | What it does |
|--------|-------------|
| **Quality Summary** | Full session analysis — per-filter breakdown, trends, trash count, recommendations |
| **Smart Mark** | AI suggests which frames to cull. You confirm before anything is marked. Fully undoable. |
| **Filter Advice** | Which filters need more integration? Considers your object type, Bortle zone, and quality |
| **About This Object** | Trivia, distance, imaging tips specific to YOUR equipment and FOV |
| **Nearby Objects** | What else can you image tonight with the same setup? |
| **Plan Tonight** | Complete session plan: targets, filters, exposures, sub counts, timeline from dusk to dawn |

## App Control

AIsaac can control the app for you. Just ask:

- "**Show me #42**" — navigates to frame #42
- "**Highlight the trash frames**" — selects them in the file list (no marking)
- "**Mark the worst 5**" — marks specific frames for deletion (with confirmation)
- "**Open #19**" — opens image in a floating preview window
- "**Filter Ha frames**" — sets the search filter
- "**Stack the best 7**" — selects and starts LightspeedStacker
- "**Show all files**" — clears filters and shows everything
- "**Compare this one**" — opens side-by-side with the best frame
- "**Open a folder**" — triggers the folder picker

## Voice Input & Output

- **Mic button** (left of input field) — hold to speak, release to send
- **Speaker button** (right of input field) — toggle text-to-speech for responses
- Uses macOS built-in speech recognition (offline on Apple Silicon)
- First time: macOS will ask for microphone and speech recognition permissions

## Quick-Reply Buttons

After each response, context-aware buttons appear:
- After quality summary: "Mark trash for me", "Show worst frames", "Filter advice"
- After marking question: "Yes, mark them", "No, leave them", "Show me first"
- Language detection: "Deutsch", "English"

## Two Tiers

### Free Sonnet Buddy (included)
- Powered by Claude Sonnet
- 20 queries per day (50/day with email signup via in-app messaging)
- No signup required
- All features available

### Opus Superexpert (bring your own key)
- Click "Free Sonnet Buddy" in the AIsaac header to upgrade
- Enter your Anthropic API key from [console.anthropic.com](https://console.anthropic.com/settings/keys)
- Key stored securely in macOS Keychain — never transmitted to our servers
- Powered by Claude Opus — deeper analysis, better image understanding
- No rate limit — you pay Anthropic directly (~$0.05-0.15 per query)
- Click "Opus Superexpert" to switch back to free tier anytime

## Language Detection

AIsaac reads your imaging site coordinates from FITS headers (SITELAT/SITELONG) and offers to respond in the local language. You can also just type in any language — AIsaac will match it.

## Equipment Memory

AIsaac learns from every session you load:
- Telescopes and cameras you use
- Filters in your filter wheel
- Objects you've imaged and when
- Your imaging locations (for Bortle zone)

This data persists across app launches in `~/Library/Application Support/AstroBlinkV2/aisaac_profile.json`. It enables features like "Plan Tonight" even before opening a folder.

## Frame History Access

AIsaac has full access to your Frame History Database — a persistent SQLite store tracking all per-frame quality metrics across sessions. Ask things like:
- "What targets have I imaged?"
- "Which setup do I use most?"
- "Where do I need more integration time?"
- "How has my FWHM improved over time?"
- "What's my trash rate per setup?"

AIsaac combines this with live weather, moon phase, and Bortle sky quality to give context-aware advice.

## Privacy

- No personal data is ever sent — only technical metadata (equipment names, quality scores, coordinates)
- Image thumbnails are 800px JPEG, never full-resolution
- Device ID is an anonymous hash for rate limiting
- See the full [Privacy Policy](https://github.com/joergs-git/AstroBlinkV2/blob/main/PRIVACY.md)

---

**We'd love your feedback!** AIsaac is brand new. Tell us what works, what doesn't, and what you'd like to see next: [GitHub Issues](https://github.com/joergs-git/AstroBlinkV2/issues)
