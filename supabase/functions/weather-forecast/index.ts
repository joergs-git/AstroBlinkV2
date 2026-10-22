// Weather Forecast — Supabase Edge Function proxy for the Meteoblue API.
// Provides 1-hourly weather data (cloud layers, visibility, temp, humidity, wind)
// for the Target Catalog Browser's astronomy weather forecast.
// Caches responses by rounded coordinates (0.05° grid ≈ 5 km), 2 h TTL.
//
// v2 (security audit 2026-10, finding B4): the limiter was an in-memory Map keyed
// by a `deviceId` taken from the request body, and there was no token at all.
// Meteoblue bills per call, so an unlimited caller could exhaust the plan and
// take the feature down for everybody.
//   • persistent per-device / per-IP / global daily limits + kill switch via
//     ../_shared/limits.ts (api_limits row 'weather-forecast': 50 / 200 / 2000)
//   • `deviceId` must be the 24-hex machine hash the app sends (400 otherwise)
//   • body capped at 4 KB
// No rolling token: shipped clients never sent one, adding it would break them.
// Response shape (Meteoblue JSON + _cached + _remaining, 429 body) is unchanged.
//
// Deploy with the CLI so ../_shared is bundled and verify_jwt stays off:
//   supabase functions deploy weather-forecast --project-ref <ref> --no-verify-jwt

import { crypto } from "https://deno.land/std@0.168.0/crypto/mod.ts";
import {
  alertOnThresholds,
  checkUsage,
  jsonResponse,
  limitResponse,
  readDeviceId,
  readJsonBody,
} from "../_shared/limits.ts";

const FUNCTION_NAME = "weather-forecast";
const METEOBLUE_API_KEY = Deno.env.get("METEOBLUE_API_KEY") || "";
const METEOBLUE_SECRET = Deno.env.get("METEOBLUE_SECRET") || "";

const MAX_BODY_CHARS = 4_096;

// Response cache: key = rounded lat/lon, value = { data, fetchedAt }
const responseCache = new Map<string, { data: unknown; fetchedAt: number }>();
const CACHE_TTL_MS = 2 * 60 * 60 * 1000; // 2 hours
const MAX_CACHE_ENTRIES = 200;

// Compute MD5 signature for Meteoblue API authentication
async function computeSignature(urlPath: string): Promise<string> {
  const signInput = `${urlPath}&secret=${METEOBLUE_SECRET}`;
  const encoder = new TextEncoder();
  const data = encoder.encode(signInput);
  const hashBuffer = await crypto.subtle.digest("MD5", data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Round coordinate to 0.05° grid (~5km) for cache keying
function roundCoord(val: number): number {
  return Math.round(val * 20) / 20;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST",
        "Access-Control-Allow-Headers": "Content-Type, Authorization",
      },
    });
  }
  if (req.method !== "POST") {
    return jsonResponse({ error: "POST required" }, 405);
  }

  try {
    const parsed = await readJsonBody(req, MAX_BODY_CHARS);
    if (!parsed.ok) return parsed.response;
    const { lat, lon, deviceId: rawDeviceId } = parsed.body;

    // Validate input
    if (
      typeof lat !== "number" ||
      typeof lon !== "number" ||
      lat < -90 ||
      lat > 90 ||
      lon < -180 ||
      lon > 180
    ) {
      return jsonResponse({ error: "Invalid coordinates" }, 400);
    }
    const deviceId = readDeviceId(typeof rawDeviceId === "string" ? rawDeviceId : null);
    if (!deviceId) {
      return jsonResponse({ error: "deviceId required" }, 400);
    }

    // Persistent limits (device / IP / global, kill switch).
    const usage = await checkUsage(FUNCTION_NAME, deviceId, req);
    await alertOnThresholds(FUNCTION_NAME, usage);
    if (!usage.allowed) {
      return limitResponse(usage, "weather forecast");
    }

    // Check cache (rounded coordinates)
    const rLat = roundCoord(lat);
    const rLon = roundCoord(lon);
    const cacheKey = `${rLat}_${rLon}`;
    const now = Date.now();
    const cached = responseCache.get(cacheKey);
    if (cached && now - cached.fetchedAt < CACHE_TTL_MS) {
      return jsonResponse({
        ...(cached.data as object),
        _cached: true,
        _remaining: usage.remaining,
      });
    }

    // Build Meteoblue URL with signature
    const urlPath = `/packages/basic-1h_clouds-1h?apikey=${METEOBLUE_API_KEY}&lat=${lat}&lon=${lon}&asl=0&format=json`;
    const sig = await computeSignature(urlPath);
    const fullUrl = `https://my.meteoblue.com${urlPath}&sig=${sig}`;

    const mbResp = await fetch(fullUrl);
    if (!mbResp.ok) {
      const errText = await mbResp.text();
      console.error("Meteoblue API error:", mbResp.status, errText);
      return jsonResponse({ error: "Weather data unavailable", detail: mbResp.status }, 502);
    }

    const mbData = await mbResp.json();

    // Check for Meteoblue-level errors
    if (mbData.error) {
      console.error("Meteoblue error:", mbData.error_message);
      return jsonResponse({ error: mbData.error_message || "Meteoblue error" }, 502);
    }

    // Strip unnecessary fields to reduce payload (~30% smaller)
    if (mbData.data_1h) {
      delete mbData.data_1h.rainspot;
      delete mbData.data_1h.pictocode;
      delete mbData.data_1h.uvindex;
      delete mbData.data_1h.snowfraction;
      delete mbData.data_1h.convective_precipitation;
      delete mbData.data_1h.sunshinetime;
    }

    // Cache response (evict oldest if full)
    if (responseCache.size >= MAX_CACHE_ENTRIES) {
      const oldestKey = responseCache.keys().next().value;
      if (oldestKey !== undefined) responseCache.delete(oldestKey);
    }
    responseCache.set(cacheKey, { data: mbData, fetchedAt: now });

    return jsonResponse({
      ...mbData,
      _cached: false,
      _remaining: usage.remaining,
    });
  } catch (err) {
    console.error("weather-forecast error:", err);
    return jsonResponse({ error: "Internal error" }, 500);
  }
});
