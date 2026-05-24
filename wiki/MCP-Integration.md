# MCP Integration — Drive AstroBlink from Claude

AstroBlinkV2 exposes its frame-history database and triage actions to LLM clients via the [Model Context Protocol](https://modelcontextprotocol.io). Once configured, you can ask Claude things like:

- *"Welche Setups habe ich in AstroBlink?"*
- *"Zeig mir die letzten 3 Sessions vom RC12"*
- *"Wie viele Stunden Ha habe ich schon bei NGC 7635 gesammelt?"*
- *"Verarbeite die Aufnahmen der letzten Nacht vom RC12 Teleskop"*
- *"Quality-Zusammenfassung der letzten Nacht"*
- *"Markiere den Schrott von gestern als dry-run"*

The first three answer instantly from the frame history. The fourth triggers a headless scan of your NAS folder, scoring 100s of frames in 2–5 minutes, then summarises. The fifth gives you the algorithm's worst-frame list per filter with garbage-reason counts. The sixth identifies trash candidates for you to confirm.

---

## Setup

### Prerequisites

- AstroBlinkV2 **v6.4.0 or newer** from the [GitHub Releases page](https://github.com/joergs-git/AstroBlinkV2/releases) (the stdio proxy needed for Claude Desktop ships only in the notarized DevID build, not in the App Store version — see [Distribution caveats](#distribution-caveats) below)
- macOS 14 Sonoma or newer
- One of:
  - **Claude Desktop** (claude.ai/download) — fully supported, recommended
  - **Claude Code** (`claude` CLI) — works via direct URL config
  - Any other MCP-capable client (custom integrations, etc.) — works via direct URL or via the bundled stdio proxy

### One-click install (Claude Desktop)

1. Open AstroBlinkV2 and choose **Window → MCP Connector (Claude)…**
2. Verify the three preflight rows are green:
   - MCP server is running (auto-starts at app launch on `https://127.0.0.1:8765/mcp`)
   - stdio proxy is bundled at `Contents/Helpers/AstroBlinkMCPProxy`
   - Claude Desktop is installed
3. Click **Install to Claude Desktop**. The stdio config snippet is copied to your clipboard and the Claude config file opens in your default editor (TextEdit by default).
4. Paste the clipboard contents into the file (replacing existing `mcpServers` block or merging — the snippet has the full `mcpServers` wrapper). Save (⌘S).
5. Quit Claude Desktop completely (⌘Q) and re-open it.
6. The wrench/tools icon now shows `astroblink` with 13 tools.

### Manual install (Claude Code or custom URL clients)

If you'd rather speak HTTPS directly:

1. In the MCP Connector window, click **Install Certificate** in the lower "URL-aware MCP clients" section. macOS shows one keychain prompt — confirm. This adds the self-signed cert to your login keychain and marks it trusted for SSL.
2. Use the URL config form:

```json
{
  "mcpServers": {
    "astroblink": {
      "url": "https://127.0.0.1:8765/mcp"
    }
  }
}
```

- For Claude Code: paste into `~/.claude/mcp.json` or your project's `.mcp.json`.
- For other clients: consult their docs for URL-based MCP server config.

---

## Astrofile Locations — Tagging Your NAS Folders

The `Window → Astrofile Locations…` panel is **not** where you tell AstroBlink "where my data lives." That happens per-session when you open a folder via ⌘O, or in bulk via `Window → Frame History → Scan Archive`.

Astrofile Locations is a **tag → path shortcut for MCP**. Register your NAS or local astro folders here with a setup tag (e.g. "RC12", "RASA"). Then in Claude you can say *"scan the RC12 folder from last night"* and AstroBlink resolves the tag automatically instead of you typing the full path.

Add a folder:
1. **Window → Astrofile Locations…** → **Add Your First Folder…**
2. Pick the root folder of one of your astro setups (e.g. `/Volumes/NAS/Astro/RC12_imaging/`).
3. In the row that appears, set the **Setup Tag** (e.g. `RC12`) and optionally a Nickname.

You can register multiple roots — one per setup is the typical pattern.

---

## The 13 Tools

**Read-only (work even when the app is busy or the active session is different):**

| Tool | What it does |
|---|---|
| `ping` | Health check. Returns server version + active-session snapshot. |
| `list_setups` | Equipment setups from frame history (telescope, camera, FL, frame count, first/last night). |
| `list_astro_roots` | Registered Astrofile Locations with their setup tags. |
| `list_nights` | Distinct observing nights, newest first. Optional `setupHash` / `target` filters. |
| `night_summary` | Per-(target, filter) aggregates for one night: frame count, trash count, median FWHM/HFR/stars/noise/trailing, integration seconds, ambient temp, moon. |
| `recent_sessions` | Last N sessions (default 5, max 50). |
| `target_integration` | Total integration time per filter for a target. |
| `frames` | Per-frame detail rows (limit 500). Optional night/target/filter/qualityMin/setupHash filters. |
| `setup_summary` | Total frames, sessions, distinct targets, first/last night, median FWHM/HFR, trash rate for one setup. |
| `quality_summary` | Quality breakdown for a scope (session / night / setup / global): per-filter aggregates, tier counts, top 10 garbage reasons, top 10 worst frames by combinedZScore. |
| `filter_advice` | Integration per filter for a target + heuristic next-filter recommendation. |

**App-driving (need AstroBlink running):**

| Tool | What it does |
|---|---|
| `scan_for_new_frames` | Triggers ArchiveScanner on a folder resolved by `setupTag` or explicit `root` path. Awaits completion (default timeout 600s). |
| `mark_auto_garbage_for_predelete` | Identifies algorithm-classified trash. `dryRun=true` (default) returns the list; `dryRun=false` asks the active session to set checkboxes. Move-to-PRE-DELETE stays user-driven (⌘⌫) — no silent deletion. |

---

## Privacy

- The MCP server binds to **`127.0.0.1` only** — never reachable from your LAN, never reachable from the internet, no tunneling.
- The self-signed TLS cert is also scoped to localhost (`127.0.0.1` + `localhost` SAN entries).
- The stdio proxy refuses to use that cert for any other host.
- The MCP transport is local-process-to-local-process. Claude Desktop launches the proxy as a subprocess; the proxy speaks HTTPS to AstroBlink on the same Mac.

---

## Distribution caveats

The bundled stdio proxy **ships only in the GitHub Developer ID build**, not in the Mac App Store build. Why:

- App Store distribution mandates `app-sandbox=true` on every embedded executable.
- Sandboxed standalone CLIs that get launched by foreign apps (like Claude Desktop) hit a kernel-level rejection (AMFI) because the sandbox needs an `.app` container anchor that doesn't exist for bare child processes.
- The two requirements are incompatible. The proxy is excluded from the ASC archive job via a `SKIP_MCP_PROXY=1` build flag.

If you're on the App Store version and want Claude Desktop integration:

- **Easiest:** download the same-version notarized zip from the [GitHub Releases page](https://github.com/joergs-git/AstroBlinkV2/releases) and replace your install. Same bundle id — overrides the App Store install cleanly. Auto-updates still come from the App Store.
- **Alternative:** use Claude Code instead of Claude Desktop. Claude Code consumes URL configs natively, no proxy needed.
- **Alternative:** use Claude Desktop's Settings → Connectors UI to add the URL endpoint manually. It works once added, just no one-click install button.

---

## Troubleshooting

- **"Einige MCP-Server konnten nicht geladen werden" in Claude Desktop on startup** — your config has a `{"url": …}` entry where Claude Desktop expects `{"command": …}`. Re-run "Install to Claude Desktop" from AstroBlink to overwrite with the proxy-based config.
- **Tools don't appear in Claude Desktop after install** — check `~/Library/Logs/Claude/mcp-server-astroblink.log`. The proxy logs its own startup line `AstroBlinkMCPProxy: started, forwarding stdio ↔ https://127.0.0.1:8765/mcp`. If you see that, the issue is upstream (server not running or unreachable).
- **"TLS handshake failed" via direct URL** — your client doesn't accept the self-signed cert. Click "Install Certificate" in the MCP Connector window. The proxy in the GH build sidesteps this entirely by bypassing cert validation for localhost.
- **`scan_for_new_frames` returns "Folder not registered"** — the folder you asked Claude to scan isn't in Astrofile Locations. Add it there with a setup tag and try again.
- **`mark_auto_garbage_for_predelete(dryRun=false)` returns "No matching frames in the active session"** — the algorithm-classified trash frames aren't in the currently loaded session. Open the relevant folder in AstroBlink first (or run `scan_for_new_frames`), then re-call.

---

## Status

MCP integration is **paused as work-in-progress at v6.4.1** while we gather usage signal on which tools actually get called from Claude in practice. Next iteration will prune the unused, extend the useful, and revisit the App Store / proxy story once Anthropic or Apple ships a smoother path.

See `tasks/lessons.md` for the technical lessons from getting here (Claude Desktop config format, AMFI sandboxed-CLI rejection, sandbox-write redirects, NSHostingView intrinsic-size pitfall).
