-- Bump rated_at on every UPDATE so the merge-duplicates UPSERT path
-- (re-rate same frame) refreshes the timestamp instead of keeping the
-- original INSERT time. Lets queries filter by 'recently re-rated' correctly.
-- Patch-1 follow-up to the W1.2 RLS audit (2026-05-03).
CREATE OR REPLACE FUNCTION public.curated_frames_bump_rated_at()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.rated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS bump_rated_at_on_update ON public.curated_frames;
CREATE TRIGGER bump_rated_at_on_update
  BEFORE UPDATE ON public.curated_frames
  FOR EACH ROW
  EXECUTE FUNCTION public.curated_frames_bump_rated_at();
