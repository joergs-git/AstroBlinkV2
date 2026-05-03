-- Revoke EXECUTE on admin_* SECURITY DEFINER functions from anon and authenticated.
-- Without this, anyone with the public anon key (which lives in the client binary
-- by design) can call admin_delete_by_machine / admin_delete_by_setup and wipe out
-- other users' curated_frames or community_sessions data. The machine_hash values
-- they would need are exposed via SELECT-anyone policies, so the attack is trivial.
--
-- After this migration these functions are still callable by service_role (server-side),
-- which is the only intended caller.

REVOKE EXECUTE ON FUNCTION public.admin_community_stats()         FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_delete_by_machine(text)   FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_delete_by_setup(text)     FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_purge_outliers()          FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable()               FROM anon, authenticated;
