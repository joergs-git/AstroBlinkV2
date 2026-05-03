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

Server-driven announcements, feedback collection, and feature announcements.

### Table Schema

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Auto-generated |
| `title` | TEXT | Message title shown in banner |
| `body` | TEXT | Message body (supports markdown-like formatting) |
| `message_type` | TEXT | `info`, `warning`, `feedback`, `announcement`, `survey` |
| `platform` | TEXT | `macos`, `ios`, `all` |
| `priority` | INT | Higher = shown first |
| `min_version` | TEXT | Minimum app version to show |
| `max_version` | TEXT | Maximum app version to show |
| `is_active` | BOOL | Active flag |
| `repeat_mode` | TEXT | `once`, `always`, `interval` |
| `repeat_interval_hours` | INT | For `interval` mode |
| `actions` | JSONB | Rich action buttons (see below) |
| `targeting` | JSONB | User targeting rules |
| `created_at` | TIMESTAMPTZ | Creation time |

### Action Types

```json
// Simple yes/no
{"actions": [
    {"type": "yes", "label": "Got it"},
    {"type": "no", "label": "Dismiss"}
]}

// Email collection (grants AIsaac boost)
{"actions": [
    {"type": "email", "label": "Get 50 AIsaac queries/day", "placeholder": "your@email.com"},
    {"type": "no", "label": "Maybe later"}
]}

// Rating slider
{"actions": [
    {"type": "slider", "label": "Rate AIsaac", "min": 1, "max": 5},
    {"type": "text", "label": "Any feedback?", "placeholder": "Tell us..."}
]}

// Radio buttons
{"actions": [
    {"type": "radio", "label": "How do you image?",
     "options": ["Observatory/dome", "Portable setup", "Remote hosting"]}
]}
```

### Common Operations

**Announce a new feature:**
```sql
INSERT INTO app_messages (title, body, message_type, platform, priority, min_version, repeat_mode, actions)
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
    '[{"type": "radio", "label": "Setup type", "options": ["Permanent observatory/dome", "Portable (setup each night)", "Remote hosting service", "Mix of both"]}, {"type": "text", "label": "Anything else?", "placeholder": "Optional"}]'
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
