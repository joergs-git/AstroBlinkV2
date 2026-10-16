// Shared guard rails for the cost-bearing Edge Functions
// (ask-aisaac, vlm-check, weather-forecast). Security audit 2026-10, findings B1/B4.
//
// Why this exists: the previous limiters were per-isolate JavaScript Maps keyed by a
// client-chosen header. Every cold start reset them, every isolate had its own copy,
// and a fresh x-device-id meant a fresh budget. The three functions proxy paid APIs
// (Claude Sonnet, Claude Opus with extended thinking, Meteoblue), so that was an
// open-ended cost exposure.
//
// What this module provides
//   • checkUsage(): ONE round trip to the SECURITY DEFINER RPC `api_usage_check`
//     (migration 20261016_security_audit.sql). Counters live in `api_usage`, limits
//     and the per-function kill switch in `api_limits`. Service role only — anon has
//     no grant on either table nor on the RPC.
//   • readDeviceId(): strict format check. The app sends the 24-hex machine hash (or
//     the literal "unknown" when the hardware UUID is unavailable); anything else is
//     a 400, not an "anonymous" bucket.
//   • The client IP is never stored or logged. It is hashed together with the UTC day
//     and the function name, so rows cannot be linked across days or functions.
//   • In-memory fallback with a SMALL fixed budget if the database is unreachable —
//     the service degrades instead of becoming unlimited.
//   • Pushover alerts, each exactly once per day: 80 % of the global budget, global
//     cap reached, an IP hit its cap (abuse signal).
//   • validateMessages()/validateSystem(): the client builds the Claude payload, so
//     the server pins its SHAPE — roles, message count, text length, image count and
//     size, no tool/document blocks. Model and max_tokens are never client-controlled.
//
// Kill switch (no redeploy):
//   update public.api_limits set enabled = false where function_name = 'ask-aisaac';
// takes effect on the next request. Limits are tuned the same way.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const PUSHOVER_USER = Deno.env.get("PUSHOVER_USER") ?? "";
const PUSHOVER_TOKEN = Deno.env.get("PUSHOVER_TOKEN") ?? "";

/** 24 lowercase hex chars (SHA-256 prefix of the hardware UUID) or the literal fallback. */
export const DEVICE_ID_PATTERN = /^(?:[0-9a-f]{24}|unknown)$/;

/** Budget per device while the database is unreachable (per isolate, per UTC day). */
export const FALLBACK_DEVICE_DAILY = 5;
/** Budget for everybody while the database is unreachable (per isolate, per UTC day). */
export const FALLBACK_GLOBAL_DAILY = 50;

export type LimitReason =
  | "disabled"
  | "unknown_function"
  | "device_limit"
  | "ip_limit"
  | "global_limit"
  | "fallback_limit"
  | null;

export interface UsageResult {
  allowed: boolean;
  reason: LimitReason;
  /** Effective per-device daily limit (entitlement boost already applied). */
  limit: number;
  /** Per-device requests left today. */
  remaining: number;
  ipCount: number;
  ipLimit: number;
  globalCount: number;
  globalLimit: number;
  /** "db" = decided by api_usage_check, "fallback" = database unreachable. */
  source: "db" | "fallback";
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

export const JSON_HEADERS = {
  "Content-Type": "application/json",
  "Access-Control-Allow-Origin": "*",
};

export function jsonResponse(
  body: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...JSON_HEADERS, ...extraHeaders },
  });
}

/** UTC calendar day as YYYY-MM-DD. */
export function utcDay(now: Date = new Date()): string {
  return now.toISOString().slice(0, 10);
}

export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Validate the device id the client sent. Returns the normalised id or null.
 * Old builds never sent anything else than the 24-hex hash or "unknown", so a
 * null here is a malformed or hand-crafted request, never a legitimate client.
 */
export function readDeviceId(raw: string | null | undefined): string | null {
  if (typeof raw !== "string") return null;
  const value = raw.trim().toLowerCase();
  return DEVICE_ID_PATTERN.test(value) ? value : null;
}

/**
 * Rolling token shared by ask-aisaac and vlm-check: YYYYMMDD minus the UTC hour,
 * accepted for the current and the previous hour (clock skew). It is a bot
 * deterrent, not authentication — the real protection is checkUsage().
 */
