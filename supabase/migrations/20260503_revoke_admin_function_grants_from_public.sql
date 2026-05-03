-- Supplement to 20260503_revoke_admin_function_grants.sql.
-- The first migration revoked EXECUTE from anon and authenticated explicitly,
-- but Postgres also grants EXECUTE on every new function to PUBLIC by default
-- (visible as `=X/postgres` in pg_proc.proacl). PUBLIC includes anon and
-- authenticated transitively, so the advisor still flagged the functions.
--
-- This migration removes the PUBLIC grant. After applying, only the postgres
-- and service_role roles can EXECUTE these functions — exactly the intended
-- shape (server-side admin only, never callable from a client).

REVOKE EXECUTE ON FUNCTION public.admin_community_stats()         FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_delete_by_machine(text)   FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_delete_by_setup(text)     FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_purge_outliers()          FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable()               FROM PUBLIC;
