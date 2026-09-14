# Supabase Admin Guide

How to manage AIsaac knowledge, in-app messages, and other server-side features.

**Project:** `astroblink` (eu-west-1)
**Dashboard:** https://supabase.com/dashboard/project/bpngramreznwvtssrcbe

> **Shared with AstroSharper (since 2026-05-03).** AstroBlink and AstroSharper write to the same Postgres project. Every shared table carries an `app` discriminator column (`'astroblink'` vs `'astrosharper'`); existing AstroBlink rows in `app_events` were backfilled to `'astroblink'` via a `DEFAULT` clause. AstroSharper-only tables: `stack_telemetry`, `community_thumbnails`. AstroSharper-only edge functions: `stack-completed`, `community-thumbnail`. Never spin up a new Supabase project for sister apps — extend this one.

---

## AIsaac Remote Knowledge (`aisaac_knowledge`)

Update AIsaac's knowledge without releasing a new app version. Changes take effect within 1 hour on all deployed apps.

### Table Schema

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Auto-generated |
| `topic` | TEXT (unique) | Short identifier, e.g. `bortle_viirs_2024` |
| `content` | TEXT | Full knowledge text — included in Claude system prompt |
| `priority` | INT | Higher = shown first (10 = critical, 5 = normal, 1 = low) |
| `min_app_version` | TEXT | Only show to apps ≥ this version (e.g. `5.8.0`). NULL = all |
| `max_app_version` | TEXT | Only show to apps ≤ this version. NULL = all |
| `is_active` | BOOL | Set `false` to deactivate without deleting |
| `updated_at` | TIMESTAMPTZ | Auto-updated on every change |

### Common Operations

**Add new knowledge:**
```sql
INSERT INTO aisaac_knowledge (topic, content, priority, min_app_version)
VALUES (
    'new_feature_name',
    'FEATURE NAME:
    Description of the feature for AIsaac to reference when answering user questions.
    Include: what it does, how the user interacts with it, tips, caveats.',
    5,
    '5.9.0'
);
```

**Update existing knowledge:**
```sql
UPDATE aisaac_knowledge
SET content = 'Updated description...',
    min_app_version = '5.8.0'
WHERE topic = 'bortle_viirs_2024';
```

**Deactivate (soft delete):**
```sql
UPDATE aisaac_knowledge SET is_active = false WHERE topic = 'old_topic';
```

**Check current state:**
```sql
SELECT topic, priority, min_app_version, is_active,
       length(content) as chars, updated_at
FROM aisaac_knowledge ORDER BY priority DESC;
```

**Version-gate for upcoming release:**
```sql
-- Only apps v5.9.0+ will see this
INSERT INTO aisaac_knowledge (topic, content, priority, min_app_version)
VALUES ('plate_solving', 'PLATE SOLVING: ...', 7, '5.9.0');
```

### Token Budget

Keep total content under ~3000 tokens (~12KB). The app fetches ALL active snippets and appends them to the system prompt. Current snippets:

| Topic | Priority | Chars | Version |
|-------|----------|-------|---------|
| bortle_viirs_2024 | 10 | ~960 | ≥5.7.0 |
| history_charts_v58 | 8 | ~860 | ≥5.8.0 |
| session_planner | 7 | ~670 | ≥5.8.0 |
| target_catalog | 5 | ~550 | ≥5.8.0 |

---

## In-App Messages (`app_messages`)

Server-driven announcements, feedback collection and feature announcements. Messages appear
without an app update: create a row, and it shows up at the next launch of every app that
matches the targeting.

> **Column names below are the real ones.** Earlier revisions of this guide listed
> `min_version`, `max_version` and a `targeting` JSONB column — none of those exist. Targeting
> lives in flat columns.

