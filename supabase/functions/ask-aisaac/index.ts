// AIsaac — Supabase Edge Function proxy to Claude API
// Rate-limited by device UUID, never exposes API key to client
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
const PUSHOVER_USER = Deno.env.get("PUSHOVER_USER") || "";
const PUSHOVER_TOKEN = Deno.env.get("PUSHOVER_TOKEN") || "";
const DAILY_LIMIT = 20;
// Model — update when newer versions release
const MODEL = "claude-sonnet-4-6";
const MAX_TOKENS = 1024;

// Track API errors for Pushover alerting
let firstErrorTime: number | null = null;
let pushoverSent = false;

// In-memory rate limiter (resets on cold start — good enough for Stage 1)
const rateLimits = new Map<string, { count: number; resetAt: number }>();

function checkRateLimit(deviceId: string): { allowed: boolean; remaining: number } {
  const now = Date.now();
  let entry = rateLimits.get(deviceId);

  if (!entry || now > entry.resetAt) {
    entry = { count: 0, resetAt: now + 86_400_000 }; // 24h window
  }

  if (entry.count >= DAILY_LIMIT) {
    rateLimits.set(deviceId, entry);
    return { allowed: false, remaining: 0 };
  }

  entry.count++;
  rateLimits.set(deviceId, entry);
  return { allowed: true, remaining: DAILY_LIMIT - entry.count };
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

  // Rate limiting
  const { allowed, remaining } = checkRateLimit(deviceId);
  if (!allowed) {
    return new Response(
      JSON.stringify({
        error: "Daily query limit reached. Try again tomorrow.",
        remaining: 0,
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
