-- AppMessageService.postInteraction uses Prefer: resolution=merge-duplicates
-- but message_interactions had no UNIQUE constraint matching (message_id,
-- machine_hash). PostgREST silently fell back to insert-only (or 409 once
-- duplicates accumulated). Adding the constraint makes the upsert behave
-- correctly: same (message,machine) pair gets the existing row updated.
-- Patch-1 follow-up to the W1.2 RLS audit (2026-05-03).
--
-- First de-duplicate any existing dupes (keep the most recent shown_at).
DELETE FROM public.message_interactions a
USING public.message_interactions b
WHERE a.message_id   = b.message_id
  AND a.machine_hash = b.machine_hash
  AND a.shown_at    < b.shown_at;

ALTER TABLE public.message_interactions
  ADD CONSTRAINT message_interactions_msg_machine_unique
  UNIQUE (message_id, machine_hash);
