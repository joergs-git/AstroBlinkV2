# Supabase RLS / Security Audit — 2026-05-03

**Project:** `bpngramreznwvtssrcbe` (`astroblink`)
**Region:** `eu-west-1` (Ireland)
**Audit method:** Supabase MCP `get_advisors` (security category) + direct queries against `pg_policies` and `pg_proc`.
**Status:** Multiple findings, three of them launch blockers (red), three nice-to-have (yellow), rest acceptable.

---

## Tables and RLS state

All 13 public tables have `rls_enabled = true`. ✓

| Table | Rows | Purpose |
|---|---|---|
| `app_events` | 194 | App-start telemetry pings |
| `app_messages` | 1 | In-app banner content (read-only for clients) |
| `aisaac_knowledge` | 12 | Knowledge snippets for AIsaac (public read) |
| `benchmarks` | 4 | Public stacking benchmark leaderboard |
| `bortle_grid` | 136 199 | VIIRS-derived light pollution grid (public read) |
| `community_sessions` | 49 | Per-setup community baselines |
| `community_thumbnails` | 8 | Optional reference thumbnails |
| `curated_frames` | 5 245 | Star-rated frames for algorithm training |
| `device_entitlements` | 0 | Email-redeemed entitlement tokens |
| `message_interactions` | 1 | Per-machine message read/dismiss state |
| `session_benchmarks` | 187 | Public session-load benchmark leaderboard |
| `stack_telemetry` | 8 | Stack performance telemetry |
| `target_catalog` | 533 | Deep-sky target list (public read) |

---

## 🔴 Launch blockers (must fix before v6.0.0)

### B1. `admin_*` SECURITY DEFINER functions executable by anon

Five SECURITY DEFINER functions carry `EXECUTE` for the `anon` role. Anyone with the public anon key can call these RPCs — and the anon key is in the binary by design:

| Function | Risk |
|---|---|
| `admin_delete_by_machine(target_hash text)` | **Anon can wipe any machine's curated_frames / community_sessions data.** `machine_hash` is a SHA256 truncation, but it's also returned by the SELECT policies (e.g. `community_sessions` is SELECT-anyone), so attackers can enumerate hashes and target them individually. |
| `admin_delete_by_setup(target_hash text)` | Same risk class — wipe by `setup_hash`. |
| `admin_purge_outliers()` | Anon can trigger an outlier purge across community_sessions. |
| `admin_community_stats()` | Information disclosure beyond the policies (depends on body — but should not be anon either). |
| `rls_auto_enable()` | Function name suggests it toggles RLS — anon execute should never happen. |

**Fix:** revoke `EXECUTE` from `anon` and `authenticated`, leave only `service_role`.

### B2. `curated_frames` UPDATE policy is `USING (true) WITH CHECK (true)`

Anon can UPDATE any row, including changing another user's `user_confidence` rating, file paths, or any other column. The intended pattern is `merge-duplicates` UPSERT from the same machine — that requires UPDATE permission, but it should be restricted.

**Fix:** restrict UPDATE to rows where `machine_hash` matches a header sent by the client (`X-Device-Id` is already used by AIsaac/VLM endpoints), then enforce the same in `WITH CHECK` so the new row also matches.

### B3. `message_interactions` UPDATE policy is `USING (true) WITH CHECK (true)`

Same class of issue: any anon can UPDATE any row. Lower data-sensitivity than B2 (this is impressions/dismiss state), but still allows global tampering.

**Fix:** same pattern as B2.

---

## 🟡 Should fix soon (defense in depth, can ship in patch 1)

### Y1. `device_entitlements` INSERT is `WITH CHECK (true)` for anon

Anyone can insert an entitlement row for any `machine_hash`. There is currently a server-side `auto_grant_email_entitlement` trigger (or similar) that decides which machines get an entitlement, but the INSERT path itself is unconstrained. If an attacker can guess a valid `entitlement_kind` payload, they can grant themselves AIsaac boosts.

**Fix:** restrict INSERT to require `machine_hash` to match `X-Device-Id` header AND drop client-side INSERT entirely in favor of an Edge Function that only the server uses. (Patch-1 work; not strictly launch-blocking because `0` rows today and the email-claim flow is gated by other logic.)

### Y2. 9 functions with mutable `search_path`

Standard Postgres hardening: every SECURITY DEFINER (and even SECURITY INVOKER) function should `SET search_path = public, pg_temp`. Without it, an attacker who has DDL on any other schema can shadow `public` types/functions and influence behavior.

