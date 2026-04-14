-- Curated ground-truth labels for the quality scoring dataset.
-- Populated by the macOS app's Blind Curation mode: every frame the user
-- rates with 1/2/3 (userConfidence > 0) auto-upserts into this table.
-- Used by Claude Code sessions (via MCP) for regression analysis and soft-
-- limit calibration of Stage 1 quality rules.
CREATE TABLE public.curated_frames (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Identity (stable cross-machine)
  file_hash text NOT NULL,
  machine_hash text NOT NULL,
  setup_hash text,

  -- Filename + capture timestamp (denormalized for readable SQL)
  filename text,
  capture_date text,
  capture_time text,
  observing_night text,

  -- Equipment
  telescope text,
  camera text,
  focal_length_mm real,
  pixel_size_microns real,

  -- Capture parameters
  target text,
  canonical_target text,
  filter text,
  exposure_s real,
  gain integer,

  -- Computed metrics (pixel-derived, the ground-truth INPUTS)
  computed_fwhm real,
  computed_hfr real,
  computed_star_count integer,
  computed_eccentricity real,
  noise_median real,
  noise_mad real,
  psf_flux real,
  trailing_score real,
  trailing_axis_ratio real,

  -- Environment (for future stratification)
  moon_illumination real,
  moon_distance real,
  bortle_class real,
  twilight_phase text,

  -- Algorithm verdict AT RATING TIME (so we can measure drift per algo version)
  quality_tier integer,
  combined_z_score real,
  garbage_reasons text,

  -- THE GROUND TRUTH LABEL
  user_confidence integer NOT NULL CHECK (user_confidence BETWEEN 1 AND 3),
  quality_feedback integer,

  -- Meta
  algorithm_version integer NOT NULL,
  app_version text,
  rated_at timestamptz NOT NULL DEFAULT now(),

  -- One rating per (file, machine). Upsert semantics: re-rating overwrites.
  UNIQUE (file_hash, machine_hash)
);

-- Fast filter for per-user per-setup queries (the common analysis path)
CREATE INDEX idx_curated_frames_machine_setup_filter
  ON public.curated_frames (machine_hash, setup_hash, filter);

-- Fast filter for target-type stratification
CREATE INDEX idx_curated_frames_canonical_target
  ON public.curated_frames (canonical_target);

-- Enable RLS and allow anon inserts/reads (same pattern as session_benchmarks)
ALTER TABLE public.curated_frames ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon can insert curated frames"
  ON public.curated_frames
  FOR INSERT
  TO anon
  WITH CHECK (true);

CREATE POLICY "anon can select curated frames"
  ON public.curated_frames
  FOR SELECT
  TO anon
  USING (true);

CREATE POLICY "anon can update curated frames"
  ON public.curated_frames
  FOR UPDATE
  TO anon
  USING (true)
  WITH CHECK (true);

COMMENT ON TABLE public.curated_frames IS
  'Ground-truth quality labels from the Blind Curation mode in the macOS app. One row per rated frame per machine, keyed on (file_hash, machine_hash). user_confidence (1/2/3) is the label; every other column is context for regression analysis.';
