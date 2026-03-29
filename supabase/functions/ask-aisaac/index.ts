// AIsaac — Supabase Edge Function proxy to Claude API
// Rate-limited by device UUID, never exposes API key to client
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
const PUSHOVER_USER = Deno.env.get("PUSHOVER_USER") || "";
const PUSHOVER_TOKEN = Deno.env.get("PUSHOVER_TOKEN") || "";
const DEFAULT_DAILY_LIMIT = 20;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
// Model — update when newer versions release
const MODEL = "claude-sonnet-4-6";
const MAX_TOKENS = 1024;

// Track API errors for Pushover alerting
let firstErrorTime: number | null = null;
let pushoverSent = false;

// In-memory rate limiter (resets on cold start — good enough for Stage 1)
const rateLimits = new Map<string, { count: number; resetAt: number }>();
// In-memory cache for device entitlement limits (1h TTL)
const entitlementCache = new Map<string, { limit: number; expiresAt: number }>();

async function getDeviceLimit(deviceId: string): Promise<number> {
  // Check in-memory cache first
  const cached = entitlementCache.get(deviceId);
  if (cached && Date.now() < cached.expiresAt) return cached.limit;

  // Query Supabase for aisaac_boost entitlement
  if (SUPABASE_URL && SUPABASE_SERVICE_KEY) {
    try {
      const res = await fetch(
        `${SUPABASE_URL}/rest/v1/device_entitlements?machine_hash=eq.${deviceId}&entitlement=eq.aisaac_boost&select=value`,
        {
          headers: {
            apikey: SUPABASE_SERVICE_KEY,
            Authorization: `Bearer ${SUPABASE_SERVICE_KEY}`,
          },
        }
      );
      if (res.ok) {
        const rows = await res.json();
        if (rows.length > 0 && rows[0].value) {
          const limit = parseInt(rows[0].value) || DEFAULT_DAILY_LIMIT;
          entitlementCache.set(deviceId, { limit, expiresAt: Date.now() + 3_600_000 });
          return limit;
        }
      }
    } catch {
      // Fallback to default on error
    }
  }

  entitlementCache.set(deviceId, { limit: DEFAULT_DAILY_LIMIT, expiresAt: Date.now() + 3_600_000 });
  return DEFAULT_DAILY_LIMIT;
}

async function checkRateLimit(deviceId: string): Promise<{ allowed: boolean; remaining: number; limit: number }> {
  const now = Date.now();
  let entry = rateLimits.get(deviceId);
  const limit = await getDeviceLimit(deviceId);

  if (!entry || now > entry.resetAt) {
    entry = { count: 0, resetAt: now + 86_400_000 }; // 24h window
  }

  if (entry.count >= limit) {
    rateLimits.set(deviceId, entry);
    return { allowed: false, remaining: 0, limit };
  }

  entry.count++;
  rateLimits.set(deviceId, entry);
  return { allowed: true, remaining: limit - entry.count, limit };
}

async function sendPushover(title: string, message: string) {
  if (!PUSHOVER_USER || !PUSHOVER_TOKEN) return;
  try {
    await fetch("https://api.pushover.net/1/messages.json", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        token: PUSHOVER_TOKEN,
        user: PUSHOVER_USER,
        title,
        message,
        priority: 1, // high priority
        sound: "siren",
      }),
    });
  } catch (e) {
    console.error("Pushover send failed:", e);
  }
}

function trackError(status: number, detail: string) {
  const now = Date.now();
  if (!firstErrorTime) {
    firstErrorTime = now;
  }
  // If errors persist for >60 minutes, send Pushover alert (once)
  const errorDurationMin = (now - firstErrorTime) / 60000;
  if (errorDurationMin > 60 && !pushoverSent) {
    pushoverSent = true;
    sendPushover(
      "🚨 AIsaac API Down >60min",
      `Claude API errors since ${new Date(firstErrorTime).toISOString()}.\nLast error: ${status} — ${detail}`
    );
  }
}

function clearErrorTracking() {
  firstErrorTime = null;
  pushoverSent = false;
}

