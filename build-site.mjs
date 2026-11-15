// Builds the dogr.dev site: one finished page per language, written to ./dist, which is what Cloudflare serves.
//
//   node build-site.mjs [--out <folder>]
//
// Input (all in ./site): page.html (the template), i18n/strings.csv (ONE table of every text: a row per key, a column per
// language, the same layout as the app's app-ios/Herdogr/l10n/strings.csv; the English column is the reference),
// style.css, page.js, icon.svg and img/. Also ../lang.js, the language table that the Worker and the page share.
// The build STOPS (exit status 1) when a language lacks a text that English has, when the template asks for a string that does
// not exist, or when a translation changes the markup or the numbers of the English text; a page that is missing a sentence
// or has a broken link must never reach the site. wrangler.jsonc runs this file before every deploy and dev run.
// TEST:tests/site.test.mjs

import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { LANGUAGES } from "./lang.js";

/** The public address of the site, used in canonical links, language alternates and the sitemap. */
export const ORIGIN = "https://dogr.dev";

/** The folder this file lives in (the root of the dogr repository). */
const ROOT = dirname(fileURLToPath(import.meta.url));

/** Files and folders of `site/` that are copied to the output unchanged. */
const STATIC_ENTRIES = ["style.css", "page.js", "icon.svg", "img"];

/**
 * The address a language page is served at, which is also its path in the output folder.
 * @param {string} code Language code.
 * @returns {string} For example `/de/`.
 */
export function pathOf(code) {
  return `/${code}/`;
}

/**
 * The address search engines should treat as the page of a language. English is the page at the root address, which the
 * Worker answers with the English page unless the visitor asked for something else, so it is the one to show people.
 * @param {string} code Language code.
 * @returns {string} A full address.
 */
export function canonicalOf(code) {
  return code === "en" ? `${ORIGIN}/` : `${ORIGIN}${pathOf(code)}`;
}

/**
 * Splits CSV text (RFC 4180: quoted cells may hold commas, doubled quotes and line breaks) into rows of cells.
 * @param {string} text The whole file.
 * @returns {string[][]} The rows; a blank line between rows is skipped.
 */
export function parseCsv(text) {
  const rows = [];
  let row = [];
  let cell = "";
  let quoted = false;
  let started = false; // true once the current row has any content, so a blank line is not a row
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') {
        cell += '"';
        i++;
      } else if (c === '"') {
        quoted = false;
      } else {
        cell += c;
      }
      continue;
    }
    if (c === '"') {
      quoted = true;
      started = true;
    } else if (c === ",") {
      row.push(cell);
      cell = "";
      started = true;
    } else if (c === "\n" || c === "\r") {
      if (c === "\r" && text[i + 1] === "\n") i++;
      if (started) {
        row.push(cell);
        rows.push(row);
      }
      row = [];
      cell = "";
      started = false;
    } else {
      cell += c;
      started = true;
    }
  }
  if (started) {
    row.push(cell);
    rows.push(row);
  }
  return rows;
}

/**
 * Reads the string table: a header row `key,en,de,...` (the language codes in the order of lang.js, case does not matter, so
 * the app's `zh-TW` is the site's `zh-tw`), then one row per key.
 * @param {string} file The path of `strings.csv`.
 * @returns {{ strings: Record<string, Record<string, string>>, problems: string[] }} The texts by language code, then key, and
 *   what could not be read (a missing file, a wrong header, a repeated key, a row with the wrong number of cells, an empty cell).
 */
export function loadStrings(file) {
  const strings = Object.fromEntries(LANGUAGES.map(({ code }) => [code, {}]));
  const problems = [];
  if (!existsSync(file)) return { strings, problems: [`${file} is missing`] };
  const rows = parseCsv(readFileSync(file, "utf8"));
  const header = (rows.shift() ?? []).map((cell) => cell.trim().toLowerCase());
  const expected = ["key", ...LANGUAGES.map(({ code }) => code)];
  if (header.join(",") !== expected.join(",")) {
    problems.push(`strings.csv: the header must be ${expected.join(",")} (case does not matter), not ${header.join(",")}`);
    return { strings, problems };
  }
  const seen = new Set();
  rows.forEach((row, index) => {
    const line = index + 2; // the header is line 1
    if (row.length !== expected.length) {
      problems.push(`strings.csv row ${line}: ${row.length} cells instead of ${expected.length}`);
      return;
    }
    const key = row[0].trim();
    if (key === "") {
      problems.push(`strings.csv row ${line}: the key is empty`);
      return;
    }
    if (seen.has(key)) problems.push(`strings.csv row ${line}: "${key}" appears twice`);
    seen.add(key);
    LANGUAGES.forEach(({ code }, column) => {
      const value = row[column + 1];
      if (value.trim() === "") problems.push(`${code}: "${key}" is empty`);
      strings[code][key] = value;
    });
  });
  return { strings, problems };
}

