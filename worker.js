// Worker for dogr.dev. wrangler.jsonc sends exactly four addresses here; everything else on dogr.dev is a plain file from
// ./dist (built from ./site by build-site.mjs) that Cloudflare serves without running this code.
//   /setup.sh  passes through the script that is on the main branch of the dogr repository on GitHub.
//   /get       sends people to the app in the App Store. The download buttons and the QR code of the home page point here, so the
//              place they lead to can change without touching the page or the printed code.
//   /          the home page: picks a language (what the visitor picked, else the browser's, else English) and answers with it.
//   /_geo      tells the page which language people in the visitor's country usually read, for the "Suggested" part of its menu.
// TEST:tests/site.test.mjs

import { languageForCountry, pickLanguage } from "./lang.js";

/** Where the script lives. Whatever is on this branch is what the next person runs, exactly as with the GitHub address. */
const SCRIPT_URL = "https://raw.githubusercontent.com/mithyer/dogr/main/setup.sh";

/** How long Cloudflare may keep a copy of the script, in seconds. A new push reaches people within about this time. */
const CACHE_SECONDS = 60;

/**
 * Where /get leads: the app's page in the App Store (the address works in every country, the store picks the storefront).
 * The number is the app record of `dev.dogr.app` in App Store Connect. It answers "not found" until the app is released.
 */
export const APP_STORE_URL = "https://apps.apple.com/app/id6835292499";
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

/**
 * Answers a request for /setup.sh.
 * @param {Request} request The incoming request.
 * @returns {Promise<Response>} The script as plain text, or an error answer with a status above 399.
 */
async function setupScript(request) {
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
}

/**
 * Answers a request for /get with a temporary redirect to the App Store page of the app.
 * It is temporary (302) and never kept, because the target is expected to change (a test build, another store page).
 * @param {Request} request The incoming request.
 * @returns {Response} The redirect, or a plain 405 for anything but GET and HEAD.
 */
function getApp(request) {
  if (request.method !== "GET" && request.method !== "HEAD") return failure(405, "Use GET.");
  return new Response(null, { status: 302, headers: { location: APP_STORE_URL, "cache-control": "private, no-store" } });
}
/**
 * Answers a request for "/": the home page in the language that suits the visitor.
 * English is sent as the page itself (status 200), not as a redirect, because link-preview fetchers and crawlers send no
 * language and may not follow a redirect. Any other language is a temporary redirect (302) to its own address, which the
 * browser does not remember, so a visitor who later changes language is not stuck. The answer depends on two request
 * headers, so it says so (`Vary`) and is never kept by shared caches.
 * @param {Request} request The incoming request.
 * @param {{ ASSETS: { fetch: (request: Request) => Promise<Response> } }} env The Worker bindings; ASSETS serves the built files.
 * @returns {Promise<Response>} The English page, a redirect to another language, or a plain 405.
 */
async function homePage(request, env) {
  if (request.method !== "GET" && request.method !== "HEAD") return failure(405, "Use GET.");
  const url = new URL(request.url);
  const code = pickLanguage({
    cookie: request.headers.get("cookie"),
    accept: request.headers.get("accept-language"),
  });

  if (code !== "en") {
    return new Response(null, {
      status: 302,
      headers: { location: `/${code}/${url.search}`, vary: "Accept-Language, Cookie", "cache-control": "private, no-store" },
    });
  }
  const page = await env.ASSETS.fetch(new Request(new URL("/en/", url), { method: request.method, headers: request.headers }));
  const answer = new Response(page.body, page);
  answer.headers.set("vary", "Accept-Language, Cookie");
  answer.headers.set("cache-control", "private, max-age=0, must-revalidate");
  return answer;
}

/**
 * Answers a request for /_geo with the language that people in the visitor's country usually read.
 * The country itself is never sent back, and the answer is never cached.
 * @param {Request & { cf?: { country?: string } }} request The incoming request; `cf.country` comes from Cloudflare.
 * @returns {Response} JSON `{"language": "<code>"}`, or `{"language": null}` when there is no guess.
 */
function geo(request) {
  return new Response(JSON.stringify({ language: languageForCountry(request.cf?.country) }), {
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "private, no-store" },
  });
}

export default {
  /**
   * Routes the four addresses this Worker answers.
   * @param {Request} request The incoming request.
   * @param {{ ASSETS: { fetch: (request: Request) => Promise<Response> } }} env The Worker bindings.
   * @returns {Promise<Response>} The answer; anything unexpected gets a plain 404.
   */
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (pathname === "/setup.sh") return setupScript(request);
    if (pathname === "/_geo") return geo(request);
    if (pathname === "/get") return getApp(request);
    if (pathname === "/") {
      try {
        return await homePage(request, env);
      } catch {
        // Whatever went wrong, the English page is better than an error.
        return env.ASSETS.fetch(new Request(new URL("/en/", request.url)));
      }
    }
    return failure(404, "Not found.");
  },
};
