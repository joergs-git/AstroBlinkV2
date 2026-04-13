-- Migration: add quality feedback counters and algorithm version to community_sessions
-- Rolls out alongside AstroBlinkV2 v5.22.0 (AlgorithmVersion 17).
--
-- Context:
--   v5.22.0 adds explicit user quality feedback (agree/disagree/partly via 'A' key).
--   Counters accumulate locally in CalibrationProfile and are uploaded per session group
--   alongside the existing algorithm agreement metrics. Enables server-side tuning of
--   detection thresholds based on cross-setup feedback rates.
--
--   algorithm_version lets us correlate baseline drift with scoring algorithm changes
--   (QualityEstimator / StarMetricsCalculator / TrailingAnalyzer etc.) so we can
--   filter baselines by the version they were scored under.
--
-- All columns default to 0 / nullable — backward-compatible with existing rows.
-- Supabase RLS insert policy remains unchanged (machine_hash-only anon insert).

BEGIN;

ALTER TABLE public.community_sessions
    ADD COLUMN IF NOT EXISTS user_agreed        INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS user_disagreed     INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS user_partly_agreed INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS algorithm_version  INTEGER;

-- Helpful indexes for server-side analytics queries.
-- algorithm_version: filter baselines by scoring version for drift analysis.
-- Compound feedback index: quickly rank setups by disagreement rate.
CREATE INDEX IF NOT EXISTS idx_community_sessions_algo_version
    ON public.community_sessions (algorithm_version)
    WHERE algorithm_version IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_community_sessions_feedback
    ON public.community_sessions (user_disagreed, user_agreed, user_partly_agreed)
    WHERE (user_agreed + user_disagreed + user_partly_agreed) > 0;

COMMENT ON COLUMN public.community_sessions.user_agreed
    IS 'Count of frames with explicit user "agree" feedback on quality tier (v5.22.0+).';
COMMENT ON COLUMN public.community_sessions.user_disagreed
    IS 'Count of frames with explicit user "disagree" feedback on quality tier (v5.22.0+).';
COMMENT ON COLUMN public.community_sessions.user_partly_agreed
    IS 'Count of frames with explicit user "partly agree" feedback on quality tier (v5.22.0+).';
COMMENT ON COLUMN public.community_sessions.algorithm_version
    IS 'kAlgorithmVersion used to score the frames (see ALGORITHM_CHANGELOG.md).';

COMMIT;
