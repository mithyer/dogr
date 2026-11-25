// Builds the dogr.dev site: one finished page per language, written to ./dist, which is what Cloudflare serves.
//
//   node build-site.mjs [--out <folder>]
//
// Input (all in ./site): page.html (the template), i18n/strings.csv (ONE table of every text: a row per key, a column per
// language, the same layout as the app's app-ios/Herdogr/l10n/strings.csv; the English column is the reference),
// style.css, page.js, icon.svg, img/ and ios/ (the rules files of the app's update reminder, update-rules-<format>.json, and the data of
// the "What's new" page, whatsnew-<format>.json). Also whatsnew.html (the template of the "What's new" page, which is written once per
// language like the home page) and ../lang.js, the language table that the Worker and the page share.
// The build STOPS (exit status 1) when a language lacks a text that English has, when the template asks for a string that does
// not exist, or when a translation changes the markup or the numbers of the English text; a page that is missing a sentence
// or has a broken link must never reach the site. wrangler.jsonc runs this file before every deploy and dev run.
// TEST:tests/site.test.mjs

import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { LANGUAGES, isCode } from "./lang.js";

/** The public address of the site, used in canonical links, language alternates and the sitemap. */
export const ORIGIN = "https://dogr.dev";

/** The folder this file lives in (the root of the dogr repository). */
const ROOT = dirname(fileURLToPath(import.meta.url));

/** Files and folders of `site/` that are copied to the output unchanged. */
const STATIC_ENTRIES = ["style.css", "page.js", "country.mjs", "whatsnew.js", "whatsnew.mjs", "vendor", "icon.svg", "img", "ios"];
/** The folder of `site/` that holds the rules files of the iPhone app's update reminder (served under /ios/). */
export const UPDATE_RULES_DIR = "ios";
/**
 * The name of the rules file of one format. The format number is part of the address, so a new format is a new file
 * (`update-rules-2.json`) and the apps that only know the old one keep reading the old file, which stays up to date.
 * @param {number} schema The format number.
 * @returns {string} For example `update-rules-1.json`.
 */
export function updateRulesName(schema) {
  return `update-rules-${schema}.json`;
}
/** The levels a rule may name, from the quietest to the loudest. */
const UPDATE_LEVELS = ["green", "orange", "red"];
/** A version as the app compares it: two to four numbers separated by dots (at least two, so a JSON object keeps its order). */
export const UPDATE_VERSION = /^\d+\.\d+(\.\d+){0,2}$/;

/** The plain English pages (site/pages/<name>.html), each written to /<name>/. They have no language menu and no strings table. */
export const PLAIN_PAGES = ["privacy", "support"];

/** The folder of the home page inside a language folder: none, the home page is the language folder itself. */
export const HOME_FOLDER = "";
/**
 * The folder of the "What's new" page inside a language folder: `/<code>/ios/whatsnew/`. The Worker answers `/ios/whatsnew` (and
 * the same with a closing slash) with the page of the right language, the way it does for `/`.
 */
export const WHATSNEW_FOLDER = "ios/whatsnew/";
/** The template of the "What's new" page (in `site/`), written once per language like the home page. */
const WHATSNEW_TEMPLATE = "whatsnew.html";
/** The format number of the "What's new" data file. A new format is a new file, so a page that only knows the old one keeps reading the old file. */
export const WHATSNEW_SCHEMA = 1;
/** The name of the "What's new" data file of a format (in `site/ios/`, served at `/ios/`), for example `whatsnew-1.json`. */
export function whatsNewName(schema = WHATSNEW_SCHEMA) {
  return `whatsnew-${schema}.json`;
}

/**
 * The address a language page is served at, which is also its path in the output folder.
 * @param {string} code Language code.
 * @param {string} [folder] The page inside the language folder: `HOME_FOLDER` (the default) or `WHATSNEW_FOLDER`.
 * @returns {string} For example `/de/` or `/de/ios/whatsnew/`.
 */
export function pathOf(code, folder = HOME_FOLDER) {
  return `/${code}/${folder}`;
}

/**
 * The address search engines should treat as the page of a language. English is the page at the address without a language
 * (`/` and `/ios/whatsnew/`), which the Worker answers with the English page unless the visitor asked for something else, so
 * it is the one to show people.
 * @param {string} code Language code.
 * @param {string} [folder] The page inside the language folder: `HOME_FOLDER` (the default) or `WHATSNEW_FOLDER`.
 * @returns {string} A full address.
 */
