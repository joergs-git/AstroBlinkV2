-- Security audit 2026-10-16 — persistent API limits with a kill switch, PII-safe
-- read policies, header-bound writes, a hardened entitlement trigger, spam guards.
--
-- Findings and rationale: supabase/SECURITY_AUDIT_2026-10.md (B1–B5).
--
-- Backward compatibility
--   Every AstroBlink build >= 6.0.0 sends `x-device-id: <machine_hash>` on EVERY
--   REST request (SupabaseClient.makeRequest), so the own-row policies below are
--   invisible to all builds seen in telemetry (6.6.0 .. 6.9.1). A pre-6.0 build
--   (none active in the last 60 days) would get empty reads and rejected writes —
--   never a crash, every call site tolerates a non-2xx.
--   AstroSharper (sister app, separate repo) writes app_events, stack_telemetry and
--   community_thumbnails; those three tables are deliberately NOT header-bound here.
--
-- This file is NOT applied automatically. Apply after review with the Supabase MCP
-- `apply_migration` or `supabase db push`, then run the smoke test in the report.

begin;

-- =========================================================================
-- 1. Persistent usage counters + per-function limits / kill switch (B1, B4)
-- =========================================================================
-- Both tables are service-role only: RLS on with no policies, every grant
-- revoked from anon/authenticated (Supabase's default privileges would
-- otherwise hand them full access the moment the table is created).

create table if not exists public.api_limits (
    function_name     text primary key,
    enabled           boolean not null default true,
    device_daily      integer not null check (device_daily >= 0),
    ip_daily          integer not null check (ip_daily >= 0),
    global_daily      integer not null check (global_daily >= 0),
    -- Optional device_entitlements.entitlement whose numeric value RAISES the
    -- per-device limit (e.g. 'aisaac_boost' = '50'). Replaces the per-request
    -- lookup the Edge Function used to do with a string-built PostgREST filter.
    boost_entitlement text,
    note              text,
    updated_at        timestamptz not null default now()
);

comment on table public.api_limits is
    'Daily limits + kill switch per Edge Function. enabled=false → the function answers 503 on the next request, no redeploy needed. Service role only.';

create table if not exists public.api_usage (
    day           date not null,
    function_name text not null,
    scope         text not null check (scope in ('device', 'ip', 'global')),
    subject       text not null,          -- machine_hash | day-salted ip hash | '*'
    count         integer not null default 0,
    updated_at    timestamptz not null default now(),
    primary key (day, function_name, scope, subject)
);

comment on table public.api_usage is
    'Per-day request counters written only by api_usage_check(). subject is a machine hash, a day-salted SHA-256 of the client IP (never the IP itself) or ''*'' for the global bucket. Rows older than 14 days are pruned by the function.';

alter table public.api_limits enable row level security;
alter table public.api_usage  enable row level security;
revoke all on table public.api_limits from public, anon, authenticated;
revoke all on table public.api_usage  from public, anon, authenticated;

-- Seed. Device limits are unchanged from the old in-memory code (20 / 10 / 50);
-- the IP and global caps are new. All values are meant to be tuned with a plain
-- UPDATE — see the admin guide.
insert into public.api_limits (function_name, enabled, device_daily, ip_daily, global_daily, boost_entitlement, note)
values
    ('ask-aisaac',       true, 20,  100,  300,  'aisaac_boost', 'Claude Sonnet text chat. Device limit raised by aisaac_boost entitlement (email opt-in).'),
    ('vlm-check',        true, 10,   30,  100,  null,           'Claude Opus + extended thinking vision check, ~0.90 USD per call.'),
    ('weather-forecast', true, 50,  200, 2000,  null,           'Meteoblue proxy, cached 2 h per 0.05 deg grid cell.')
on conflict (function_name) do nothing;

