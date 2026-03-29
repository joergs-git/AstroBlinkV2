-- Bortle grid lookup table — pre-populated from Falchi 2016 World Atlas GeoTIFF.
-- Only stores cells with Bortle > 1 (light-polluted areas).
-- Ocean/pristine areas default to Bortle 1 (handled by Edge Function).

CREATE TABLE IF NOT EXISTS public.bortle_grid (
    lat REAL NOT NULL,              -- Latitude rounded to 0.01°
    lon REAL NOT NULL,              -- Longitude rounded to 0.01°
    bortle REAL NOT NULL,           -- Fractional Bortle class (e.g. 5.2)
    radiance REAL NOT NULL,         -- Artificial sky brightness in mcd/m²

    PRIMARY KEY (lat, lon)
);

-- Fast lookup by coordinates
CREATE INDEX IF NOT EXISTS idx_bortle_grid_coords
    ON public.bortle_grid (lat, lon);

-- RLS: anon can SELECT only (read-only for the app)
ALTER TABLE public.bortle_grid ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon_select_bortle" ON public.bortle_grid
    FOR SELECT TO anon USING (true);
