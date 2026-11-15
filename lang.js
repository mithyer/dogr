// Languages of the dogr.dev home page, and the rules that choose one. This file is shared on purpose: the Worker
// (worker.js) picks a language for "/", the build script (build-site.mjs) writes one page per language, and the page script
// (site/page.js, loaded by the browser as /lang.js) builds the "suggested" part of the language menu with the same rules.
// It must stay plain JavaScript with no imports, so all three can load it.
// TEST:tests/site.test.mjs

/**
 * One language of the page.
 * @typedef {object} Language
 * @property {string} code Short code used in the address (/de/), in the cookie and in the string file name. Always lower case.
 * @property {string} name The language written in itself, shown in the menu.
 * @property {string} html Value of the `lang` attribute of the page and of `hreflang`.
 * @property {string} locale Value of `og:locale`.
 */

/**
 * The twelve languages of the app, in the order the menu lists them. The same set as app-ios/Herdogr/l10n/strings.csv
 * (`zh` is Simplified, `zh-tw` is Traditional, `pt` is Brazilian Portuguese).
 * @type {Language[]}
 */
export const LANGUAGES = [
  { code: "en", name: "English", html: "en", locale: "en_US" },
  { code: "de", name: "Deutsch", html: "de", locale: "de_DE" },
  { code: "es", name: "Español", html: "es", locale: "es_ES" },
  { code: "ko", name: "한국어", html: "ko", locale: "ko_KR" },
  { code: "ja", name: "日本語", html: "ja", locale: "ja_JP" },
  { code: "zh", name: "简体中文", html: "zh-Hans", locale: "zh_CN" },
  { code: "zh-tw", name: "繁體中文", html: "zh-Hant", locale: "zh_TW" },
  { code: "ru", name: "Русский", html: "ru", locale: "ru_RU" },
  { code: "it", name: "Italiano", html: "it", locale: "it_IT" },
  { code: "fr", name: "Français", html: "fr", locale: "fr_FR" },
  { code: "pt", name: "Português", html: "pt-BR", locale: "pt_BR" },
  { code: "tr", name: "Türkçe", html: "tr", locale: "tr_TR" },
];

/** The language used when nothing else is known, and the one every visitor can always switch to. */
export const FALLBACK = "en";

/** Name of the cookie that remembers a language the visitor picked. It is written only when they pick one. */
export const COOKIE_NAME = "lang";

/**
 * Tells whether a string is the code of one of the languages.
 * @param {unknown} code Anything.
 * @returns {boolean} True for "en", "zh-tw" and the like.
 */
export function isCode(code) {
  return typeof code === "string" && LANGUAGES.some((language) => language.code === code);
}

/**
 * Turns one language tag from a browser (`de-CH`, `zh-Hant-TW`, `pt-PT`) into the code of the closest language we have.
 * Chinese is split by script or region: Traditional for `Hant`, `TW`, `HK` and `MO`, Simplified for the rest.
 * @param {string} tag A language tag as found in Accept-Language or `navigator.languages`.
 * @returns {string | null} A code, or null when the tag is `*`, empty or a language we do not have.
 */
export function matchTag(tag) {
  const parts = String(tag).trim().toLowerCase().replace(/_/g, "-").split("-");
  const primary = parts[0];
  if (primary === "zh") {
    const traditional = parts.slice(1).some((part) => part === "hant" || part === "tw" || part === "hk" || part === "mo");
    return traditional ? "zh-tw" : "zh";
  }
  // `zh-tw` is not a primary tag; every other code is exactly a primary tag.
  return primary !== "" && primary !== "*" && isCode(primary) ? primary : null;
}

/**
 * Reads an Accept-Language header into language tags, best first. Entries with `q=0` ("not acceptable") are dropped, and
 * entries of equal weight keep the order the browser wrote them in.
 * @param {string | null | undefined} header The header value, for example `de-CH,fr;q=0.8,*;q=0.1`.
 * @returns {string[]} The tags without their weights.
 */
export function parseAcceptLanguage(header) {
  if (!header) return [];
  const entries = [];
  header.split(",").forEach((piece, index) => {
    const [tag, ...params] = piece.trim().split(";");
    if (tag === "") return;
    let weight = 1;
    for (const param of params) {
      const match = /^\s*q\s*=\s*([0-9.]+)\s*$/i.exec(param);
      if (match) weight = Number.parseFloat(match[1]);
    }
    if (Number.isFinite(weight) && weight > 0) entries.push({ tag: tag.trim(), weight, index });
  });
  entries.sort((a, b) => b.weight - a.weight || a.index - b.index);
  return entries.map((entry) => entry.tag);
}

/**
 * Finds the first language of an Accept-Language header that we have. English counts: a header that lists English before
 * anything else gives English.
 * @param {string | null | undefined} header The Accept-Language header.
 * @returns {string | null} A code, or null when no listed language is one of ours.
 */
export function languageFromAccept(header) {
  for (const tag of parseAcceptLanguage(header)) {
    const code = matchTag(tag);
    if (code !== null) return code;
  }
  return null;
}

/**
 * Reads the language the visitor picked earlier.
 * @param {string | null | undefined} cookieHeader The Cookie header.
 * @returns {string | null} A code, or null when there is no cookie of ours or its value is not a language we have.
 */
export function languageFromCookie(cookieHeader) {
  if (!cookieHeader) return null;
  for (const piece of cookieHeader.split(";")) {
    const at = piece.indexOf("=");
    if (at < 0) continue;
    if (piece.slice(0, at).trim() !== COOKIE_NAME) continue;
    const value = piece.slice(at + 1).trim();
    if (isCode(value)) return value;
  }
  return null;
}

/**
 * Chooses the language for the address "/": what the visitor picked, else what the browser asks for, else English.
 * @param {{ cookie?: string | null, accept?: string | null }} headers The Cookie and Accept-Language header values.
 * @returns {string} A code, always one of ours.
 */
export function pickLanguage({ cookie, accept }) {
  return languageFromCookie(cookie) ?? languageFromAccept(accept) ?? FALLBACK;
}

/**
 * Countries and the language people there most likely read. Only used for a suggestion in the menu, never to switch
 * the page by itself: a VPN, a trip or a country with several languages makes the guess wrong too often for that.
 * @type {Record<string, string>}
 */
export const COUNTRY_LANGUAGE = {
  CN: "zh",
  TW: "zh-tw", HK: "zh-tw", MO: "zh-tw",
  JP: "ja",
  KR: "ko",
  DE: "de", AT: "de", LI: "de", CH: "de",
  FR: "fr", BE: "fr", LU: "fr", MC: "fr",
  IT: "it", SM: "it", VA: "it",
  ES: "es", MX: "es", AR: "es", CO: "es", CL: "es", PE: "es", VE: "es", EC: "es", GT: "es", CU: "es", BO: "es",
  DO: "es", HN: "es", PY: "es", SV: "es", NI: "es", CR: "es", PA: "es", UY: "es", PR: "es",
  PT: "pt", BR: "pt",
  RU: "ru", BY: "ru", KZ: "ru",
  TR: "tr",
};

/**
 * Looks up the language for a country.
 * @param {string | null | undefined} country Two-letter country code from Cloudflare (`request.cf.country`); `XX` and `T1` mean unknown and Tor.
 * @returns {string | null} A code, or null when we have no guess for that country.
 */
export function languageForCountry(country) {
  if (typeof country !== "string") return null;
  return COUNTRY_LANGUAGE[country.toUpperCase()] ?? null;
}
