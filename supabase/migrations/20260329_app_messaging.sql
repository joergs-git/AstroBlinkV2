-- ============================================================
-- Migration: In-App Messaging & Engagement System
-- Run in Supabase SQL Editor (Dashboard > SQL Editor > New Query)
-- ============================================================

-- 1. Messages table — developer creates rows via Supabase dashboard
CREATE TABLE IF NOT EXISTS public.app_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Content
    title TEXT NOT NULL,
    body TEXT NOT NULL,                    -- Markdown-capable (links, bold, privacy text)
    message_type TEXT NOT NULL DEFAULT 'info'
        CHECK (message_type IN ('info', 'warning', 'update_nudge', 'feedback', 'email_collect')),
    display_mode TEXT NOT NULL DEFAULT 'banner'
        CHECK (display_mode IN ('banner', 'modal')),
    actions JSONB NOT NULL DEFAULT '[]'::jsonb,  -- Array of action objects

    -- Targeting (all nullable = no restriction)
    min_app_version TEXT,
    max_app_version TEXT,
    platform TEXT NOT NULL DEFAULT 'all'
        CHECK (platform IN ('macos', 'ios', 'all')),
    min_session_count INT,
    min_frame_count INT,
    max_frame_count INT,

    -- Conditional targeting (based on previous responses/entitlements)
    requires_entitlement TEXT,             -- Only show if device HAS this entitlement
    excludes_entitlement TEXT,             -- Only show if device does NOT have this
    requires_response_to UUID REFERENCES public.app_messages(id),
    excludes_response_to UUID REFERENCES public.app_messages(id),

    -- Scheduling
    starts_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ,               -- NULL = never expires
    snooze_hours INT NOT NULL DEFAULT 168, -- Default snooze: 1 week

    -- Repeat behavior
    repeat_mode TEXT NOT NULL DEFAULT 'once'
        CHECK (repeat_mode IN ('once', 'always', 'interval')),
    repeat_interval_hours INT,            -- For 'interval' mode: re-show every N hours after dismiss

    -- Control
    is_active BOOLEAN NOT NULL DEFAULT true,
    priority INT NOT NULL DEFAULT 0,       -- Higher = shown first

    -- Metadata
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_app_messages_active
    ON public.app_messages (is_active, platform, starts_at, expires_at);

-- 2. Interactions table — tracks impressions + responses per device per message
CREATE TABLE IF NOT EXISTS public.message_interactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id UUID NOT NULL REFERENCES public.app_messages(id) ON DELETE CASCADE,
    machine_hash TEXT NOT NULL,            -- Anonymous 12-char device hash
    app_version TEXT NOT NULL,

    -- Impression tracking
    shown_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    shown_count INT NOT NULL DEFAULT 1,
    last_shown_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Response (filled when user acts)
    responded_at TIMESTAMPTZ,
    action_type TEXT,                      -- Which action was taken
    response_value TEXT,                   -- The actual value (email, text, radio option, slider value)

    -- Dismiss/snooze tracking
    dismissed_at TIMESTAMPTZ,
    snoozed_until TIMESTAMPTZ
);

-- One interaction per device per message (UPSERT on conflict)
CREATE UNIQUE INDEX IF NOT EXISTS idx_message_interactions_unique
    ON public.message_interactions (message_id, machine_hash);
CREATE INDEX IF NOT EXISTS idx_message_interactions_device
    ON public.message_interactions (machine_hash);

-- 3. Device entitlements — feature flags per device
CREATE TABLE IF NOT EXISTS public.device_entitlements (
    machine_hash TEXT NOT NULL,
    entitlement TEXT NOT NULL,             -- e.g. 'email_verified', 'aisaac_boost', 'beta_tester'
    value TEXT,                            -- Optional payload (email address, custom limit, etc.)
    granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ,               -- NULL = permanent

    PRIMARY KEY (machine_hash, entitlement)
);

CREATE INDEX IF NOT EXISTS idx_device_entitlements_device
    ON public.device_entitlements (machine_hash);

-- 4. RLS
ALTER TABLE public.app_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_interactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.device_entitlements ENABLE ROW LEVEL SECURITY;

-- app_messages: anon can only SELECT active messages
CREATE POLICY "anon_select_active_messages" ON public.app_messages
    FOR SELECT TO anon USING (is_active = true);

-- message_interactions: anon can INSERT and SELECT
CREATE POLICY "anon_insert_interactions" ON public.message_interactions
    FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_update_interactions" ON public.message_interactions
    FOR UPDATE TO anon USING (true) WITH CHECK (true);
CREATE POLICY "anon_select_interactions" ON public.message_interactions
    FOR SELECT TO anon USING (true);

-- device_entitlements: anon can SELECT own + INSERT (auto-grant via trigger)
CREATE POLICY "anon_select_entitlements" ON public.device_entitlements
    FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_entitlements" ON public.device_entitlements
    FOR INSERT TO anon WITH CHECK (true);

-- 5. Auto-update updated_at on app_messages
CREATE OR REPLACE FUNCTION update_app_messages_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER app_messages_updated_at
    BEFORE UPDATE ON public.app_messages
    FOR EACH ROW EXECUTE FUNCTION update_app_messages_updated_at();

-- 6. Auto-grant entitlements when email is submitted
CREATE OR REPLACE FUNCTION auto_grant_email_entitlement()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.action_type = 'email_input' AND NEW.response_value IS NOT NULL
       AND NEW.response_value LIKE '%@%.%' THEN
        -- Grant email_verified with the email as value
        INSERT INTO public.device_entitlements (machine_hash, entitlement, value)
        VALUES (NEW.machine_hash, 'email_verified', NEW.response_value)
        ON CONFLICT (machine_hash, entitlement) DO UPDATE SET value = EXCLUDED.value;

        -- Grant aisaac_boost with increased daily limit
        INSERT INTO public.device_entitlements (machine_hash, entitlement, value)
        VALUES (NEW.machine_hash, 'aisaac_boost', '50')
        ON CONFLICT (machine_hash, entitlement) DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER on_email_response
    AFTER INSERT OR UPDATE ON public.message_interactions
    FOR EACH ROW EXECUTE FUNCTION auto_grant_email_entitlement();
