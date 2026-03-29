// get-bortle — Supabase Edge Function
// Returns Bortle class for a given lat/lon from the bortle_grid table.
// Cached in Supabase — each unique location queried only once from the grid.
// The grid is pre-populated from the Falchi 2016 World Atlas GeoTIFF.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Content-Type": "application/json",
};

serve(async (req: Request) => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const url = new URL(req.url);
    const lat = parseFloat(url.searchParams.get("lat") || "");
    const lon = parseFloat(url.searchParams.get("lon") || "");

    if (isNaN(lat) || isNaN(lon) || lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      return new Response(
        JSON.stringify({ error: "Invalid lat/lon parameters" }),
        { status: 400, headers: corsHeaders }
      );
    }

    // Round to grid resolution (0.01° ≈ 1.1km)
    const gridLat = Math.round(lat * 100) / 100;
    const gridLon = Math.round(lon * 100) / 100;

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

    // Query the bortle_grid table for the nearest grid cell
    const { data, error } = await supabase
      .from("bortle_grid")
      .select("bortle, radiance")
      .eq("lat", gridLat)
      .eq("lon", gridLon)
      .maybeSingle();

    if (error) {
      console.error("DB query error:", error);
      return new Response(
        JSON.stringify({ error: "Database error" }),
        { status: 500, headers: corsHeaders }
      );
    }

    if (data) {
      return new Response(
        JSON.stringify({
          lat: gridLat,
          lon: gridLon,
          bortle: data.bortle,
          radiance_mcd: data.radiance,
        }),
        { headers: corsHeaders }
      );
    }

    // Not in grid — must be pristine (Bortle 1, ocean or remote)
    return new Response(
      JSON.stringify({
        lat: gridLat,
        lon: gridLon,
        bortle: 1.0,
        radiance_mcd: 0.0,
      }),
      { headers: corsHeaders }
    );
  } catch (err) {
    console.error("Edge function error:", err);
    return new Response(
      JSON.stringify({ error: "Internal error" }),
      { status: 500, headers: corsHeaders }
    );
  }
});
