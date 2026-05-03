-- Tighten UPDATE policies on curated_frames and message_interactions.
-- Previously: USING (true) WITH CHECK (true) — anon could rewrite ANY row.
-- New: row's machine_hash must match the X-Device-Id header sent by the client.
--
-- Paired with client commit 1bf677b which auto-injects X-Device-Id on every
-- request built through SupabaseClient.makeRequest. Existing flows already
-- send machine_hash in the body and this header; the merge-duplicates upsert
-- continues to work for the originating machine.
--
-- Rollback at the bottom of this file (commented out) — un-comment and run
-- as a separate migration if anything regresses post-launch.

-- curated_frames
DROP POLICY IF EXISTS "anon can update curated frames" ON public.curated_frames;
CREATE POLICY "anon can update own curated frames"
  ON public.curated_frames
  FOR UPDATE
  TO anon
  USING      (machine_hash = (current_setting('request.headers', true)::json ->> 'x-device-id'))
  WITH CHECK (machine_hash = (current_setting('request.headers', true)::json ->> 'x-device-id'));

-- message_interactions
DROP POLICY IF EXISTS "anon_update_interactions" ON public.message_interactions;
CREATE POLICY "anon_update_own_interactions"
  ON public.message_interactions
  FOR UPDATE
  TO anon
  USING      (machine_hash = (current_setting('request.headers', true)::json ->> 'x-device-id'))
  WITH CHECK (machine_hash = (current_setting('request.headers', true)::json ->> 'x-device-id'));

-- ROLLBACK (only if a regression appears after deploy):
-- DROP POLICY IF EXISTS "anon can update own curated frames" ON public.curated_frames;
-- CREATE POLICY "anon can update curated frames"
--   ON public.curated_frames FOR UPDATE TO anon USING (true) WITH CHECK (true);
-- DROP POLICY IF EXISTS "anon_update_own_interactions" ON public.message_interactions;
-- CREATE POLICY "anon_update_interactions"
--   ON public.message_interactions FOR UPDATE TO anon USING (true) WITH CHECK (true);
