// Weather Forecast — Supabase Edge Function proxy for Meteoblue API
// Provides 1-hourly weather data (cloud layers, visibility, temp, humidity, wind)
// for the Target Catalog Browser's astronomy weather forecast.
// Caches responses by rounded coordinates (0.05° grid ≈ 5km), 2h TTL.
// Rate-limits per device: 50 calls/day, 2000 global daily cap.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { crypto } from "https://deno.land/std@0.168.0/crypto/mod.ts";

const METEOBLUE_API_KEY = Deno.env.get("METEOBLUE_API_KEY") || "";
const METEOBLUE_SECRET = Deno.env.get("METEOBLUE_SECRET") || "";

// Rate limits
const DEVICE_DAILY_LIMIT = 50;
const GLOBAL_DAILY_CAP = 2000;

// In-memory rate limiter (resets on cold start)
const deviceLimits = new Map<string, { count: number; resetAt: number }>();
let globalCount = 0;
let globalResetAt = Date.now() + 86_400_000;

// Response cache: key = rounded lat/lon, value = { data, fetchedAt }
const responseCache = new Map<
  string,
  { data: unknown; fetchedAt: number }
>();
const CACHE_TTL_MS = 2 * 60 * 60 * 1000; // 2 hours
const MAX_CACHE_ENTRIES = 200;

function checkRateLimit(
  deviceId: string
): { allowed: boolean; remaining: number; reason?: string } {
  const now = Date.now();
  if (now > globalResetAt) {
    globalCount = 0;
    globalResetAt = now + 86_400_000;
    deviceLimits.clear();
  }
  if (globalCount >= GLOBAL_DAILY_CAP) {
    return {
      allowed: false,
      remaining: 0,
      reason: "Weather service temporarily at capacity. Try again tomorrow.",
    };
  }
  let entry = deviceLimits.get(deviceId);
  if (!entry || now > entry.resetAt) {
    entry = { count: 0, resetAt: now + 86_400_000 };
  }
  if (entry.count >= DEVICE_DAILY_LIMIT) {
    return {
      allowed: false,
      remaining: 0,
      reason: `Daily weather forecast limit reached (${DEVICE_DAILY_LIMIT}/day). Try again tomorrow.`,
    };
  }
  entry.count++;
  deviceLimits.set(deviceId, entry);
  globalCount++;
  return { allowed: true, remaining: DEVICE_DAILY_LIMIT - entry.count };
}

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

serve(async (req: Request) => {
  // CORS preflight
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
    return new Response(JSON.stringify({ error: "POST required" }), {
      status: 405,
    });
  }

  try {
    const body = await req.json();
    const { lat, lon, deviceId } = body;

    // Validate input
    if (
      typeof lat !== "number" ||
      typeof lon !== "number" ||
      lat < -90 ||
      lat > 90 ||
      lon < -180 ||
      lon > 180
    ) {
      return new Response(
        JSON.stringify({ error: "Invalid coordinates" }),
        { status: 400 }
      );
    }
    if (!deviceId || typeof deviceId !== "string") {
      return new Response(
        JSON.stringify({ error: "deviceId required" }),
        { status: 400 }
      );
    }

    // Rate limiting
    const rateCheck = checkRateLimit(deviceId);
    if (!rateCheck.allowed) {
      return new Response(
        JSON.stringify({
          error: rateCheck.reason,
          remaining: 0,
        }),
        { status: 429 }
      );
    }

    // Check cache (rounded coordinates)
    const rLat = roundCoord(lat);
    const rLon = roundCoord(lon);
    const cacheKey = `${rLat}_${rLon}`;
    const now = Date.now();
    const cached = responseCache.get(cacheKey);
    if (cached && now - cached.fetchedAt < CACHE_TTL_MS) {
      return new Response(
        JSON.stringify({
          ...cached.data as object,
          _cached: true,
          _remaining: rateCheck.remaining,
        }),
        {
          headers: { "Content-Type": "application/json" },
        }
      );
    }

    // Build Meteoblue URL with signature
    const urlPath = `/packages/basic-1h_clouds-1h?apikey=${METEOBLUE_API_KEY}&lat=${lat}&lon=${lon}&asl=0&format=json`;
    const sig = await computeSignature(urlPath);
    const fullUrl = `https://my.meteoblue.com${urlPath}&sig=${sig}`;

    const mbResp = await fetch(fullUrl);
    if (!mbResp.ok) {
      const errText = await mbResp.text();
      console.error("Meteoblue API error:", mbResp.status, errText);
      return new Response(
        JSON.stringify({
          error: "Weather data unavailable",
          detail: mbResp.status,
        }),
        { status: 502 }
      );
    }

    const mbData = await mbResp.json();

    // Check for Meteoblue-level errors
    if (mbData.error) {
      console.error("Meteoblue error:", mbData.error_message);
      return new Response(
        JSON.stringify({ error: mbData.error_message || "Meteoblue error" }),
        { status: 502 }
      );
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

    return new Response(
      JSON.stringify({
        ...mbData,
        _cached: false,
        _remaining: rateCheck.remaining,
      }),
      {
        headers: { "Content-Type": "application/json" },
      }
    );
  } catch (err) {
    console.error("weather-forecast error:", err);
    return new Response(
      JSON.stringify({ error: "Internal error" }),
      { status: 500 }
    );
  }
});