### Table Schema

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Auto-generated |
| `title` | TEXT | Headline |
| `body` | TEXT | Markdown (`**bold**`, `*italic*`, `[text](https://…)`) |
| `message_type` | TEXT | `info` · `warning` · `update_nudge` · `feedback` · `email_collect` — picks the icon and accent colour |
| `display_mode` | TEXT | `banner` (slim strip at the top, default) · `modal` (blocking popup) |
| `media_url` | TEXT | YouTube/Vimeo URL — popup only (v6.9.0+) |
| `media_type` | TEXT | `video`, or NULL. Required whenever `media_url` is set |
| `poster_url` | TEXT | Reserved, not yet rendered |
| `actions` | JSONB | Buttons and inputs (see below) |
| `platform` | TEXT | `macos` · `ios` · `all` |
| `min_app_version` | TEXT | Lowest app version that sees it (semver) |
| `max_app_version` | TEXT | Highest app version that sees it |
| `min_session_count` | INT | Only for users with at least this many sessions |
| `min_frame_count` / `max_frame_count` | INT | Frames in the user's history |
| `requires_entitlement` / `excludes_entitlement` | TEXT | e.g. `aisaac_boost` |
| `requires_response_to` / `excludes_response_to` | UUID | Chain messages by prior answer |
| `starts_at` | TIMESTAMPTZ | Defaults to now |
| `expires_at` | TIMESTAMPTZ | NULL = never |
| `snooze_hours` | INT | How long "Later" hides it (default 168) |
| `repeat_mode` | TEXT | `once` · `always` · `interval` |
| `repeat_interval_hours` | INT | For `interval` |
| `is_active` | BOOL | The master switch — flip to false to pull a message instantly |
| `priority` | INT | Higher wins; only ONE message is shown at a time |

### Action Types

`type` values are exactly: `dismiss`, `yes`, `no`, `later`, `email_input`, `text_input`,
`radio`, `slider`, `link`.

```json
// Simple yes/no
{"actions": [
    {"type": "yes", "label": "Got it"},
    {"type": "no", "label": "Dismiss"}
]}

// Email collection (grants AIsaac boost)
{"actions": [
    {"type": "email_input", "label": "Get 50 AIsaac queries/day", "placeholder": "your@email.com"},
    {"type": "later", "label": "Maybe later"}
]}

// Rating slider
{"actions": [
    {"type": "slider", "label": "Rate AIsaac", "min": 1, "max": 5},
    {"type": "text_input", "label": "Any feedback?", "placeholder": "Tell us..."}
]}

// Radio buttons
{"actions": [
    {"type": "radio", "label": "How do you image?",
     "options": ["Observatory/dome", "Portable setup", "Remote hosting"]}
]}

// External link (https only — anything else is ignored by the app)
{"actions": [
    {"type": "link", "label": "Read the notes", "url": "https://github.com/joergs-git/AstroBlinkV2/releases"}
]}
```

---

### Popup with a video, short text and a link (v6.9.0+)

The common case: announce a feature with a short clip, a sentence or two, and a link.

**1. Upload the video to YouTube** (unlisted is fine — unlisted videos play in embeds;
*private* ones do not). Copy the normal watch URL, e.g.
`https://www.youtube.com/watch?v=dQw4w9WgXcQ`. Short links (`https://youtu.be/…`), embed
links and Vimeo links all work — the app normalises them.

**2. Insert the row:**

```sql
INSERT INTO public.app_messages (
    title, body, message_type, display_mode,
    media_url, media_type,
    actions, platform, expires_at, repeat_mode, snooze_hours, priority
) VALUES (
    'Plate solving is here',
    E'AstroBlink can now plate-solve a whole session with **ASTAP** — 0.3 s per frame, '
     || E'and it tells you when a FOCALLEN header disagrees with reality.\n\n'
     || E'Watch the clip, then find it under *Window → Plate Solve Frames…*',
    'info',
    'modal',                                              -- popup, not the slim banner
    'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    'video',
    '[{"type":"link","label":"Read the release notes","url":"https://github.com/joergs-git/AstroBlinkV2/releases"},
      {"type":"later","label":"Later"}]'::jsonb,
    'macos',
    now() + interval '21 days',                           -- or NULL to run until you pull it
    'once',
    168,
    10
);
```

**3. Pull it again** at any time — no app update needed:

```sql
UPDATE public.app_messages SET is_active = false WHERE id = '<uuid>';
```

#### What the user sees

Title with the `message_type` icon · the video player · the markdown body · then the action
buttons and **Close**. Below the player sits an **Open in browser** button that opens the
video full size in the user's normal browser.

#### Rules worth knowing before you write the row