export function verifyRollingToken(token: string | null, now: Date = new Date()): boolean {
  if (!token) return false;
  const dateNum = now.getUTCFullYear() * 10000 + (now.getUTCMonth() + 1) * 100 + now.getUTCDate();
  const current = String(dateNum - now.getUTCHours());
  const previous = String(dateNum - ((now.getUTCHours() + 23) % 24));
  return token === current || token === previous;
}

/**
 * Pick the client IP from the proxy headers. Cloudflare's `cf-connecting-ip` is
 * authoritative (Cloudflare overwrites a client-supplied value). Failing that, the
 * LAST entry of X-Forwarded-For is the address the nearest trusted proxy saw; the
 * first entries can be written by the client and are never used. Returns the
 * header that was used so the deploy checklist can verify it from the logs
 * without ever logging the address itself.
 */
export function clientIp(headers: Headers): { ip: string; source: string } {
  const cf = headers.get("cf-connecting-ip")?.trim();
  if (cf) return { ip: cf, source: "cf-connecting-ip" };
  const xff = headers.get("x-forwarded-for");
  if (xff) {
    const parts = xff.split(",").map((s) => s.trim()).filter((s) => s.length > 0);
    if (parts.length > 0) return { ip: parts[parts.length - 1], source: "x-forwarded-for" };
  }
  return { ip: "unknown", source: "none" };
}

// ---------------------------------------------------------------------------
// Usage check — database first, small in-memory budget as fallback
// ---------------------------------------------------------------------------

const fallbackDevice = new Map<string, { day: string; count: number }>();
let fallbackGlobal = { day: "", count: 0 };

function fallbackCheck(fn: string, deviceId: string): UsageResult {
  const day = utcDay();
  if (fallbackGlobal.day !== day) fallbackGlobal = { day, count: 0 };
  const key = `${fn}|${deviceId}`;
  let entry = fallbackDevice.get(key);
  if (!entry || entry.day !== day) entry = { day, count: 0 };
  entry.count += 1;
  fallbackDevice.set(key, entry);
  fallbackGlobal.count += 1;

  const allowed = entry.count <= FALLBACK_DEVICE_DAILY && fallbackGlobal.count <= FALLBACK_GLOBAL_DAILY;
  return {
    allowed,
    reason: allowed ? null : "fallback_limit",
    limit: FALLBACK_DEVICE_DAILY,
    remaining: Math.max(FALLBACK_DEVICE_DAILY - entry.count, 0),
    ipCount: 0,
    ipLimit: 0,
    globalCount: fallbackGlobal.count,
    globalLimit: FALLBACK_GLOBAL_DAILY,
    source: "fallback",
  };
}

function toInt(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : 0;
}

/**
 * Decide whether this request may proceed and count it. Never throws.
 * `fn` must match a row in api_limits (seeded by the migration).
 */
export async function checkUsage(fn: string, deviceId: string, req: Request): Promise<UsageResult> {
  const { ip, source } = clientIp(req.headers);
  // Day-salted, per-function hash — the address itself is never persisted.
  const ipHash = ip === "unknown" ? "unknown" : (await sha256Hex(`${fn}|${utcDay()}|${ip}`)).slice(0, 32);

  if (!SUPABASE_URL || !SUPABASE_SERVICE_KEY) {
    console.error(`[limits] ${fn}: SUPABASE_URL / SERVICE_ROLE_KEY missing — fallback limiter`);
    return fallbackCheck(fn, deviceId);
  }

  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/api_usage_check`, {
      method: "POST",
      headers: {
        apikey: SUPABASE_SERVICE_KEY,
        Authorization: `Bearer ${SUPABASE_SERVICE_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ p_function: fn, p_device: deviceId, p_ip: ipHash }),
    });
    if (!res.ok) {
      throw new Error(`api_usage_check ${res.status}: ${(await res.text()).slice(0, 200)}`);
    }
    const r = await res.json() as Record<string, unknown>;
    const result: UsageResult = {
      allowed: r.allowed === true,
      reason: (r.reason ?? null) as LimitReason,
      limit: toInt(r.limit),
      remaining: toInt(r.remaining),
      ipCount: toInt(r.ip_count),
      ipLimit: toInt(r.ip_limit),
      globalCount: toInt(r.global_count),
      globalLimit: toInt(r.global_limit),
      source: "db",
    };
    // Source of the IP header only — never the address. Lets the deploy checklist
    // confirm which proxy header the platform actually sets.
    console.log(`[limits] ${fn} ip-source=${source} allowed=${result.allowed} reason=${result.reason ?? "-"} global=${result.globalCount}/${result.globalLimit}`);
    return result;
  } catch (err) {
    console.error(`[limits] ${fn}: database limiter unavailable — fallback limiter`, err);
    return fallbackCheck(fn, deviceId);
  }
}

