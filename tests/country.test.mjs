// Tests the country suggestion without contacting STUN, Cloudflare or the country provider.
// Run with: node --test tests/country.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import { countryLanguage, STUN_SERVERS } from "../site/country.mjs";
import worker from "../worker.js";

/** Creates an uncached JSON answer for the fake browser network. */
const json = (value, status = 200) => new Response(JSON.stringify(value), { status });

// TEST:site/country.mjs[countryLanguage]
test("tries independent STUN providers, including one in mainland China", () => {
  assert.deepEqual(STUN_SERVERS, ["stun:stun.chat.bilibili.com:3478", "stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"]);
});

test("uses the WebRTC country even when it has no suggested language", async () => {
  const calls = [];
  const language = await countryLanguage({
    getAddress: async () => "203.0.113.42",
    request: async (url, options) => { calls.push([url, options]); return json({ language: null }); },
  });
  assert.equal(language, null);
  assert.equal(calls.length, 1);
  assert.equal(calls[0][1].method, "POST");
  assert.deepEqual(JSON.parse(calls[0][1].body), { ip: "203.0.113.42" });
});

test("falls back when WebRTC or the country service fails", async () => {
  for (const fail of ["webrtc", "provider"]) {
    const methods = [];
    const language = await countryLanguage({
      getAddress: async () => { if (fail === "webrtc") throw Error("blocked"); return "203.0.113.42"; },
      request: async (_, options) => { methods.push(options.method || "GET"); return options.method ? json({}, 502) : json({ language: "ja" }); },
    });
    assert.equal(language, "ja");
    assert.deepEqual(methods, fail === "webrtc" ? ["GET"] : ["POST", "GET"]);
  }
});

test("returns null when the fallback is unavailable", async () => {
  assert.equal(await countryLanguage({ getAddress: async () => { throw Error(); }, request: async () => { throw Error(); } }), null);
});

// TEST:worker.js[geo,validAddress]
test("Worker looks up only valid literals and maps the provider country", async () => {
  const oldFetch = globalThis.fetch;
  const urls = [];
  globalThis.fetch = async (url) => { urls.push(url); return json({ success: true, country_code: "JP" }); };
  try {
    for (const ip of ["203.0.113.42", "2001:db8::1"]) {
      const response = await worker.fetch(new Request("https://dogr.dev/_geo", { method: "POST", body: JSON.stringify({ ip }) }), {});
      assert.equal(response.status, 200);
      assert.deepEqual(await response.json(), { language: "ja" });
      assert.equal(response.headers.get("cache-control"), "private, no-store");
    }
    for (const ip of ["example.com", "1.2.3.999", "::1/../../", "not:ipv6", "1.2.3.4?x=y"]) {
      const response = await worker.fetch(new Request("https://dogr.dev/_geo", { method: "POST", body: JSON.stringify({ ip }) }), {});
      assert.equal(response.status, 400, ip);
    }
    assert.equal(urls.length, 2);
  } finally { globalThis.fetch = oldFetch; }
});

test("Worker reports a failed provider instead of silently using the wrong country", async () => {
  const oldFetch = globalThis.fetch;
  globalThis.fetch = async () => json({ success: false });
  try {
    const response = await worker.fetch(new Request("https://dogr.dev/_geo", { method: "POST", body: JSON.stringify({ ip: "203.0.113.42" }) }), {});
    assert.equal(response.status, 502);
  } finally { globalThis.fetch = oldFetch; }
});
