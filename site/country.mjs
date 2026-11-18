// Country-language lookup for the language menu. The two requests are kept separate so a failed WebRTC lookup never breaks it.
// TEST:tests/country.test.mjs
import { getIP } from "./vendor/webrtc-ip.mjs";

/** Independent STUN servers improve the chance of a reply on networks where one provider is unreachable. */
export const STUN_SERVERS = ["stun:stun.chat.bilibili.com:3478", "stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"];

/**
 * Guesses a language from the WebRTC address, falling back to Cloudflare's country for the request.
 * @param {{ getAddress?: () => Promise<string>, request?: typeof fetch }} options Replaceable browser services for tests.
 * @returns {Promise<string | null>} The suggested language, or null if neither source has a suggestion.
 */
export async function countryLanguage({ getAddress = () => getIP({ stun: STUN_SERVERS, timeout: 3000 }), request = fetch } = {}) {
  try {
    // A successful lookup is authoritative even when the country has no language in our table.
    const ip = await getAddress();
    const answer = await request("/_geo", {
      method: "POST", credentials: "omit", cache: "no-store",
      headers: { "content-type": "application/json" }, body: JSON.stringify({ ip }),
      signal: AbortSignal.timeout(4000),
    });
    if (answer.ok) return (await answer.json()).language ?? null;
  } catch {
    // WebRTC can be blocked or unsupported, and the external country service can be unavailable.
  }
  try {
    const answer = await request("/_geo", { credentials: "omit", cache: "no-store", signal: AbortSignal.timeout(4000) });
    return answer.ok ? (await answer.json()).language ?? null : null;
  } catch {
    return null;
  }
}