serve(async (req) => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers":
          "authorization, x-device-id, x-aisaac-token, content-type, apikey",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
      },
    });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  if (!ANTHROPIC_API_KEY) {
    return new Response(
      JSON.stringify({ error: "Server misconfigured — missing API key" }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }

  // Verify rolling token (YYYYMMDD - currentUTCHour)
  const token = req.headers.get("x-aisaac-token");
  const now = new Date();
  const dateNum =
    now.getUTCFullYear() * 10000 +
    (now.getUTCMonth() + 1) * 100 +
    now.getUTCDate();
  const expectedToken = String(dateNum - now.getUTCHours());
  // Allow ±1 hour tolerance for clock skew
  const prevHourToken = String(dateNum - ((now.getUTCHours() + 23) % 24));

  if (token !== expectedToken && token !== prevHourToken) {
    return new Response(
      JSON.stringify({ error: "Unauthorized" }),
      {
        status: 403,
        headers: {
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*",
        },
      }
    );
  }

  const deviceId = req.headers.get("x-device-id") || "anonymous";

  // Rate limiting (async — checks device_entitlements for custom limits)
  const { allowed, remaining, limit } = await checkRateLimit(deviceId);
  if (!allowed) {
    return new Response(
      JSON.stringify({
        error: "Daily query limit reached. Try again tomorrow.",
        remaining: 0,
        limit,
      }),
      {
        status: 429,
        headers: {
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*",
        },
      }
    );
  }

  try {
    const { system, messages } = await req.json();

    if (!messages || !Array.isArray(messages) || messages.length === 0) {
      return new Response(
        JSON.stringify({ error: "Missing or empty messages array" }),
        { status: 400, headers: { "Content-Type": "application/json" } }
      );
    }

    // Check if client wants streaming
    const wantStream = req.headers.get("x-stream") === "true";

    // Call Claude API
    const anthropicResponse = await fetch(
      "https://api.anthropic.com/v1/messages",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-api-key": ANTHROPIC_API_KEY,
          "anthropic-version": "2023-06-01",
        },
        body: JSON.stringify({
          model: MODEL,
          max_tokens: MAX_TOKENS,
          system: system || "",
          messages: messages,
          stream: wantStream,
        }),
      }
    );

    if (!anthropicResponse.ok) {
      const errorBody = await anthropicResponse.text();
      const status = anthropicResponse.status;
      console.error("Claude API error:", status, errorBody);
      trackError(status, errorBody.substring(0, 200));

      // User-friendly error messages
      let userMessage: string;
      if (status === 401) {
        userMessage = "🔑 API key issue — the service admin needs to check the configuration.";
      } else if (status === 429) {
        userMessage = "⏳ Claude API is rate-limited right now. Please try again in a minute.";
      } else if (status === 500 || status === 503) {
        userMessage = "🔧 Claude API is temporarily unavailable. This usually resolves within minutes.";
      } else if (status === 529) {
        userMessage = "🔧 Claude API is overloaded. Please try again in a moment.";
      } else {
        userMessage = `⚠️ AI service error (${status}). Please try again later.`;
      }

      return new Response(
        JSON.stringify({ error: userMessage, remaining }),
        {
          status: 502,
          headers: {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
          },
        }
      );
    }

    clearErrorTracking();

    // Streaming: pipe Claude's SSE stream through
    if (wantStream && anthropicResponse.body) {
      return new Response(anthropicResponse.body, {
        headers: {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          "Connection": "keep-alive",
          "Access-Control-Allow-Origin": "*",
          "X-Remaining": String(remaining),
        },
      });
    }

    // Non-streaming fallback
    const data = await anthropicResponse.json();
    const text =
      data.content?.[0]?.text || "I couldn't generate a response. Try again.";

    return new Response(
      JSON.stringify({
        text,
        remaining,
        usage: {
          input: data.usage?.input_tokens || 0,
          output: data.usage?.output_tokens || 0,
        },
      }),
      {
        headers: {
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*",
        },
      }
    );
  } catch (err) {
    console.error("Edge function error:", err);
    return new Response(
      JSON.stringify({ error: "Internal server error", remaining }),
      {
        status: 500,
        headers: {
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*",
        },
      }
    );
  }
});
