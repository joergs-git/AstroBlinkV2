-- App message media (v6.9.0)
--
-- Adds optional video support to the existing in-app messaging system so an
-- announcement can carry a short clip without shipping an app update. Combined
-- with the display_mode column (present since the original schema but unread by
-- the app until v6.9.0), this enables an ad-hoc startup popup with a video.
--
-- All columns are nullable: existing rows keep working untouched, and older app
-- builds ignore what they do not know.

ALTER TABLE public.app_messages
    ADD COLUMN IF NOT EXISTS media_url  TEXT,   -- YouTube / Vimeo watch, short or embed URL
    ADD COLUMN IF NOT EXISTS media_type TEXT,   -- 'video' or NULL
    ADD COLUMN IF NOT EXISTS poster_url TEXT;   -- reserved: still image shown before playback

-- Only a known media kind may be stored. The app additionally enforces an https
-- host allowlist (YouTube / Vimeo) before handing any URL to a web view, so a
-- bad row can never turn into arbitrary navigation on the client.
ALTER TABLE public.app_messages
    DROP CONSTRAINT IF EXISTS app_messages_media_type_check;
ALTER TABLE public.app_messages
    ADD CONSTRAINT app_messages_media_type_check
    CHECK (media_type IS NULL OR media_type IN ('video'));

-- A media_url without a media_type would silently render nothing; reject it early.
ALTER TABLE public.app_messages
    DROP CONSTRAINT IF EXISTS app_messages_media_pair_check;
ALTER TABLE public.app_messages
    ADD CONSTRAINT app_messages_media_pair_check
    CHECK (media_url IS NULL OR media_type IS NOT NULL);

COMMENT ON COLUMN public.app_messages.media_url  IS 'YouTube/Vimeo URL; client accepts https + host allowlist only';
COMMENT ON COLUMN public.app_messages.media_type IS 'video, or NULL for a text-only message';
COMMENT ON COLUMN public.app_messages.poster_url IS 'Reserved for a still image shown before playback';