- **Popup and video need app ≥ 6.9.0.** Older builds ignore `display_mode` and `media_url`
  and render the same row as a **banner** — so write the body so it stands on its own without
  the video. Set `min_app_version = '6.9.0'` only if older builds should not see it at all.
- **`media_url` requires `media_type = 'video'`** — a CHECK constraint rejects the row otherwise.
- **Only YouTube and Vimeo, only https.** The app enforces an exact host allowlist and an
  exact URL shape; anything else renders as a text-only popup, silently. Test the row yourself
  before relying on it.
- **Every link must be https** — in `actions` and in the markdown body. Other schemes are
  stripped and the link degrades to plain text.
- **Videos do not autoplay.** The viewer presses play.
- **Only the highest-`priority` matching message is shown**, one at a time.
- **Testing without disturbing users:** set `min_app_version` above every released version
  (e.g. `'9.9.9'`) while you check it, then lower it when you are happy. Delete the test row
  when done — `message_interactions` rows cascade with it.

---

### Common Operations


**Announce a new feature:**
```sql
INSERT INTO app_messages (title, body, message_type, platform, priority, min_app_version, repeat_mode, actions)
VALUES (
    'New: Chart Hover Tooltips',
    'Hover any data point in the History charts to see detailed breakdowns — targets, filters, FWHM, moon phase, and likely causes for bad nights.',
    'announcement',
    'macos',
    5,
    '5.8.0',
    'once',
    '[{"type": "yes", "label": "Nice!"}]'
);
```

**Collect feedback:**
```sql
INSERT INTO app_messages (title, body, message_type, platform, priority, repeat_mode, actions)
VALUES (
    'Quick Question',
    'Do you use a permanent observatory or portable setup? This helps us improve session planning.',
    'survey',
    'all',
    3,
    'once',
    '[{"type": "radio", "label": "Setup type", "options": ["Permanent observatory/dome", "Portable (setup each night)", "Remote hosting service", "Mix of both"]}, {"type": "text_input", "label": "Anything else?", "placeholder": "Optional"}]'
);
```

**Deactivate a message:**
```sql
UPDATE app_messages SET is_active = false WHERE id = 'uuid-here';
```

**Check interactions:**
```sql
SELECT m.title, COUNT(i.id) as responses,
       COUNT(CASE WHEN i.response_action = 'yes' THEN 1 END) as yes_count,
       COUNT(CASE WHEN i.response_action = 'no' THEN 1 END) as no_count
FROM app_messages m
LEFT JOIN message_interactions i ON i.message_id = m.id::text
GROUP BY m.id, m.title;
```

---

## Device Entitlements (`device_entitlements`)

Per-device feature flags and rate limits.

**Grant AIsaac boost (after email signup):**
```sql
INSERT INTO device_entitlements (machine_hash, entitlement_key, entitlement_value)
VALUES ('abc123...', 'aisaac_daily_limit', '50')
ON CONFLICT (machine_hash, entitlement_key) DO UPDATE SET entitlement_value = '50';
```

**Check a device's entitlements:**
```sql
SELECT * FROM device_entitlements WHERE machine_hash = 'abc123...';
```

---

## Bortle VIIRS Lookup (`viirs_bortle_2024`)

136K grid cells at 0.1° resolution. App queries by lat/lon.

**Check a location:**
```sql
SELECT bortle_class, radiance
FROM viirs_bortle_2024
WHERE lat = round(52.0, 1) AND lon = round(5.0, 1);
```

---

## Useful Admin Queries

**App usage overview:**
```sql
SELECT date_trunc('day', created_at) as day, COUNT(*) as starts
FROM app_events WHERE event_type = 'app_start'
GROUP BY day ORDER BY day DESC LIMIT 14;
```

**Active devices per version:**
```sql
SELECT app_version, COUNT(DISTINCT machine_hash) as devices
FROM app_events WHERE event_type = 'app_start'
  AND created_at > now() - interval '7 days'
GROUP BY app_version ORDER BY app_version DESC;
```

**Community detection uploads:**
```sql
SELECT COUNT(*) as uploads, AVG(frame_count) as avg_frames
FROM community_baselines WHERE created_at > now() - interval '7 days';
```
