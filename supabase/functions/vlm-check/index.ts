// VLM Check — Supabase Edge Function proxy for visual anomaly detection
// Routes mosaic images to Claude Vision API with separate rate limiting.
// 10 checks/day per device, global daily cap, Pushover usage notifications.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
const PUSHOVER_USER = Deno.env.get("PUSHOVER_USER") || "";
const PUSHOVER_TOKEN = Deno.env.get("PUSHOVER_TOKEN") || "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

// VLM-specific limits (separate from AIsaac text chat)
const DEVICE_DAILY_LIMIT = 10;
const GLOBAL_DAILY_CAP = 500; // Safety cap across all devices
const MODEL = "claude-opus-4-20250514"; // Opus for best visual anomaly detection accuracy
const MAX_TOKENS = 16000; // Extended thinking budget + structured JSON output
const THINKING_BUDGET = 10000; // Tokens for systematic tile-by-tile analysis

// In-memory rate limiter per device (resets on cold start)
const deviceLimits = new Map<string, { count: number; resetAt: number }>();
// Global counter (resets on cold start + daily)
let globalCount = 0;
let globalResetAt = Date.now() + 86_400_000;
// Track daily usage for Pushover reporting
let dailyDevices = new Set<string>();
let lastPushoverSummary = 0;

function checkRateLimit(
  deviceId: string
): { allowed: boolean; remaining: number; reason?: string } {
  const now = Date.now();

  // Reset global counter daily
  if (now > globalResetAt) {
    globalCount = 0;
    globalResetAt = now + 86_400_000;
    dailyDevices = new Set();
    lastPushoverSummary = 0;
  }

  // Check global cap
  if (globalCount >= GLOBAL_DAILY_CAP) {
    return {
      allowed: false,
      remaining: 0,
      reason: "Service temporarily at capacity. Try again tomorrow.",
    };
  }

  // Check per-device limit
  let entry = deviceLimits.get(deviceId);
  if (!entry || now > entry.resetAt) {
    entry = { count: 0, resetAt: now + 86_400_000 };
  }

  if (entry.count >= DEVICE_DAILY_LIMIT) {
    return {
      allowed: false,
      remaining: 0,
      reason: `Daily VLM check limit reached (${DEVICE_DAILY_LIMIT}/day). Try again tomorrow.`,
    };
  }

  entry.count++;
  deviceLimits.set(deviceId, entry);
  globalCount++;
  dailyDevices.add(deviceId);

  return { allowed: true, remaining: DEVICE_DAILY_LIMIT - entry.count };
}

async function sendPushover(title: string, message: string, priority = 0) {
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
        priority,
      }),
    });
  } catch (e) {
    console.error("Pushover send failed:", e);
  }
}

// Send usage summary every 10 checks or when approaching limits
function maybeNotifyUsage() {
  const now = Date.now();
  // Notify every 10 global checks (but max once per hour)
  if (globalCount % 10 === 0 && now - lastPushoverSummary > 3_600_000) {
    lastPushoverSummary = now;
    sendPushover(
      `VLM Check: ${globalCount} today`,
      `${dailyDevices.size} devices, ${globalCount}/${GLOBAL_DAILY_CAP} global cap.\nEstimated cost: ~$${(globalCount * 0.90).toFixed(2)} (Opus + thinking)`
    );
  }
  // Alert if approaching global cap
  if (globalCount === Math.floor(GLOBAL_DAILY_CAP * 0.8)) {
    sendPushover(
      "VLM Check: 80% of daily cap",
      `${globalCount}/${GLOBAL_DAILY_CAP} checks used by ${dailyDevices.size} devices.`,
      1 // high priority
    );
  }
}

serve(async (req) => {
  // CORS
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
      JSON.stringify({ error: "Server misconfigured" }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }

  // Verify rolling token (same as ask-aisaac)
  const token = req.headers.get("x-aisaac-token");
  const now = new Date();
  const dateNum =
    now.getUTCFullYear() * 10000 +
    (now.getUTCMonth() + 1) * 100 +
    now.getUTCDate();
  const expectedToken = String(dateNum - now.getUTCHours());
  const prevHourToken = String(dateNum - ((now.getUTCHours() + 23) % 24));

  if (token !== expectedToken && token !== prevHourToken) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 403,
      headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
    });
  }

  const deviceId = req.headers.get("x-device-id") || "anonymous";

  // Rate limiting
  const { allowed, remaining, reason } = checkRateLimit(deviceId);
  if (!allowed) {
    return new Response(
      JSON.stringify({ error: reason, remaining: 0 }),
      {
        status: 429,
        headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
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

    // Call Claude Vision API (non-streaming for structured JSON output)
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
          thinking: { type: "enabled", budget_tokens: THINKING_BUDGET },
          system: system || "",
          messages,
          stream: false,
        }),
      }
    );

    if (!anthropicResponse.ok) {
      const errorBody = await anthropicResponse.text();
      const status = anthropicResponse.status;
      console.error("Claude Vision API error:", status, errorBody.substring(0, 300));

      if (status === 413 || errorBody.includes("too large")) {
        return new Response(
          JSON.stringify({ error: "Mosaic image too large. Try with fewer frames.", remaining }),
          { status: 413, headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } }
        );
      }

      // Include Claude's actual error for debugging
      const detail = errorBody.substring(0, 300);
      return new Response(
        JSON.stringify({ error: `Claude ${status}: ${detail}`, remaining }),
        { status: 502, headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } }
      );
    }

    const data = await anthropicResponse.json();
    // With extended thinking, response has both "thinking" and "text" content blocks.
    // Extract only the "text" block (contains the JSON result).
    const textBlock = data.content?.find((b: any) => b.type === "text");
    const text = textBlock?.text || "[]";

    // Track usage for notifications
    maybeNotifyUsage();

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
          "X-Remaining": String(remaining),
        },
      }
    );
  } catch (err) {
    console.error("VLM Check edge function error:", err);
    return new Response(
      JSON.stringify({ error: "Internal server error" }),
      { status: 500, headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } }
    );
  }
});