/** Matches an HTML comment. The template is full of notes for the author; none of them reaches a finished page. */
const COMMENT = /<!--[\s\S]*?-->/g;

/** Matches a placeholder: `{{key}}` (HTML), `{{@key}}` (plain text, escaped) or `{{$name}}` (computed by the build). */
const PLACEHOLDER = /\{\{([@$]?)([A-Za-z0-9_.-]+)\}\}/g;

/** Matches one HTML tag inside a string value. */
const TAG = /<\/?[a-zA-Z][^>]*>/g;

/**
 * Removes the comments of the template.
 * @param {string} template The template text.
 * @returns {string} The template without comments.
 */
export function stripComments(template) {
  return template.replace(COMMENT, "");
}

/**
 * Lists the strings a template asks for.
 * @param {string} template The template text (comments are ignored).
 * @returns {{ html: Set<string>, text: Set<string>, computed: Set<string> }} Keys used as HTML, keys used as plain text, and computed names.
 */
export function placeholdersOf(template) {
  const found = { html: new Set(), text: new Set(), computed: new Set() };
  for (const [, kind, key] of stripComments(template).matchAll(PLACEHOLDER)) {
    if (kind === "$") found.computed.add(key);
    else if (kind === "@") found.text.add(key);
    else found.html.add(key);
  }
  return found;
}

/**
 * The tags of a value, written out and sorted, so two values can be compared without caring about word order.
 * @param {string} value A string of a language file.
 * @returns {string[]} The tags, for example `['</a>', '<a href="#feedback">']`.
 */
function tagsOf(value) {
  return (value.match(TAG) ?? []).slice().sort();
}

/**
 * The numbers in a value (`17.5`, `800`, `2026`).
 * @param {string} value A string of a language file.
 * @returns {string[]} Every run of digits, with an optional decimal part.
 */
function numbersOf(value) {
  return value.match(/\d+(?:\.\d+)?/g) ?? [];
}

/**
 * Checks every language against the English reference and the template.
 * @param {Record<string, Record<string, string>>} strings The string files by language code (English must be present).
 * @param {string} template The template text.
 * @returns {string[]} One line per problem; empty when everything fits.
 */