export function canonicalOf(code, folder = HOME_FOLDER) {
  return code === "en" ? `${ORIGIN}/${folder}` : `${ORIGIN}${pathOf(code, folder)}`;
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
 * @param {string} folder The page inside the language folder (`HOME_FOLDER` or `WHATSNEW_FOLDER`).
 * @returns {string} One line per language plus `x-default`, which is English at the address without a language.
 */
function alternates(folder) {
  const lines = LANGUAGES.map(({ code, html }) => `<link rel="alternate" hreflang="${html}" href="${canonicalOf(code, folder)}">`);
  lines.push(`<link rel="alternate" hreflang="x-default" href="${ORIGIN}/${folder}">`);
  return lines.join("\n");
}

/**
 * The list items of the language menu as the page ships them: English and the language of the page, nothing else. The
 * languages that are likely for the visitor (the browser's, the one guessed from the country) are added by page.js when the
 * menu is opened. Every link goes to the fixed address of a language, which the Worker never redirects.
 * @param {string} current Code of the page being built; its link is marked as the current one.
 * @param {string} [folder] The page being built (`HOME_FOLDER`, the default, or `WHATSNEW_FOLDER`): each link goes to the same page in another language.
 * @returns {string} The `<li>` lines.
 */
export function languageItems(current, folder = HOME_FOLDER) {
  const shown = LANGUAGES.filter(({ code }) => code === current || code === "en");
  return shown
    .map(({ code, name, html }) => {
      const mark = code === current ? ' aria-current="true"' : "";
      return `        <li><a href="${pathOf(code, folder)}" lang="${html}" hreflang="${html}" data-code="${code}"${mark}>${name}</a></li>`;
    })
    .join("\n");
}

/**
 * Writes the finished page of one language.
 * @param {string} template The template text.
 * @param {Record<string, string>} values The strings of the language.
 * @param {string} code The language code.
 * @param {{ folder?: string, computed?: Record<string, string> }} [options] `folder`: the page being written (`HOME_FOLDER`, the
 *   default, or `WHATSNEW_FOLDER`); `computed`: more `{{$name}}` values for the template (for example `latest`, the newest version).
 * @returns {string} The page as HTML.
 * @throws {Error} When the template asks for a string or a computed value that does not exist.
 */
export function renderPage(template, values, code, { folder = HOME_FOLDER, computed: extra = {} } = {}) {
  const language = LANGUAGES.find((candidate) => candidate.code === code);
  if (!language) throw new Error(`unknown language ${code}`);
  const computed = {
    html: language.html,
    code,
    name: escapeHtml(language.name),
    locale: language.locale,
    // The page being written, and the home page and the "What's new" page of this language (the pages link to each other).
    path: pathOf(code, folder),
    folder,
    home: pathOf(code, HOME_FOLDER),
    whatsnew: pathOf(code, WHATSNEW_FOLDER),
    canonical: canonicalOf(code, folder),
    alternates: alternates(folder),
    languages: languageItems(code, folder),
    // Apple's own "Download on the App Store" badge in this language (site/img/appstore/<code>.svg, unchanged files).
    badge: `/img/appstore/${code}.svg`,
    ...extra,
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
 * Compares two versions made of numbers (`0.10` is newer than `0.9`; a missing number counts as 0, so `0.2` equals `0.2.0`).
 * @param {string} a A version that passed `UPDATE_VERSION`.
 * @param {string} b Another one.
 * @returns {number} Negative when `a` is older, 0 when they are the same, positive when `a` is newer.
 */
export function compareVersions(a, b) {
  const left = a.split(".").map(Number);
  const right = b.split(".").map(Number);
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    const difference = (left[i] ?? 0) - (right[i] ?? 0);
    if (difference !== 0) return difference;
  }
  return 0;
}
/**
 * Checks the text of one update rules file. The app ignores what it does not understand, so a typo would silently turn a red
 * reminder into nothing; the build refuses it instead.
 * Shape: `{ "schema": <n>, "releases": { "<version>": "<level>" }, "appBelow": [ { "version": "<version>", "level": "<level>" } ] }`.
 * @param {string} text The file's text.
 * @param {number} [schema] The format number the file's name promises; `"schema"` inside the file must say the same.
 * @returns {string[]} What is wrong with it; empty when it is fine.
 */
export function checkUpdateRules(text, schema = 1) {
  const file = `${UPDATE_RULES_DIR}/${updateRulesName(schema)}`;
  let rules;
  try {
    rules = JSON.parse(text);
  } catch (error) {
    return [`${file}: not valid JSON (${error.message})`];
  }
  const problems = [];
  const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
  if (!isObject(rules)) return [`${file}: must be a JSON object`];
  if (rules.schema !== schema) problems.push(`${file}: "schema" must be ${schema}, the number in the file name`);
  if (!isObject(rules.releases)) {
    problems.push(`${file}: "releases" must be an object`);
  } else {
    let previous = null;
    for (const [version, level] of Object.entries(rules.releases)) {
      if (!UPDATE_VERSION.test(version)) problems.push(`${file}: releases: "${version}" is not a version like 0.3 or 1.2.1`);
      else if (previous !== null && compareVersions(previous, version) >= 0) problems.push(`${file}: releases: "${version}" must come after "${previous}"`);
      if (!UPDATE_LEVELS.includes(level)) problems.push(`${file}: releases: "${version}" has the level ${JSON.stringify(level)}, expected green, orange or red`);
      if (UPDATE_VERSION.test(version)) previous = version;
    }
  }
  if (!Array.isArray(rules.appBelow)) {
    problems.push(`${file}: "appBelow" must be a list`);
  } else {
    let previous = null;
    for (const [index, entry] of rules.appBelow.entries()) {
      if (!isObject(entry) || !UPDATE_VERSION.test(entry.version ?? "")) {
        problems.push(`${file}: appBelow[${index}] needs a "version" like 0.3`);
        continue;
      }
      if (!UPDATE_LEVELS.includes(entry.level)) problems.push(`${file}: appBelow[${index}] has the level ${JSON.stringify(entry.level)}, expected green, orange or red`);
      if (previous !== null && compareVersions(previous, entry.version) >= 0) problems.push(`${file}: appBelow[${index}] must come after "${previous}"`);
      previous = entry.version;
    }
  }
  return problems;
}
/**
 * Checks every file in the rules folder: each one must be named `update-rules-<n>.json` and be good, and format 1 (the one the
 * first app reads) must exist. A file with any other name is refused, because a typo in a name would hide a rule from the app.
 * The data files of the "What's new" page (`whatsnew-<n>.json`) share the folder and are checked by `checkWhatsNewFolder`.
 * @param {string} sourceDir The `site` folder.
 * @returns {string[]} What is wrong; empty when all is fine.
 */
export function checkUpdateRulesFolder(sourceDir) {
  const folder = join(sourceDir, UPDATE_RULES_DIR);
  const names = existsSync(folder) ? readdirSync(folder) : [];
  const problems = [];
  if (!names.includes(updateRulesName(1))) problems.push(`${UPDATE_RULES_DIR}/${updateRulesName(1)}: missing`);
  for (const name of names.sort()) {
    if (WHATSNEW_FILE_NAME.test(name)) continue;
    const schema = /^update-rules-([1-9]\d*)\.json$/.exec(name)?.[1];
    if (schema === undefined) problems.push(`${UPDATE_RULES_DIR}/${name}: not a rules file (they are named update-rules-<number>.json)`);
    else problems.push(...checkUpdateRules(readFileSync(join(folder, name), "utf8"), Number(schema)));
  }
  return problems;
}
/** The length limit of one version's notes in one language: the App Store's own limit for "What's New". */
const WHATSNEW_MAX_LENGTH = 4000;
/** A data file of the "What's new" page, by name. */
const WHATSNEW_FILE_NAME = /^whatsnew-[1-9]\d*\.json$/;

/**
 * Checks the text of a "What's new" data file. The page builds itself from this file, so a mistake would show up as a page that
 * is empty or in the wrong order; the build refuses it instead.
 * Shape: `{ "schema": 1, "versions": [ { "version": "0.4", "notes": { "en": "...", "de": "..." } } ] }`, the newest version first.
 * `notes` is the text the App Store shows as "What's New" in each language, keyed by the language codes of this site; English is required.
 * @param {string} text The file's text.
 * @param {number} [schema] The format number the file's name promises; `"schema"` inside the file must say the same.
 * @returns {string[]} What is wrong with it; empty when it is fine.
 */
export function checkWhatsNew(text, schema = WHATSNEW_SCHEMA) {
  const file = `${UPDATE_RULES_DIR}/${whatsNewName(schema)}`;
  let data;
  try {
    data = JSON.parse(text);
  } catch (error) {
    return [`${file}: not valid JSON (${error.message})`];
  }
  const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
  if (!isObject(data)) return [`${file}: must be a JSON object`];
  const problems = [];
  if (data.schema !== schema) problems.push(`${file}: "schema" must be ${schema}, the number in the file name`);
  if (!Array.isArray(data.versions) || data.versions.length === 0) {
    problems.push(`${file}: "versions" must be a list with at least one version`);
    return problems;
  }
  let previous = null;
  for (const [index, entry] of data.versions.entries()) {
    const where = `${file}: versions[${index}]`;
    if (!isObject(entry) || !UPDATE_VERSION.test(entry.version ?? "")) {
      problems.push(`${where} needs a "version" like 0.3`);
      continue;
    }
    // The newest comes first, and a version appears once: the page shows the list as it is.
    if (previous !== null && compareVersions(previous, entry.version) <= 0) problems.push(`${where}: "${entry.version}" must come before "${previous}" (newest first)`);
    previous = entry.version;
    if (!isObject(entry.notes)) {
      problems.push(`${where}: "notes" must be an object with one text per language`);
      continue;
    }
    if (!("en" in entry.notes)) problems.push(`${where}: "notes" needs an English text (it is what the other languages fall back to)`);
    for (const [code, note] of Object.entries(entry.notes)) {
      if (!isCode(code)) problems.push(`${where}: "${code}" is not a language code of this site`);
      else if (typeof note !== "string" || note.trim() === "") problems.push(`${where}: the ${code} text must be a non-empty string`);
      else if (note.length > WHATSNEW_MAX_LENGTH) problems.push(`${where}: the ${code} text is longer than ${WHATSNEW_MAX_LENGTH} characters`);
    }
  }
  return problems;
}

/**
 * Checks the "What's new" files of the `ios` folder: format 1 must exist, and every `whatsnew-<n>.json` must be good.
 * @param {string} sourceDir The `site` folder.
 * @returns {string[]} What is wrong; empty when all is fine.
 */
export function checkWhatsNewFolder(sourceDir) {
  const folder = join(sourceDir, UPDATE_RULES_DIR);
  const names = existsSync(folder) ? readdirSync(folder).filter((name) => WHATSNEW_FILE_NAME.test(name)).sort() : [];
  if (!names.includes(whatsNewName())) return [`${UPDATE_RULES_DIR}/${whatsNewName()}: missing`];
  return names.flatMap((name) => checkWhatsNew(readFileSync(join(folder, name), "utf8"), Number(/^whatsnew-(\d+)\.json$/.exec(name)[1])));
}

/**
 * The newest version in the "What's new" data file the page is built from (the home page shows it in the top bar).
 * @param {string} sourceDir The `site` folder; its file must have passed `checkWhatsNewFolder`.
 * @returns {string} A version such as `0.4`.
 */
export function latestWhatsNew(sourceDir) {
  return JSON.parse(readFileSync(join(sourceDir, UPDATE_RULES_DIR, whatsNewName()), "utf8")).versions[0].version;
}

/**
 * The sitemap: every language page of the home page and of the "What's new" page, each listing all its alternates.
 * @returns {string} The XML text.
 */
export function sitemap() {
  const urls = [];
  for (const folder of [HOME_FOLDER, WHATSNEW_FOLDER]) {
    const links = LANGUAGES.map(({ code, html }) => `    <xhtml:link rel="alternate" hreflang="${html}" href="${canonicalOf(code, folder)}"/>`);
    links.push(`    <xhtml:link rel="alternate" hreflang="x-default" href="${ORIGIN}/${folder}"/>`);
    for (const { code } of LANGUAGES) urls.push(`  <url>\n    <loc>${canonicalOf(code, folder)}</loc>\n${links.join("\n")}\n  </url>`);
  }
  for (const name of PLAIN_PAGES) urls.push(`  <url>\n    <loc>${ORIGIN}/${name}/</loc>\n  </url>`);
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
  const whatsNewTemplate = readFileSync(join(sourceDir, WHATSNEW_TEMPLATE), "utf8");
  const { strings, problems } = loadStrings(join(sourceDir, "i18n", "strings.csv"));
  // One table serves both templates, so a text must be used by one of them (and every text a template asks for must exist).
  problems.push(...checkStrings(strings, `${template}\n${whatsNewTemplate}`));
  problems.push(...checkUpdateRulesFolder(sourceDir));
  problems.push(...checkWhatsNewFolder(sourceDir));
  if (problems.length > 0) return { pages: [], problems };
  // The newest version in the "What's new" data is the one the home page shows in its top bar.
  const latest = latestWhatsNew(sourceDir);

  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });
  const pages = [];
  for (const { code } of LANGUAGES) {
    mkdirSync(join(outDir, code), { recursive: true });
    writeFileSync(join(outDir, code, "index.html"), renderPage(template, strings[code], code, { computed: { latest } }));
    mkdirSync(join(outDir, code, WHATSNEW_FOLDER), { recursive: true });
    writeFileSync(join(outDir, code, WHATSNEW_FOLDER, "index.html"), renderPage(whatsNewTemplate, strings[code], code, { folder: WHATSNEW_FOLDER }));
    pages.push(code);
  }
  for (const name of PLAIN_PAGES) {
    mkdirSync(join(outDir, name), { recursive: true });
    cpSync(join(sourceDir, "pages", `${name}.html`), join(outDir, name, "index.html"));
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