// ---------------------------------------------------------------------------
// Pushover alerts — fire exactly once per day each, keyed on the atomic counters
// ---------------------------------------------------------------------------

export async function sendPushover(title: string, message: string, priority = 1): Promise<void> {
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
        sound: priority >= 1 ? "siren" : "pushover",
      }),
    });
  } catch (e) {
    console.error("Pushover send failed:", e);
  }
}

/**
 * The counters are atomic and global, so "count === threshold" is true for exactly
 * one request per day — no in-memory "already sent" flag needed.
 */
export async function alertOnThresholds(fn: string, r: UsageResult): Promise<void> {
  if (r.source !== "db") return;
  if (r.reason === "global_limit" && r.globalCount === r.globalLimit + 1) {
    await sendPushover(
      `🛑 ${fn}: global daily cap reached`,
      `${r.globalLimit} requests today. The function answers 429 until UTC midnight.\n` +
        `Raise: update api_limits set global_daily = … where function_name = '${fn}';`,
    );
    return;
  }
  if (r.reason === "ip_limit" && r.ipCount === r.ipLimit + 1) {
    await sendPushover(
      `⚠️ ${fn}: one network hit its daily cap`,
      `${r.ipLimit} requests from a single IP today — possible abuse or a large shared network.\n` +
        `Kill switch: update api_limits set enabled = false where function_name = '${fn}';`,
    );
    return;
  }
  if (r.allowed && r.globalLimit > 0 && r.globalCount === Math.ceil(r.globalLimit * 0.8)) {
    await sendPushover(
      `📈 ${fn}: 80 % of the daily budget used`,
      `${r.globalCount} of ${r.globalLimit} requests so far today.`,
      0,
    );
  }
}

/** 429 / 503 response for a blocked request; body shape matches what the apps already parse. */
export function limitResponse(r: UsageResult, what = "query"): Response {
  switch (r.reason) {
    case "disabled":
      return jsonResponse(
        { error: "This service is temporarily paused by the maintainer. Please try again later.", remaining: 0, limit: r.limit },
        503,
      );
    case "unknown_function":
      return jsonResponse({ error: "Server misconfigured — no limit profile for this function.", remaining: 0, limit: 0 }, 503);
    case "ip_limit":
      return jsonResponse(
        { error: "Too many requests from this network today. Try again tomorrow.", remaining: r.remaining, limit: r.limit },
        429,
      );
    case "global_limit":
      return jsonResponse(
        { error: "Service temporarily at capacity. Try again tomorrow.", remaining: r.remaining, limit: r.limit },
        429,
      );
    case "fallback_limit":
      return jsonResponse(
        { error: "Service is running in degraded mode. Please try again later.", remaining: 0, limit: r.limit },
        429,
      );
    default:
      return jsonResponse(
        { error: `Daily ${what} limit reached (${r.limit}/day). Try again tomorrow.`, remaining: 0, limit: r.limit },
        429,
      );
  }
}

// ---------------------------------------------------------------------------
// Request body — size cap before parsing
// ---------------------------------------------------------------------------

export type BodyResult =
  | { ok: true; body: Record<string, unknown> }
  | { ok: false; response: Response };

