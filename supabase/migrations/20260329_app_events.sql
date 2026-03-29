-- App usage telemetry — anonymous, lightweight, fire-and-forget
-- One row per app start. Never blocks the app.

CREATE TABLE IF NOT EXISTS public.app_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    machine_hash TEXT NOT NULL,
    app_version TEXT NOT NULL,
    event TEXT NOT NULL DEFAULT 'app_started',
    chip_name TEXT,
    cpu_cores INT,
    ram_gb INT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_app_events_created
    ON public.app_events (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_app_events_device
    ON public.app_events (machine_hash, created_at DESC);

-- RLS: anon can INSERT only (no SELECT — users can't read other users' events)
ALTER TABLE public.app_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon_insert_events" ON public.app_events
    FOR INSERT TO anon WITH CHECK (true);