-- One round trip, atomic, decides AND counts.
--   • device and ip buckets are always incremented (so abuse volume is visible),
--   • the global bucket only when the request is otherwise allowed, so a blocked
--     attacker cannot drain the budget for everybody else,
--   • an IP of 'unknown' (no proxy header) is counted but never blocks — only the
--     platform's proxies can set those headers, a client cannot force 'unknown'.
create or replace function public.api_usage_check(p_function text, p_device text, p_ip text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    lim            public.api_limits%rowtype;
    v_today        date := (now() at time zone 'utc')::date;
    v_device_limit integer;
    v_boost        text;
    v_device       integer := 0;
    v_ip           integer := 0;
    v_global       integer := 0;
begin
    select * into lim from public.api_limits where function_name = p_function;
    if not found then
        return jsonb_build_object('allowed', false, 'reason', 'unknown_function',
            'limit', 0, 'remaining', 0, 'ip_count', 0, 'ip_limit', 0, 'global_count', 0, 'global_limit', 0);
    end if;
    if not lim.enabled then
        return jsonb_build_object('allowed', false, 'reason', 'disabled',
            'limit', lim.device_daily, 'remaining', 0, 'ip_count', 0, 'ip_limit', lim.ip_daily,
            'global_count', 0, 'global_limit', lim.global_daily);
    end if;

    v_device_limit := lim.device_daily;
    if lim.boost_entitlement is not null then
        select value into v_boost
          from public.device_entitlements
         where machine_hash = p_device
           and entitlement = lim.boost_entitlement
           and (expires_at is null or expires_at > now());
        if v_boost ~ '^\d{1,6}$' then
            v_device_limit := greatest(v_device_limit, v_boost::integer);
        end if;
    end if;

    insert into public.api_usage as u (day, function_name, scope, subject, count)
    values (v_today, p_function, 'device', p_device, 1)
    on conflict (day, function_name, scope, subject)
    do update set count = u.count + 1, updated_at = now()
    returning u.count into v_device;

    insert into public.api_usage as u (day, function_name, scope, subject, count)
    values (v_today, p_function, 'ip', coalesce(nullif(p_ip, ''), 'unknown'), 1)
    on conflict (day, function_name, scope, subject)
    do update set count = u.count + 1, updated_at = now()
    returning u.count into v_ip;

    if v_device > v_device_limit then
        return jsonb_build_object('allowed', false, 'reason', 'device_limit',
            'limit', v_device_limit, 'remaining', 0, 'ip_count', v_ip, 'ip_limit', lim.ip_daily,
            'global_count', 0, 'global_limit', lim.global_daily);
    end if;
    if coalesce(nullif(p_ip, ''), 'unknown') <> 'unknown' and v_ip > lim.ip_daily then
        return jsonb_build_object('allowed', false, 'reason', 'ip_limit',
            'limit', v_device_limit, 'remaining', greatest(v_device_limit - v_device, 0),
            'ip_count', v_ip, 'ip_limit', lim.ip_daily, 'global_count', 0, 'global_limit', lim.global_daily);
    end if;

    insert into public.api_usage as u (day, function_name, scope, subject, count)
    values (v_today, p_function, 'global', '*', 1)
    on conflict (day, function_name, scope, subject)
    do update set count = u.count + 1, updated_at = now()
    returning u.count into v_global;

    -- First global hit of the day for this function: prune old counters.
    if v_global = 1 then
        delete from public.api_usage where day < v_today - 14;
    end if;

    if v_global > lim.global_daily then
        return jsonb_build_object('allowed', false, 'reason', 'global_limit',
            'limit', v_device_limit, 'remaining', greatest(v_device_limit - v_device, 0),
            'ip_count', v_ip, 'ip_limit', lim.ip_daily, 'global_count', v_global, 'global_limit', lim.global_daily);
    end if;

    return jsonb_build_object('allowed', true, 'reason', null,
        'limit', v_device_limit, 'remaining', greatest(v_device_limit - v_device, 0),
        'ip_count', v_ip, 'ip_limit', lim.ip_daily, 'global_count', v_global, 'global_limit', lim.global_daily);
end;
$$;

comment on function public.api_usage_check(text, text, text) is
    'Rate-limit decision for an Edge Function call: increments the device/ip/global day counters in api_usage and compares them with api_limits. Service role only.';

revoke execute on function public.api_usage_check(text, text, text) from public, anon, authenticated;
grant  execute on function public.api_usage_check(text, text, text) to service_role;

-- =========================================================================
-- 2. device_entitlements — no anon writes, own rows only (B2)
-- =========================================================================
-- The trigger that grants `email_verified` + `aisaac_boost` after an e-mail
-- answer used to run as SECURITY INVOKER, i.e. as anon — it only worked
-- BECAUSE anon could insert into device_entitlements. It now runs as its owner,
-- so the anon INSERT policy can go. It also checks that the answer belongs to
-- an active message and looks like exactly one e-mail address.
create or replace function public.auto_grant_email_entitlement()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if NEW.action_type = 'email_input'
       and NEW.response_value is not null
       and length(NEW.response_value) <= 254
       and NEW.response_value ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
       and exists (select 1 from public.app_messages m where m.id = NEW.message_id and m.is_active)
    then
        insert into public.device_entitlements (machine_hash, entitlement, value)
        values (NEW.machine_hash, 'email_verified', NEW.response_value)
        on conflict (machine_hash, entitlement) do update set value = excluded.value;

        insert into public.device_entitlements (machine_hash, entitlement, value)
        values (NEW.machine_hash, 'aisaac_boost', '50')
        on conflict (machine_hash, entitlement) do nothing;
    end if;
    return NEW;
end;
$$;

revoke execute on function public.auto_grant_email_entitlement() from public, anon, authenticated;

drop policy if exists "anon_insert_entitlements" on public.device_entitlements;
drop policy if exists "anon_select_entitlements" on public.device_entitlements;

-- `value` carries the user's e-mail address for `email_verified` → never public.
create policy "anon_select_own_entitlements"
    on public.device_entitlements for select to anon
    using (machine_hash = (current_setting('request.headers', true)::json ->> 'x-device-id'));

revoke insert, update, delete, truncate, references, trigger
    on table public.device_entitlements from anon, authenticated;

-- =========================================================================
-- 3. message_interactions — own rows only, writes bound to the header (B2/B3)
-- =========================================================================
-- `response_value` holds the typed e-mail address → own rows only.
drop policy if exists "anon_select_interactions" on public.message_interactions;
create policy "anon_select_own_interactions"
    on public.message_interactions for select to anon
    using (machine_hash = (current_setting('request.headers', true)::json ->> 'x-device-id'));

drop policy if exists "anon_insert_interactions" on public.message_interactions;
create policy "anon_insert_own_interactions"
    on public.message_interactions for insert to anon
    with check (machine_hash = (current_setting('request.headers', true)::json ->> 'x-device-id'));

-- (UPDATE policy "anon_update_own_interactions" from 2026-05-03 stays as is.)
revoke delete, truncate, references, trigger
    on table public.message_interactions from anon, authenticated;

-- =========================================================================
-- 4. curated_frames — own rows only, header-bound insert, working delete (B3)
-- =========================================================================
-- The app never reads other devices' rows (the owner analyses the table with
-- the service role), so the public SELECT goes. Side finding of the audit: the
-- table never had a DELETE policy, so "clear rating" in the app was a silent
-- 204 that deleted nothing — fixed by the own-row DELETE policy below.
drop policy if exists "anon can select curated frames" on public.curated_frames;
create policy "anon can select own curated frames"
    on public.curated_frames for select to anon
    using (machine_hash = (current_setting('request.headers', true)::json ->> 'x-device-id'));

