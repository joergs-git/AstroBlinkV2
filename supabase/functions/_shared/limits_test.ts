// Unit tests for the pure helpers in limits.ts.
// Run:  deno test --allow-env supabase/functions/_shared/
// (--allow-env because limits.ts reads its secrets at module load, like every
//  Edge Function does. checkUsage / sendPushover talk to the network and are
//  exercised by the post-deploy smoke test in supabase/SECURITY_AUDIT_2026-10.md.)

import { assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import {
  clientIp,
  readDeviceId,
  utcDay,
  validateMessages,
  validateSystem,
  verifyRollingToken,
} from "./limits.ts";

Deno.test("readDeviceId accepts the app's 24-hex hash and the 'unknown' fallback", () => {
  assertEquals(readDeviceId("bd7e7a0f526e8bef8e1529c7"), "bd7e7a0f526e8bef8e1529c7");
  assertEquals(readDeviceId("BD7E7A0F526E8BEF8E1529C7"), "bd7e7a0f526e8bef8e1529c7");
  assertEquals(readDeviceId("unknown"), "unknown");
});

Deno.test("readDeviceId rejects anything a shipped client never sent", () => {
  assertEquals(readDeviceId(null), null);
  assertEquals(readDeviceId(""), null);
  assertEquals(readDeviceId("anonymous"), null);
  assertEquals(readDeviceId("bd7e7a0f526e8bef8e1529c"), null); // 23 chars
  assertEquals(readDeviceId("bd7e7a0f526e8bef8e1529c7a"), null); // 25 chars
  assertEquals(readDeviceId("x&select=*&machine_hash=neq.0"), null); // PostgREST filter smuggling
});

Deno.test("verifyRollingToken accepts current and previous UTC hour only", () => {
  const now = new Date(Date.UTC(2026, 9, 16, 14, 30, 0)); // 2026-10-16 14:30 UTC
  assertEquals(verifyRollingToken(String(20261016 - 14), now), true);
  assertEquals(verifyRollingToken(String(20261016 - 13), now), true); // previous hour
  assertEquals(verifyRollingToken(String(20261016 - 15), now), false); // next hour
  assertEquals(verifyRollingToken(String(20261015 - 14), now), false); // yesterday
  assertEquals(verifyRollingToken(null, now), false);
});

Deno.test("verifyRollingToken wraps at midnight (previous hour of 00:xx is 23)", () => {
  const now = new Date(Date.UTC(2026, 9, 16, 0, 10, 0));
  assertEquals(verifyRollingToken(String(20261016 - 0), now), true);
  assertEquals(verifyRollingToken(String(20261016 - 23), now), true);
});

Deno.test("clientIp prefers cf-connecting-ip, then the LAST x-forwarded-for entry", () => {
  assertEquals(
    clientIp(new Headers({ "cf-connecting-ip": "203.0.113.9", "x-forwarded-for": "10.0.0.1, 198.51.100.2" })),
    { ip: "203.0.113.9", source: "cf-connecting-ip" },
  );
  assertEquals(
    clientIp(new Headers({ "x-forwarded-for": "10.0.0.1, 198.51.100.2" })),
    { ip: "198.51.100.2", source: "x-forwarded-for" },
  );
  assertEquals(clientIp(new Headers()), { ip: "unknown", source: "none" });
});

Deno.test("utcDay is the ISO calendar day", () => {
  assertEquals(utcDay(new Date(Date.UTC(2026, 9, 16, 23, 59, 59))), "2026-10-16");
});

const AISAAC_LIMITS = { maxMessages: 12, maxTextChars: 30_000, maxImages: 2, maxImageBase64Chars: 2_000_000 };

Deno.test("validateMessages accepts the AIsaac payload shape (history + thumbnail)", () => {
  const messages = [
    { role: "user", content: "Why is frame 4A-7566 marked as trash?" },
    { role: "assistant", content: "Because of star trailing …" },
    {
      role: "user",
      content: [
        { type: "image", source: { type: "base64", media_type: "image/jpeg", data: "/9j/4AAQ" } },
        { type: "text", text: "And this one?" },
      ],
    },
  ];
  assertEquals(validateMessages(messages, AISAAC_LIMITS), null);
});

Deno.test("validateMessages accepts the VLM payload shape (two images, captions, prompt)", () => {
  const messages = [{
    role: "user",
    content: [
      { type: "text", text: "IMAGE 1 — ORIGINAL MOSAIC" },
      { type: "image", source: { type: "base64", media_type: "image/jpeg", data: "a".repeat(4_800_000) } },
      { type: "text", text: "IMAGE 2 — DEVIATION MAP" },
      { type: "image", source: { type: "base64", media_type: "image/jpeg", data: "b".repeat(4_800_000) } },
      { type: "text", text: "Analyse …" },
    ],
  }];
  assertEquals(validateMessages(messages, { maxMessages: 2, maxTextChars: 50_000, maxImages: 2, maxImageBase64Chars: 5_000_000 }), null);
});

Deno.test("validateMessages rejects what the proxy must not forward", () => {
  const err = (m: unknown) => validateMessages(m, AISAAC_LIMITS);
  assertNotEquals(err([]), null);
  assertNotEquals(err([{ role: "system", content: "x" }]), null);
  assertNotEquals(err([{ role: "user", content: [{ type: "tool_use", id: "t", name: "bash", input: {} }] }]), null);
  assertNotEquals(err([{ role: "user", content: [{ type: "document", source: { type: "url", url: "https://x" } }] }]), null);
  assertNotEquals(err([{ role: "user", content: [{ type: "image", source: { type: "url", url: "https://x/a.jpg" } }] }]), null);
  assertNotEquals(err([{ role: "user", content: "x".repeat(30_001) }]), null);
  assertNotEquals(err(Array.from({ length: 13 }, () => ({ role: "user", content: "hi" }))), null);
  const threeImages = [{
    role: "user",
    content: [1, 2, 3].map(() => ({ type: "image", source: { type: "base64", media_type: "image/jpeg", data: "x" } })),
  }];
  assertNotEquals(err(threeImages), null);
});

Deno.test("validateSystem caps length and type, allows absence", () => {
  assertEquals(validateSystem(undefined, 10), null);
  assertEquals(validateSystem("short", 10), null);
  assertNotEquals(validateSystem("x".repeat(11), 10), null);
  assertNotEquals(validateSystem(["not", "a", "string"], 10), null);
});