export function checkStrings(strings, template) {
  const problems = [];
  const english = strings.en;
  if (!english) return ["en: the English column is missing; it is the reference of all the others"];
  const reference = Object.keys(english);
  const used = placeholdersOf(template);

  // The template and English must agree on the keys, both ways, so no string is dead and none is missing.
  for (const key of [...used.html, ...used.text]) {
    if (!(key in english)) problems.push(`template: asks for "${key}", which the English column does not have`);
  }
  const asked = new Set([...used.html, ...used.text]);
  for (const key of reference) {
    if (!asked.has(key)) problems.push(`en: "${key}" is not used by the template`);
  }
  // A string used as an attribute or plain text must not carry markup, because it would be shown as text.
  for (const key of used.text) {
    if (key in english && /[<>]/.test(english[key])) problems.push(`en: "${key}" is used as plain text but contains markup`);
  }

  for (const [code, values] of Object.entries(strings)) {
    const keys = Object.keys(values);
    for (const key of reference) if (!(key in values)) problems.push(`${code}: missing "${key}"`);
    for (const key of keys) if (!(key in english)) problems.push(`${code}: "${key}" is not in the English column`);
    for (const key of reference) {
      const value = values[key];
      if (typeof value !== "string") continue;
      if (value.includes("{{")) problems.push(`${code}: "${key}" contains a placeholder`);
      const bare = value.replace(TAG, "");
      if (/[<>]/.test(bare)) problems.push(`${code}: "${key}" has a stray < or >`);
      if (/&(?!(?:amp|nbsp|lt|gt|quot|#\d+);)/.test(bare)) problems.push(`${code}: "${key}" has a bare &; write &amp;`);
      if (code === "en") continue;
      if (JSON.stringify(tagsOf(value)) !== JSON.stringify(tagsOf(english[key]))) {
        problems.push(`${code}: "${key}" has different tags than English (links, emphasis and their addresses must stay)`);
      }
      const numbers = numbersOf(value);
      const missing = numbersOf(english[key]).filter((number) => !numbers.includes(number));
      if (missing.length > 0) problems.push(`${code}: "${key}" lost the number ${missing.join(", ")}`);
    }
  }
  return problems;
}

/**
 * Escapes text for an HTML attribute or text node.
 * @param {string} text Plain text.
 * @returns {string} The text with `&`, `<`, `>` and `"` written as entities.
 */
export function escapeHtml(text) {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/**
 * Turns an HTML-capable string into plain text, for places that cannot carry markup (attributes, the title).
 * @param {string} value A string that may contain tags and the entities `&amp;`, `&nbsp;`, `&lt;`, `&gt;`, `&quot;`.
 * @returns {string} The text without tags.
 */
function plainText(value) {
  return value
    .replace(TAG, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, "&");
}

/**
 * The `<link rel="alternate">` lines that tell search engines about the other languages of the page.
 * @returns {string} One line per language plus `x-default`, which is English at the root address.
 */
function alternates() {
  const lines = LANGUAGES.map(({ code, html }) => `<link rel="alternate" hreflang="${html}" href="${canonicalOf(code)}">`);
  lines.push(`<link rel="alternate" hreflang="x-default" href="${ORIGIN}/">`);
  return lines.join("\n");
}

/**
 * The list items of the language menu. Every link goes to the fixed address of a language, which the Worker never redirects.
 * @param {string} current Code of the page being built; its link is marked as the current one.
 * @returns {string} The `<li>` lines.
 */
function languageItems(current) {
  return LANGUAGES.map(({ code, name, html }) => {
    const mark = code === current ? ' aria-current="true"' : "";
    return `        <li><a href="${pathOf(code)}" lang="${html}" hreflang="${html}" data-code="${code}"${mark}>${name}</a></li>`;
  }).join("\n");
}

/**
 * Writes the finished page of one language.
 * @param {string} template The template text.
 * @param {Record<string, string>} values The strings of the language.
 * @param {string} code The language code.
 * @returns {string} The page as HTML.
 * @throws {Error} When the template asks for a string or a computed value that does not exist.
 */
export function renderPage(template, values, code) {
  const language = LANGUAGES.find((candidate) => candidate.code === code);
  if (!language) throw new Error(`unknown language ${code}`);
  const computed = {
    html: language.html,
    code,
    name: escapeHtml(language.name),
    locale: language.locale,
    path: pathOf(code),
    canonical: canonicalOf(code),
    alternates: alternates(),
    languages: languageItems(code),
  };
  return stripComments(template).replace(PLACEHOLDER, (_whole, kind, key) => {
    if (kind === "$") {
      if (!(key in computed)) throw new Error(`the template asks for the computed value "${key}", which does not exist`);
      return computed[key];
    }
    if (!(key in values)) throw new Error(`${code}: missing "${key}"`);
    return kind === "@" ? escapeHtml(plainText(values[key])) : values[key];
  }).replace(/\n(?:[ \t]*\n){2,}/g, "\n\n").replace(/^\s+/, "");
}

/**
 * The sitemap: every language page, each listing all its alternates.
 * @returns {string} The XML text.
 */
export function sitemap() {
  const links = LANGUAGES.map(({ code, html }) => `    <xhtml:link rel="alternate" hreflang="${html}" href="${canonicalOf(code)}"/>`);
  links.push(`    <xhtml:link rel="alternate" hreflang="x-default" href="${ORIGIN}/"/>`);
  const urls = LANGUAGES.map(({ code }) => `  <url>\n    <loc>${canonicalOf(code)}</loc>\n${links.join("\n")}\n  </url>`);
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">',
    ...urls,
    "</urlset>",
    "",
  ].join("\n");
}

/** The robots file: everything may be read, and where the sitemap is. */
export function robots() {
  return `User-agent: *\nAllow: /\n\nSitemap: ${ORIGIN}/sitemap.xml\n`;
}

/**
 * Builds the whole site.
 * @param {{ sourceDir?: string, outDir?: string }} [options] Where the sources are and where to write; both default to this repository.
 * @returns {{ pages: string[], problems: string[] }} The language codes written, and the problems found. When there are
 *   problems nothing is written, so a half-built site can never be deployed.
 */
export function build({ sourceDir = join(ROOT, "site"), outDir = join(ROOT, "dist") } = {}) {
  const template = readFileSync(join(sourceDir, "page.html"), "utf8");
  const { strings, problems } = loadStrings(join(sourceDir, "i18n", "strings.csv"));
  problems.push(...checkStrings(strings, template));
  if (problems.length > 0) return { pages: [], problems };

  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });
  const pages = [];
  for (const { code } of LANGUAGES) {
    mkdirSync(join(outDir, code), { recursive: true });
    writeFileSync(join(outDir, code, "index.html"), renderPage(template, strings[code], code));
    pages.push(code);
  }
  for (const entry of STATIC_ENTRIES) cpSync(join(sourceDir, entry), join(outDir, entry), { recursive: true });
  cpSync(join(ROOT, "lang.js"), join(outDir, "lang.js"));
  writeFileSync(join(outDir, "sitemap.xml"), sitemap());
  writeFileSync(join(outDir, "robots.txt"), robots());
  return { pages, problems: [] };
}

// Run from the command line: `node build-site.mjs [--out folder]`.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const at = process.argv.indexOf("--out");
  const result = build(at > 0 ? { outDir: process.argv[at + 1] } : {});
  if (result.problems.length > 0) {
    console.error(`The site was not built. ${result.problems.length} problem(s):`);
    for (const problem of result.problems) console.error(`  - ${problem}`);
    process.exit(1);
  }
  console.log(`Built ${result.pages.length} pages.`);
}