drop policy if exists "anon can insert curated frames" on public.curated_frames;
create policy "anon can insert own curated frames"
    on public.curated_frames for insert to anon
    with check (machine_hash = (current_setting('request.headers', true)::json ->> 'x-device-id'));

drop policy if exists "anon can delete own curated frames" on public.curated_frames;
create policy "anon can delete own curated frames"
    on public.curated_frames for delete to anon
    using (machine_hash = (current_setting('request.headers', true)::json ->> 'x-device-id'));

-- (UPDATE policy "anon can update own curated frames" from 2026-05-03 stays.)
revoke truncate, references, trigger
    on table public.curated_frames from anon, authenticated;

-- =========================================================================
-- 5. Leaderboards + community baselines — inserts bound to the header (B3/B5)
-- =========================================================================
-- Rows stay publicly readable (they are leaderboards / aggregate baselines),
-- but nobody can insert a row under somebody else's machine_hash any more.
drop policy if exists "Anyone can insert" on public.benchmarks;
create policy "anon can insert own benchmarks"
    on public.benchmarks for insert to anon
    with check (machine_hash = (current_setting('request.headers', true)::json ->> 'x-device-id'));
revoke update, delete, truncate, references, trigger
    on table public.benchmarks from anon, authenticated;

drop policy if exists "Anyone can insert" on public.session_benchmarks;
create policy "anon can insert own session benchmarks"
    on public.session_benchmarks for insert to anon
    with check (machine_hash = (current_setting('request.headers', true)::json ->> 'x-device-id'));
revoke update, delete, truncate, references, trigger
    on table public.session_benchmarks from anon, authenticated;

