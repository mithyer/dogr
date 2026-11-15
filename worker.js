// Worker for dogr.dev. It answers exactly one address, /setup.sh (wrangler.jsonc sends only that path here), and passes
// the script that is on the main branch of the dogr repository on GitHub through. Everything else on dogr.dev is a plain
// file from ./site that Cloudflare serves without running this code.

/** Where the script lives. Whatever is on this branch is what the next person runs, exactly as with the GitHub address. */
const SCRIPT_URL = "https://raw.githubusercontent.com/mithyer/dogr/main/setup.sh";

/** How long Cloudflare may keep a copy of the script, in seconds. A new push reaches people within about this time. */
const CACHE_SECONDS = 60;

/** The first line a real script has. Anything else (an HTML error page, say) must never reach `| sh`. */
const SHEBANG = "#!/bin/sh";

/**
 * Builds a plain-text error answer.
 * @param {number} status HTTP status; 4xx and 5xx make `curl -f` stop, so nothing is piped into `sh`.
 * @param {string} message One line telling the person what went wrong.
 * @returns {Response} The answer, never cached.
 */
function failure(status, message) {
  return new Response(`${message}\n`, {
    status,
    headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" },
  });
}

export default {
  /**
   * Answers a request for /setup.sh.
   * @param {Request} request The incoming request.
   * @returns {Promise<Response>} The script as plain text, or an error answer with a status above 399.
   */
  async fetch(request) {
    const { pathname } = new URL(request.url);
    if (pathname !== "/setup.sh") return failure(404, "Not found.");
    if (request.method !== "GET" && request.method !== "HEAD") {
      return failure(405, "Use GET.");
    }

    let upstream;
    try {
      upstream = await fetch(SCRIPT_URL, { cf: { cacheTtl: CACHE_SECONDS, cacheEverything: true } });
    } catch {
      return failure(502, "The script could not be fetched from GitHub. Try again in a minute.");
    }
    if (!upstream.ok) return failure(502, "GitHub did not give out the script. Try again in a minute.");

    // Read the whole script (about 100 KB) so it can be checked before a single byte is sent on.
    const script = await upstream.text();
    if (!script.startsWith(SHEBANG)) return failure(502, "What GitHub returned is not the setup script.");

    return new Response(request.method === "HEAD" ? null : script, {
      headers: {
        "content-type": "text/plain; charset=utf-8",
        "cache-control": `public, max-age=${CACHE_SECONDS}`,
        "x-content-type-options": "nosniff",
      },
    });
  },
};