/** Read and parse a JSON body, rejecting oversized or malformed payloads early. */
export async function readJsonBody(req: Request, maxChars: number): Promise<BodyResult> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > maxChars) {
    return { ok: false, response: jsonResponse({ error: "Request body too large." }, 413) };
  }
  let text: string;
  try {
    text = await req.text();
  } catch {
    return { ok: false, response: jsonResponse({ error: "Unreadable request body." }, 400) };
  }
  if (text.length > maxChars) {
    return { ok: false, response: jsonResponse({ error: "Request body too large." }, 413) };
  }
  try {
    const parsed = JSON.parse(text);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      return { ok: false, response: jsonResponse({ error: "Body must be a JSON object." }, 400) };
    }
    return { ok: true, body: parsed as Record<string, unknown> };
  } catch {
    return { ok: false, response: jsonResponse({ error: "Invalid JSON." }, 400) };
  }
}

// ---------------------------------------------------------------------------
// Claude payload shape — pin what the client may send
// ---------------------------------------------------------------------------

export interface MessageLimits {
  maxMessages: number;
  maxTextChars: number;
  maxImages: number;
  maxImageBase64Chars: number;
}

const IMAGE_MEDIA_TYPES = new Set(["image/jpeg", "image/png", "image/webp", "image/gif"]);

/** Returns an error string, or null when the system prompt is acceptable. */
export function validateSystem(system: unknown, maxChars: number): string | null {
  if (system === undefined || system === null) return null;
  if (typeof system !== "string") return "system must be a string";
  if (system.length > maxChars) return `system prompt too long (max ${maxChars} chars)`;
  return null;
}

/**
 * Returns an error string, or null when `messages` is acceptable: 1..maxMessages
 * entries, roles user/assistant only, content either a string or an array of text
 * and base64 image blocks within the given sizes. Anything else (tool_use,
 * document, URL images, unknown keys in a block) is rejected — this proxy serves
 * one chat UI, not the general API.
 */
export function validateMessages(messages: unknown, limits: MessageLimits): string | null {
  if (!Array.isArray(messages) || messages.length === 0) return "messages must be a non-empty array";
  if (messages.length > limits.maxMessages) return `too many messages (max ${limits.maxMessages})`;

  let images = 0;
  for (const [i, m] of messages.entries()) {
    if (m === null || typeof m !== "object" || Array.isArray(m)) return `message ${i} must be an object`;
    const msg = m as Record<string, unknown>;
    if (msg.role !== "user" && msg.role !== "assistant") return `message ${i}: role must be user or assistant`;

    const content = msg.content;
    if (typeof content === "string") {
      if (content.length > limits.maxTextChars) return `message ${i}: text too long (max ${limits.maxTextChars} chars)`;
      continue;
    }
    if (!Array.isArray(content) || content.length === 0) return `message ${i}: content must be a string or a non-empty array`;
    if (content.length > 8) return `message ${i}: too many content blocks`;

    for (const [j, b] of content.entries()) {
      if (b === null || typeof b !== "object" || Array.isArray(b)) return `message ${i} block ${j}: must be an object`;
      const block = b as Record<string, unknown>;
      if (block.type === "text") {
        if (typeof block.text !== "string") return `message ${i} block ${j}: text missing`;
        if (block.text.length > limits.maxTextChars) return `message ${i} block ${j}: text too long (max ${limits.maxTextChars} chars)`;
        continue;
      }
      if (block.type === "image") {
        images += 1;
        if (images > limits.maxImages) return `too many images (max ${limits.maxImages})`;
        const source = block.source;
        if (source === null || typeof source !== "object" || Array.isArray(source)) return `message ${i} block ${j}: image source missing`;
        const src = source as Record<string, unknown>;
        if (src.type !== "base64") return `message ${i} block ${j}: only base64 images are accepted`;
        if (typeof src.media_type !== "string" || !IMAGE_MEDIA_TYPES.has(src.media_type)) return `message ${i} block ${j}: unsupported image media type`;
        if (typeof src.data !== "string" || src.data.length === 0) return `message ${i} block ${j}: image data missing`;
        if (src.data.length > limits.maxImageBase64Chars) return `message ${i} block ${j}: image too large (max ${limits.maxImageBase64Chars} base64 chars)`;
        continue;
      }
      return `message ${i} block ${j}: unsupported block type`;
    }
  }
  return null;
}