drop policy if exists "Anon insert" on public.community_sessions;
create policy "anon can insert own community sessions"
    on public.community_sessions for insert to anon
    with check (machine_hash = (current_setting('request.headers', true)::json ->> 'x-device-id'));
-- ("Admin delete" for service_role and "Anon select" stay.)
revoke update, delete, truncate, references, trigger
    on table public.community_sessions from anon, authenticated;

-- =========================================================================
-- 6. Defence in depth — privileges no client ever needs (B5)
-- =========================================================================
-- Supabase grants anon/authenticated ALL privileges on every public table by
-- default and relies on RLS alone. TRUNCATE is not even subject to RLS.
revoke truncate, references, trigger on all tables in schema public from anon, authenticated;

-- Read-only catalog / content tables: no write path exists in any client.
revoke insert, update, delete on table public.aisaac_knowledge from anon, authenticated;
revoke insert, update, delete on table public.app_messages     from anon, authenticated;
revoke insert, update, delete on table public.bortle_grid      from anon, authenticated;
revoke insert, update, delete on table public.target_catalog   from anon, authenticated;

-- Telemetry tables shared with AstroSharper: keep INSERT, drop the rest.
revoke update, delete on table public.app_events           from anon, authenticated;
revoke update, delete on table public.stack_telemetry      from anon, authenticated;
revoke update, delete on table public.community_thumbnails from anon, authenticated;

-- =========================================================================
-- 7. Spam guards — text lengths and physically impossible numbers (B5)
-- =========================================================================
-- NOT VALID: enforced for every new/updated row, existing rows are not
-- re-checked (so the migration cannot fail on legacy data). Bounds are far
-- above anything real hardware produces (checked against live maxima).
alter table public.benchmarks
    add constraint benchmarks_text_lengths check (
        length(machine_hash) <= 64 and length(machine_model) <= 100 and length(chip_name) <= 100
        and length(app_version) <= 50 and length(stack_engine) <= 50) not valid,
    add constraint benchmarks_numeric_ranges check (
        stack_time_ms between 1 and 86400000 and file_count between 1 and 1000000
        and image_megapixels between 0 and 100000 and cpu_cores between 1 and 4096
        and ram_gb between 1 and 1048576) not valid;

alter table public.session_benchmarks
    add constraint session_benchmarks_text_lengths check (
        length(machine_hash) <= 64 and length(machine_model) <= 100 and length(chip_name) <= 100
        and length(app_version) <= 50 and length(source_type) <= 50) not valid,
    add constraint session_benchmarks_numeric_ranges check (
        file_count between 1 and 10000000 and total_size_bytes between 0 and 10000000000000000
        and scan_ms between 0 and 86400000 and first_image_ms between 0 and 86400000
        and header_ms between 0 and 86400000 and caching_ms between 0 and 86400000
        and total_ready_ms between 0 and 86400000 and cpu_cores between 1 and 4096
        and ram_gb between 1 and 1048576) not valid;

alter table public.app_events
    add constraint app_events_text_lengths check (
        length(machine_hash) <= 64 and length(app_version) <= 50 and length(event) <= 100
        and length(chip_name) <= 100 and length(app) <= 32) not valid;

alter table public.community_sessions
    add constraint community_sessions_text_lengths check (
        length(machine_hash) <= 64 and length(setup_hash) <= 64 and length(app_version) <= 50
        and length(filter_canonical) <= 64) not valid;

alter table public.message_interactions
    add constraint message_interactions_text_lengths check (
        length(machine_hash) <= 64 and length(app_version) <= 50 and length(action_type) <= 50
        and length(response_value) <= 2000) not valid;

alter table public.curated_frames
    add constraint curated_frames_text_lengths check (
        length(file_hash) <= 128 and length(machine_hash) <= 64 and length(setup_hash) <= 64
        and length(filename) <= 512 and length(telescope) <= 200 and length(camera) <= 200
        and length(target) <= 200 and length(canonical_target) <= 200 and length(filter) <= 100
        and length(garbage_reasons) <= 4000 and length(app_version) <= 50
        and length(twilight_phase) <= 50 and length(capture_date) <= 32 and length(capture_time) <= 32
        and length(observing_night) <= 32) not valid;

alter table public.device_entitlements
    add constraint device_entitlements_text_lengths check (
        length(machine_hash) <= 64 and length(entitlement) <= 64 and length(value) <= 254) not valid;

commit;
