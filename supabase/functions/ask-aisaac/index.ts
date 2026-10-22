// AIsaac — Supabase Edge Function proxy to the Claude API.
// Never exposes the API key to the client.
//
// v2 (security audit 2026-10, finding B1):
//   • persistent per-device / per-IP / global daily limits + kill switch via
//     ../_shared/limits.ts (table api_limits, RPC api_usage_check) — the old
//     in-memory Map reset on every cold start and was keyed by a free-form header
//   • strict x-device-id format (24-hex machine hash) — no more "anonymous" bucket
//   • the aisaac_boost entitlement is resolved inside the RPC; the string-built
//     PostgREST filter that invited parameter injection is gone
//   • request shape pinned: body size, system length, message count/roles, text
//     length, image count/size; tool/document blocks rejected
//   • model and max_tokens stay server-side constants (never client-controlled)
// Response shapes (success JSON, SSE pass-through, 429 body, X-Remaining header)
// are unchanged so every shipped app build keeps working.
//
// Deploy with the CLI so ../_shared is bundled and verify_jwt stays off:
//   supabase functions deploy ask-aisaac --project-ref <ref> --no-verify-jwt

import {
  alertOnThresholds,
  checkUsage,
  jsonResponse,
  limitResponse,
  readDeviceId,
  readJsonBody,
  sendPushover,
  validateMessages,
  validateSystem,
  verifyRollingToken,
} from "../_shared/limits.ts";

const FUNCTION_NAME = "ask-aisaac";
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
// Model — update when newer versions release
const MODEL = "claude-sonnet-4-6";
// 4096 ≈ 3000 words — prevents silent mid-word truncation seen at 1024
// (Sonnet 4.6 supports up to 64K output; 4096 is a safe free-tier budget)
const MAX_TOKENS = 4096;

// Payload bounds. The app sends: knowledge block (~55 KB) + session context +
// per-frame table (≤ 200 rows) + 60 headers + weather as `system`; ≤ 10 history
// messages + 1 user message, the last one optionally with an 800 px JPEG thumbnail
// (≤ ~300 KB base64). Bounds are several times those sizes, and small enough that a
// single request cannot cost more than a few cents.
const MAX_BODY_CHARS = 6_000_000;
const MAX_SYSTEM_CHARS = 500_000;
const MESSAGE_LIMITS = {
  maxMessages: 12,
  maxTextChars: 30_000,
  maxImages: 2,
  maxImageBase64Chars: 2_000_000,
};

const CORS_PREFLIGHT_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-device-id, x-aisaac-token, x-stream, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// ---------------------------------------------------------------------------
// Claude API outage alert (unchanged behaviour): one Pushover after >60 min of errors
// ---------------------------------------------------------------------------
let firstErrorTime: number | null = null;
let outageAlertSent = false;

function trackError(status: number, detail: string) {
  const now = Date.now();
  if (!firstErrorTime) firstErrorTime = now;
  const errorDurationMin = (now - firstErrorTime) / 60000;
  if (errorDurationMin > 60 && !outageAlertSent) {
    outageAlertSent = true;
    sendPushover(
      "🚨 AIsaac API Down >60min",
      `Claude API errors since ${new Date(firstErrorTime).toISOString()}.\nLast error: ${status} — ${detail}`,
    );
  }
}

function clearErrorTracking() {
  firstErrorTime = null;
  outageAlertSent = false;
}

// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS_PREFLIGHT_HEADERS });
  }
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }
  if (!ANTHROPIC_API_KEY) {
    return jsonResponse({ error: "Server misconfigured — missing API key" }, 500);
  }

  // Bot deterrent (rolling token, ±1 h). Authentication proper is the usage check.
  if (!verifyRollingToken(req.headers.get("x-aisaac-token"))) {
    return jsonResponse({ error: "Unauthorized" }, 403);
  }

  const deviceId = readDeviceId(req.headers.get("x-device-id"));
  if (!deviceId) {
    return jsonResponse({ error: "Invalid or missing x-device-id" }, 400);
  }

  // Persistent limits: device (20/day, boosted by entitlement), IP, global, kill switch.
  const usage = await checkUsage(FUNCTION_NAME, deviceId, req);
  await alertOnThresholds(FUNCTION_NAME, usage);
  if (!usage.allowed) {
    return limitResponse(usage, "query");
  }
  const remaining = usage.remaining;

  // Body: size cap → JSON → shape.
  const parsed = await readJsonBody(req, MAX_BODY_CHARS);
  if (!parsed.ok) return parsed.response;
  const { system, messages } = parsed.body;

  const systemError = validateSystem(system, MAX_SYSTEM_CHARS);
  if (systemError) return jsonResponse({ error: systemError }, 400);
  const messagesError = validateMessages(messages, MESSAGE_LIMITS);
  if (messagesError) return jsonResponse({ error: messagesError }, 400);

  try {
    const wantStream = req.headers.get("x-stream") === "true";

    const anthropicResponse = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: MAX_TOKENS,
        system: (system as string | undefined) ?? "",
        messages,
        stream: wantStream,
      }),
    });

    if (!anthropicResponse.ok) {
      const errorBody = await anthropicResponse.text();
      const status = anthropicResponse.status;
      console.error("Claude API error:", status, errorBody);
      trackError(status, errorBody.substring(0, 200));

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
      return jsonResponse({ error: userMessage, remaining }, 502);
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
    const text = data.content?.[0]?.text || "I couldn't generate a response. Try again.";
    return jsonResponse(
      {
        text,
        remaining,
        usage: {
          input: data.usage?.input_tokens || 0,
          output: data.usage?.output_tokens || 0,
        },
      },
      200,
      { "X-Remaining": String(remaining) },
    );
  } catch (err) {
    console.error("Edge function error:", err);
    return jsonResponse({ error: "Internal server error", remaining }, 500);
  }
});
