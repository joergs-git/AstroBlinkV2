// VLM Check — Supabase Edge Function proxy for visual anomaly detection.
// Routes mosaic images to Claude Vision (Opus + extended thinking).
//
// v2 (security audit 2026-10, finding B4): this is the most expensive endpoint of
// the project (~0.90 USD per call) and had the same weaknesses as ask-aisaac — a
// per-isolate in-memory limiter keyed by a free-form header, no payload bounds.
//   • persistent per-device / per-IP / global daily limits + kill switch via
//     ../_shared/limits.ts (api_limits row 'vlm-check': 10 / 30 / 100 per day)
//   • strict x-device-id format
//   • request shape pinned: ≤ 2 messages, ≤ 2 base64 JPEG/PNG images of ≤ 5 MB
//     base64 each (Claude's own per-image limit), text ≤ 50 K chars
//   • Pushover: 80 % budget, global cap, single-IP cap (replaces the old
//     every-10-checks usage summary)
// Response shapes (text/remaining/usage JSON, 413 + 429 bodies, X-Remaining header)
// are unchanged.
//
// Deploy with the CLI so ../_shared is bundled and verify_jwt stays off:
//   supabase functions deploy vlm-check --project-ref <ref> --no-verify-jwt

import {
  alertOnThresholds,
  checkUsage,
  jsonResponse,
  limitResponse,
  readDeviceId,
  readJsonBody,
  validateMessages,
  validateSystem,
  verifyRollingToken,
} from "../_shared/limits.ts";

const FUNCTION_NAME = "vlm-check";
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
const MODEL = "claude-opus-4-20250514"; // Opus for best visual anomaly detection accuracy
const MAX_TOKENS = 16000; // Extended thinking budget + structured JSON output
const THINKING_BUDGET = 10000; // Tokens for systematic tile-by-tile analysis

// Payload bounds. The app sends one user message with: caption, mosaic JPEG
// (≤ 4.8 MB base64), optional caption + deviation-map JPEG (≤ 4.8 MB base64), prompt.
const MAX_BODY_CHARS = 14_000_000;
const MAX_SYSTEM_CHARS = 100_000;
const MESSAGE_LIMITS = {
  maxMessages: 2,
  maxTextChars: 50_000,
  maxImages: 2,
  maxImageBase64Chars: 5_000_000,
};

const CORS_PREFLIGHT_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-device-id, x-aisaac-token, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS_PREFLIGHT_HEADERS });
  }
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }
  if (!ANTHROPIC_API_KEY) {
    return jsonResponse({ error: "Server misconfigured" }, 500);
  }

  // Same rolling token as ask-aisaac (bot deterrent, ±1 h).
  if (!verifyRollingToken(req.headers.get("x-aisaac-token"))) {
    return jsonResponse({ error: "Unauthorized" }, 403);
  }

  const deviceId = readDeviceId(req.headers.get("x-device-id"));
  if (!deviceId) {
    return jsonResponse({ error: "Invalid or missing x-device-id" }, 400);
  }

  const usage = await checkUsage(FUNCTION_NAME, deviceId, req);
  await alertOnThresholds(FUNCTION_NAME, usage);
  if (!usage.allowed) {
    return limitResponse(usage, "VLM check");
  }
  const remaining = usage.remaining;

  const parsed = await readJsonBody(req, MAX_BODY_CHARS);
  if (!parsed.ok) return parsed.response;
  const { system, messages } = parsed.body;

  const systemError = validateSystem(system, MAX_SYSTEM_CHARS);
  if (systemError) return jsonResponse({ error: systemError }, 400);
  const messagesError = validateMessages(messages, MESSAGE_LIMITS);
  if (messagesError) return jsonResponse({ error: messagesError }, 400);

  try {
    // Non-streaming: the client expects one structured JSON text block.
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
        thinking: { type: "enabled", budget_tokens: THINKING_BUDGET },
        system: (system as string | undefined) ?? "",
        messages,
        stream: false,
      }),
    });

    if (!anthropicResponse.ok) {
      const errorBody = await anthropicResponse.text();
      const status = anthropicResponse.status;
      console.error("Claude Vision API error:", status, errorBody.substring(0, 300));

      if (status === 413 || errorBody.includes("too large")) {
        return jsonResponse({ error: "Mosaic image too large. Try with fewer frames.", remaining }, 413);
      }
      // Include Claude's actual error for debugging
      const detail = errorBody.substring(0, 300);
      return jsonResponse({ error: `Claude ${status}: ${detail}`, remaining }, 502);
    }

    const data = await anthropicResponse.json();
    // With extended thinking, response has both "thinking" and "text" content blocks.
    // Extract only the "text" block (contains the JSON result).
    const textBlock = data.content?.find((b: { type?: string }) => b.type === "text");
    const text = textBlock?.text || "[]";

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
    console.error("VLM Check edge function error:", err);
    return jsonResponse({ error: "Internal server error" }, 500);
  }
});