Affected functions:
- `update_aisaac_knowledge_timestamp`
- `update_app_messages_updated_at`
- `auto_grant_email_entitlement`
- `get_community_baseline`
- `validate_community_session`
- `admin_delete_by_machine`
- `admin_delete_by_setup`
- `admin_purge_outliers`
- `admin_community_stats`

**Fix:** `ALTER FUNCTION <name>(...) SET search_path = public, pg_temp;` for each.

### Y3. `community_thumbnails` SELECT policy `(NOT flagged)` returns user-uploaded image data anonymously

Less of a security issue, more of a privacy reminder: any anonymous client can read any unflagged community thumbnail. Currently 8 rows; small surface today. Worth documenting in PRIVACY.md if/when this grows.

---

## 🟢 Acceptable as-is (intentional public-read or intentional anon-insert)

| Pattern | Tables | Why |
|---|---|---|
| INSERT `WITH CHECK (true)` anon-write telemetry | `app_events`, `benchmarks`, `community_sessions`, `community_thumbnails`, `session_benchmarks`, `stack_telemetry`, `curated_frames` | Aggregate telemetry by design — server-side validation triggers (`validate_community_session`) catch out-of-range values. INSERT-public is the correct shape. |
| SELECT `(true)` public read | `bortle_grid`, `target_catalog`, `benchmarks`, `community_sessions`, `session_benchmarks`, `curated_frames` | Public datasets / leaderboards |
| SELECT `(is_active = true)` | `aisaac_knowledge`, `app_messages` | Filtered public read |

---

## Proposed migration (`fix_rls_launch_blockers.sql`)

```sql
-- Remove anon/authenticated execute on admin_* and rls_auto_enable.
REVOKE EXECUTE ON FUNCTION public.admin_community_stats()         FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_delete_by_machine(text)   FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_delete_by_setup(text)     FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_purge_outliers()          FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable()               FROM anon, authenticated;

-- Tighten UPDATE policy on curated_frames so anon can only update own rows.
DROP POLICY "anon can update curated frames" ON public.curated_frames;
CREATE POLICY "anon can update own curated frames"
  ON public.curated_frames FOR UPDATE TO anon
  USING      (machine_hash = (current_setting('request.headers', true)::json ->> 'x-device-id'))
  WITH CHECK (machine_hash = (current_setting('request.headers', true)::json ->> 'x-device-id'));

-- Tighten UPDATE policy on message_interactions so anon can only update own rows.
DROP POLICY "anon_update_interactions" ON public.message_interactions;
CREATE POLICY "anon_update_own_interactions"
  ON public.message_interactions FOR UPDATE TO anon
  USING      (machine_hash = (current_setting('request.headers', true)::json ->> 'x-device-id'))
  WITH CHECK (machine_hash = (current_setting('request.headers', true)::json ->> 'x-device-id'));

-- Pin search_path on every public function (defense in depth).
ALTER FUNCTION public.update_aisaac_knowledge_timestamp()         SET search_path = public, pg_temp;
ALTER FUNCTION public.update_app_messages_updated_at()            SET search_path = public, pg_temp;
ALTER FUNCTION public.auto_grant_email_entitlement()              SET search_path = public, pg_temp;
ALTER FUNCTION public.get_community_baseline(real, real)          SET search_path = public, pg_temp;
ALTER FUNCTION public.validate_community_session()                SET search_path = public, pg_temp;
ALTER FUNCTION public.admin_delete_by_machine(text)               SET search_path = public, pg_temp;
ALTER FUNCTION public.admin_delete_by_setup(text)                 SET search_path = public, pg_temp;
ALTER FUNCTION public.admin_purge_outliers()                      SET search_path = public, pg_temp;
ALTER FUNCTION public.admin_community_stats()                     SET search_path = public, pg_temp;
```

### Client-side change paired with B2/B3

`CurationService.swift` and `AppMessageService.swift` must send `X-Device-Id: <machine_hash>` on every request to `curated_frames` (UPSERT path) and `message_interactions` (UPSERT/PATCH path). AIsaacService and VisualAnomalyDetector already do this — pattern is established.

If the migration is applied without the client header, the upsert that replaces an existing row will fail (UPDATE leg of the merge). New inserts continue to work.

---

## Region note

Project region is `eu-west-1` (Supabase data center in Ireland), not US. PRIVACY.md must reflect EU storage for Supabase data, not US.
