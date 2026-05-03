-- Pin search_path on every public function (defense in depth).
-- Without an explicit search_path, an attacker with DDL on any schema in the
-- search path can shadow public types/functions and influence behavior. Setting
-- it to (public, pg_temp) is the standard hardening recommendation.
--
-- Pure metadata change — no behavior change for legitimate calls.

ALTER FUNCTION public.update_aisaac_knowledge_timestamp()         SET search_path = public, pg_temp;
ALTER FUNCTION public.update_app_messages_updated_at()            SET search_path = public, pg_temp;
ALTER FUNCTION public.auto_grant_email_entitlement()              SET search_path = public, pg_temp;
ALTER FUNCTION public.get_community_baseline(real, real)          SET search_path = public, pg_temp;
ALTER FUNCTION public.validate_community_session()                SET search_path = public, pg_temp;
ALTER FUNCTION public.admin_delete_by_machine(text)               SET search_path = public, pg_temp;
ALTER FUNCTION public.admin_delete_by_setup(text)                 SET search_path = public, pg_temp;
ALTER FUNCTION public.admin_purge_outliers()                      SET search_path = public, pg_temp;
ALTER FUNCTION public.admin_community_stats()                     SET search_path = public, pg_temp;
