// Tests of the dogr.dev site: the language rules (lang.js), the build (build-site.mjs) and the Worker (worker.js).
// Run from the repository root with:  node --test tests/site.test.mjs
// No network and no Cloudflare: the Worker is called with plain Request objects and a stand-in for the file store.

import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, describe, test } from "node:test";
import { fileURLToPath } from "node:url";

import {
  PLAIN_PAGES,
  UPDATE_RULES_DIR,
  WHATSNEW_FOLDER,
  build,
  canonicalOf,
  checkStrings,
  checkUpdateRules,
  checkUpdateRulesFolder,
  checkWhatsNew,
  checkWhatsNewFolder,
  compareVersions,
  latestWhatsNew,
  loadStrings,
  parseCsv,
  placeholdersOf,
  renderPage,
  sitemap,
  updateRulesName,
} from "../build-site.mjs";
import {
  COUNTRY_LANGUAGE,
  LANGUAGES,
  isCode,
  languageForCountry,
  languageFromAccept,
  languageFromCookie,
  matchTag,
  parseAcceptLanguage,
  pickLanguage,
} from "../lang.js";
import { APP_STORE_URL } from "../app-store.js";
import worker from "../worker.js";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const TEMPLATE = readFileSync(join(ROOT, "site", "page.html"), "utf8");
/** The template of the "What's new" page; it shares the strings table with the home page. */
const WHATSNEW_TEMPLATE = readFileSync(join(ROOT, "site", "whatsnew.html"), "utf8");
const STRINGS_FILE = join(ROOT, "site", "i18n", "strings.csv");

// The five pictures are the current App Store scenes, with descriptions for their actual contents.
// TEST:site.test.mjs[App Store screenshots]
describe("App Store screenshots", () => {
  test("the page references the current scenes and each asset is present", () => {
    for (const [name, alt] of [
      ["iphone-machines-v03.jpg", "hero.alt"],
      ["iphone-workspaces-v03.jpg", "r1.alt"],
      ["iphone-preview-v03.jpg", "r2.alt"],
      ["iphone-conversation-v03.jpg", "r3.alt"],
      ["ipad-panels-v03.jpg", "r5.alt"],
    ]) {
      assert.ok(TEMPLATE.includes(`src="/img/${name}"`), name);
      assert.ok(TEMPLATE.includes(`alt="{{@${alt}}}"`), alt);
      assert.ok(readFileSync(join(ROOT, "site", "img", name)).length > 0, name);
    }
  });
});

describe("language table", () => {
  test("the twelve languages of the app, each code once", () => {
    assert.equal(LANGUAGES.length, 12);
    assert.equal(new Set(LANGUAGES.map((language) => language.code)).size, 12);
    assert.deepEqual(
      LANGUAGES.map((language) => language.code),
      ["en", "de", "es", "ko", "ja", "zh", "zh-tw", "ru", "it", "fr", "pt", "tr"],
    );
  });

  test("isCode accepts our codes and nothing else", () => {
    assert.ok(isCode("zh-tw"));
    assert.ok(!isCode("zh-TW"), "codes are lower case");
    assert.ok(!isCode("xx"));
    assert.ok(!isCode(undefined));
    assert.ok(!isCode(null));
  });
});

describe("matchTag", () => {
  test("plain and regional tags go to the language", () => {
    assert.equal(matchTag("de"), "de");
    assert.equal(matchTag("de-CH"), "de");
    assert.equal(matchTag("EN-us"), "en");
    assert.equal(matchTag("fr_CA"), "fr");
    assert.equal(matchTag("ja-JP"), "ja");
  });

  test("Chinese is split into Simplified and Traditional", () => {
    assert.equal(matchTag("zh"), "zh");
    assert.equal(matchTag("zh-CN"), "zh");
    assert.equal(matchTag("zh-Hans"), "zh");
    assert.equal(matchTag("zh-SG"), "zh");
    assert.equal(matchTag("zh-TW"), "zh-tw");
    assert.equal(matchTag("zh-HK"), "zh-tw");
    assert.equal(matchTag("zh-MO"), "zh-tw");
    assert.equal(matchTag("zh-Hant"), "zh-tw");
    assert.equal(matchTag("zh-Hant-TW"), "zh-tw");
  });

  test("Portuguese of either country is our Brazilian one", () => {
    assert.equal(matchTag("pt"), "pt");
    assert.equal(matchTag("pt-PT"), "pt");
    assert.equal(matchTag("pt-BR"), "pt");
  });

  test("anything we do not have gives null", () => {
    assert.equal(matchTag("*"), null);
    assert.equal(matchTag(""), null);
    assert.equal(matchTag("nl"), null);
    assert.equal(matchTag("sv-SE"), null);
    assert.equal(matchTag("zh-tw-x"), "zh-tw", "a private-use tail does not matter");
  });
});

describe("Accept-Language", () => {
  test("tags come best first, equal weights keep the written order", () => {
    assert.deepEqual(parseAcceptLanguage("de;q=0.5, fr, ja;q=0.9, it"), ["fr", "it", "ja", "de"]);
  });

  test("q=0 means not acceptable", () => {
    assert.deepEqual(parseAcceptLanguage("de;q=0, fr;q=0.0, ja"), ["ja"]);
  });

  test("empty and missing headers give nothing", () => {
    assert.deepEqual(parseAcceptLanguage(""), []);
    assert.deepEqual(parseAcceptLanguage(undefined), []);
    assert.deepEqual(parseAcceptLanguage(null), []);
  });

  test("a bad weight is read as 1 and does not break the rest", () => {
    assert.deepEqual(parseAcceptLanguage("de;q=abc, fr;q=0.8"), ["de", "fr"]);
  });

  test("the first language we have wins; English counts", () => {
    assert.equal(languageFromAccept("de-CH, fr;q=0.8"), "de");
    assert.equal(languageFromAccept("nl, sv;q=0.8, es;q=0.5"), "es");
    assert.equal(languageFromAccept("en-US,en;q=0.9,ja;q=0.8"), "en");
    assert.equal(languageFromAccept("nl, sv"), null);
    assert.equal(languageFromAccept("*"), null);
    assert.equal(languageFromAccept(undefined), null);
  });
});

describe("cookie and the final choice", () => {
  test("the cookie is read among others, and only with a valid language", () => {
    assert.equal(languageFromCookie("a=1; lang=ja; b=2"), "ja");
    assert.equal(languageFromCookie("lang=zh-tw"), "zh-tw");
    assert.equal(languageFromCookie("lang=xx"), null);
    assert.equal(languageFromCookie("lang=ZH"), null);
    assert.equal(languageFromCookie("language=ja"), null);
    assert.equal(languageFromCookie(""), null);
    assert.equal(languageFromCookie(undefined), null);
  });

  test("what the visitor picked beats the browser, the browser beats the default", () => {
    assert.equal(pickLanguage({ cookie: "lang=en", accept: "de" }), "en");
    assert.equal(pickLanguage({ cookie: "lang=ja", accept: "en" }), "ja");
    assert.equal(pickLanguage({ cookie: "lang=bogus", accept: "fr" }), "fr");
    assert.equal(pickLanguage({ cookie: null, accept: "nl" }), "en");
    assert.equal(pickLanguage({}), "en");
  });
});

describe("country guess", () => {
  test("known countries", () => {
    assert.equal(languageForCountry("CN"), "zh");
    assert.equal(languageForCountry("TW"), "zh-tw");
    assert.equal(languageForCountry("HK"), "zh-tw");
    assert.equal(languageForCountry("JP"), "ja");
    assert.equal(languageForCountry("kr"), "ko", "lower case is accepted");
    assert.equal(languageForCountry("DE"), "de");
    assert.equal(languageForCountry("CH"), "de");
    assert.equal(languageForCountry("FR"), "fr");
    assert.equal(languageForCountry("BR"), "pt");
    assert.equal(languageForCountry("MX"), "es");
    assert.equal(languageForCountry("RU"), "ru");
    assert.equal(languageForCountry("TR"), "tr");
  });

  test("no guess for the rest, for Tor and for unknown", () => {
    assert.equal(languageForCountry("US"), null);
    assert.equal(languageForCountry("T1"), null);
    assert.equal(languageForCountry("XX"), null);
    assert.equal(languageForCountry(undefined), null);
    assert.equal(languageForCountry(null), null);
  });

  test("every country in the table points at a language we have", () => {
    for (const [country, code] of Object.entries(COUNTRY_LANGUAGE)) {
      assert.match(country, /^[A-Z]{2}$/);
      assert.ok(isCode(code), `${country} -> ${code}`);
    }
  });
});

describe("string checks", () => {
  const template = "<p>{{a}}</p><img alt=\"{{@b}}\"><p>{{c}}</p>";
  const english = {
    a: "Hello <a href=\"/x\">link</a>",
    b: "Picture",
    c: "Version 17.5 and 12 languages",
  };
  const good = () => ({ en: { ...english }, de: { a: "Hallo <a href=\"/x\">Link</a>", b: "Bild", c: "Version 17.5 und 12 Sprachen" } });

  test("a matching set has no problem", () => {
    assert.deepEqual(checkStrings(good(), template), []);
  });

  test("a missing key, an extra key and a key nobody uses are found", () => {
    const strings = good();
    delete strings.de.b;
    strings.de.extra = "x";
    assert.ok(checkStrings(strings, template).some((line) => line.includes('de: missing "b"')));
    assert.ok(checkStrings(strings, template).some((line) => line.includes('de: "extra" is not in the English column')));
    const unused = { ...good(), en: { ...english, spare: "s" }, de: { ...good().de, spare: "s" } };
    assert.ok(checkStrings(unused, template).some((line) => line.includes('"spare" is not used by the template')));
    assert.ok(checkStrings(good(), template + "{{nope}}").some((line) => line.includes('"nope"')));
  });

  test("changed links, lost numbers, bare ampersands and stray brackets are found", () => {
    let strings = good();
    strings.de.a = "Hallo <a href=\"/y\">Link</a>";
    assert.ok(checkStrings(strings, template).some((line) => line.includes("different tags")));
    strings = good();
    strings.de.a = "Hallo Link";
    assert.ok(checkStrings(strings, template).some((line) => line.includes("different tags")));
    strings = good();
    strings.de.c = "Version 17 und zwölf Sprachen";
    assert.ok(checkStrings(strings, template).some((line) => line.includes("lost the number")));
    strings = good();
    strings.de.b = "Bild & Ton";
    assert.ok(checkStrings(strings, template).some((line) => line.includes("bare &")));
    strings = good();
    strings.de.b = "Bild < Ton";
    assert.ok(checkStrings(strings, template).some((line) => line.includes("stray")));
    strings = good();
    strings.de.b = "{{a}}";
    assert.ok(checkStrings(strings, template).some((line) => line.includes("contains a placeholder")));
  });

  test("tags may be reordered by a translation", () => {
    const strings = { en: { a: "<b>x</b> and <i>y</i>" }, de: { a: "<i>y</i> und <b>x</b>" } };
    assert.deepEqual(checkStrings(strings, "{{a}}"), []);
  });

  test("a string used as plain text must not carry markup", () => {
    const strings = { en: { a: "x <b>y</b>" } };
    assert.ok(checkStrings(strings, "{{@a}}").some((line) => line.includes("plain text but contains markup")));
  });

  test("the placeholders of a template are sorted by kind, and comments are ignored", () => {
    const found = placeholdersOf("<!-- {{ignored}} --> {{a}} {{@b}} {{$c}}");
    assert.deepEqual([...found.html], ["a"]);
    assert.deepEqual([...found.text], ["b"]);
    assert.deepEqual([...found.computed], ["c"]);
  });
});

describe("the string table (CSV)", () => {
  test("quoted cells keep commas, doubled quotes and line breaks; blank lines and CRLF are fine", () => {
    const rows = parseCsv('k,v\r\n"a,b","say ""hi"""\r\n\r\n"two\nlines",x\n');
    assert.deepEqual(rows, [
      ["k", "v"],
      ["a,b", 'say "hi"'],
      ["two\nlines", "x"],
    ]);
  });

  test("the last row needs no line break, and an empty cell stays an empty cell", () => {
    assert.deepEqual(parseCsv("a,,c"), [["a", "", "c"]]);
    assert.deepEqual(parseCsv(""), []);
  });

  /** Writes a table into a scratch folder and loads it. */
  function load(text) {
    const dir = mkdtempSync(join(tmpdir(), "dogr-csv-"));
    try {
      const file = join(dir, "strings.csv");
      writeFileSync(file, text);
      return loadStrings(file);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
  const HEADER = "key," + LANGUAGES.map(({ code }) => code).join(",");
  const row = (key, ...cells) => [key, ...LANGUAGES.map((_, i) => cells[i] ?? `t${i}`)].join(",");

  test("the header may spell zh-TW as the app does, and every language gets its own column", () => {
    const { strings, problems } = load(`${HEADER.replace("zh-tw", "zh-TW")}\n${row("a")}\n`);
    assert.deepEqual(problems, []);
    assert.equal(strings.en.a, "t0");
    assert.equal(strings["zh-tw"].a, "t6");
  });

  test("a wrong header, a short row, an empty cell and a repeated key are all reported", () => {
    assert.ok(load("key,en\na,b\n").problems.some((line) => line.includes("the header must be")));
    assert.ok(load(`${HEADER}\na,only,three\n`).problems.some((line) => line.includes("cells instead of")));
    assert.ok(load(`${HEADER}\n${row("a", "")}\n`).problems.some((line) => line.includes('en: "a" is empty')));
    assert.ok(load(`${HEADER}\n${row("a")}\n${row("a")}\n`).problems.some((line) => line.includes("appears twice")));
  });

  test("a missing file is a problem, not a crash", () => {
    assert.ok(loadStrings(join(tmpdir(), "no-such-dogr-strings.csv")).problems.length > 0);
  });
});

describe("the update rules file of the app", () => {
  const good = JSON.stringify({
    schema: 1,
    releases: { "0.3": "orange", "0.4": "green", "0.5.1": "red" },
    appBelow: [{ version: "0.3", level: "orange" }, { version: "0.10", level: "red" }],
  });
  test("versions are compared as numbers, not as text", () => {
    assert.ok(compareVersions("0.10", "0.9") > 0);
    assert.equal(compareVersions("0.2", "0.2.0"), 0);
    assert.ok(compareVersions("1.0", "0.99.9") > 0);
    assert.ok(compareVersions("0.2.1", "0.3") < 0);
  });
  test("the format number is part of the file name, and the real folder passes", () => {
    assert.equal(updateRulesName(1), "update-rules-1.json");
    assert.equal(updateRulesName(2), "update-rules-2.json");
    assert.deepEqual(checkUpdateRulesFolder(join(ROOT, "site")), []);
    assert.deepEqual(checkUpdateRules(good), []);
  });
  test("every file of the folder is built to /ios/ unchanged, so old apps keep their old format", () => {
    const out = mkdtempSync(join(tmpdir(), "dogr-rules-"));
    try {
      assert.deepEqual(build({ outDir: out }).problems, []);
      const folder = join(ROOT, "site", UPDATE_RULES_DIR);
      assert.ok(readdirSync(folder).includes(updateRulesName(1)));
      for (const name of readdirSync(folder)) {
        assert.equal(readFileSync(join(out, UPDATE_RULES_DIR, name), "utf8"), readFileSync(join(folder, name), "utf8"), name);
      }
    } finally {
      rmSync(out, { recursive: true, force: true });
    }
  });
  test("the folder check wants format 1, refuses odd names, and checks the number inside against the name", () => {
    const site = mkdtempSync(join(tmpdir(), "dogr-rules-site-"));
    try {
      const folder = join(site, UPDATE_RULES_DIR);
      mkdirSync(folder);
      assert.match(checkUpdateRulesFolder(site)[0], /update-rules-1\.json: missing/);
      writeFileSync(join(folder, "update-rules-1.json"), good);
      assert.deepEqual(checkUpdateRulesFolder(site), []);
      // A second format sits beside the first, and is checked on its own number.
      writeFileSync(join(folder, "update-rules-2.json"), good.replace('"schema":1', '"schema":2'));
      assert.deepEqual(checkUpdateRulesFolder(site), []);
      writeFileSync(join(folder, "update-rules-3.json"), good);
      assert.match(checkUpdateRulesFolder(site)[0], /update-rules-3\.json: "schema" must be 3/);
      rmSync(join(folder, "update-rules-3.json"));
      writeFileSync(join(folder, "update-rule-4.json"), good);
      assert.match(checkUpdateRulesFolder(site)[0], /update-rule-4\.json: not a rules file/);
    } finally {
      rmSync(site, { recursive: true, force: true });
    }
  });
  test("a broken file is refused, so a typo cannot turn a red reminder into nothing", () => {
    const edit = (change) => {
      const rules = JSON.parse(good);
      change(rules);
      return checkUpdateRules(JSON.stringify(rules));
    };
    assert.match(checkUpdateRules("{nope")[0], /not valid JSON/);
    assert.match(checkUpdateRules("[]")[0], /must be a JSON object/);
    assert.match(edit((r) => { r.schema = 2; })[0], /"schema" must be 1, the number in the file name/);
    assert.match(edit((r) => { r.releases["0.4"] = "reed"; })[0], /expected green, orange or red/);
    assert.match(edit((r) => { r.releases["3"] = "red"; })[0], /not a version/);
    assert.match(edit((r) => { r.releases["0.3.x"] = "red"; })[0], /not a version/);
    assert.match(edit((r) => { delete r.releases["0.4"]; r.releases["0.2"] = "red"; })[0], /must come after/);
    assert.match(edit((r) => { r.appBelow = {}; })[0], /"appBelow" must be a list/);
    assert.match(edit((r) => { r.appBelow[0].level = "blue"; })[0], /appBelow\[0\] has the level/);
    assert.match(edit((r) => { r.appBelow.reverse(); })[0], /must come after/);
    assert.match(edit((r) => { r.appBelow.push({ level: "red" }); })[0], /needs a "version"/);
    assert.match(edit((r) => { r.releases = []; })[0], /"releases" must be an object/);
  });
});
// The data file the "What's new" page draws itself from. TEST:tests/site.test.mjs[the What's new page]
describe("the What's new data file", () => {
  const good = JSON.stringify({
    schema: 1,
    versions: [
      { version: "0.10", notes: { en: "Ten\n\n• a", de: "Zehn" } },
      { version: "0.9", notes: { en: "Nine" } },
    ],
  });
  /** Checks the good file after one change. */
  const edit = (change) => {
    const data = JSON.parse(good);
    change(data);
    return checkWhatsNew(JSON.stringify(data));
  };

  test("a good file passes, and the real one does too", () => {
    assert.deepEqual(checkWhatsNew(good), []);
    assert.deepEqual(checkWhatsNewFolder(join(ROOT, "site")), []);
  });

  test("the newest version is the first one, compared as numbers", () => {
    assert.equal(latestWhatsNew(join(ROOT, "site")), JSON.parse(readFileSync(join(ROOT, "site", UPDATE_RULES_DIR, "whatsnew-1.json"), "utf8")).versions[0].version);
    // 0.10 comes before 0.9 although it sorts lower as text.
    assert.match(edit((d) => d.versions.reverse())[0], /"0\.10" must come before "0\.9"/);
  });

  test("a broken file is refused, so a typo cannot turn into an empty or wrongly ordered page", () => {
    assert.match(checkWhatsNew("{nope")[0], /not valid JSON/);
    assert.match(checkWhatsNew("[]")[0], /must be a JSON object/);
    assert.match(edit((d) => { d.schema = 2; })[0], /"schema" must be 1/);
    assert.match(edit((d) => { d.versions = []; })[0], /at least one version/);
    assert.match(edit((d) => { d.versions[1].version = "0.10"; })[0], /must come before/);
    assert.match(edit((d) => { d.versions[0].version = "ten"; })[0], /needs a "version"/);
    assert.match(edit((d) => { d.versions[0].notes = []; })[0], /"notes" must be an object/);
    assert.match(edit((d) => { delete d.versions[1].notes.en; d.versions[1].notes.de = "Neun"; })[0], /needs an English text/);
    assert.match(edit((d) => { d.versions[0].notes.xx = "?"; })[0], /"xx" is not a language code/);
    assert.match(edit((d) => { d.versions[0].notes.de = "   "; })[0], /the de text must be a non-empty string/);
    assert.match(edit((d) => { d.versions[0].notes.de = 7; })[0], /the de text must be a non-empty string/);
    assert.match(edit((d) => { d.versions[0].notes.de = "x".repeat(4001); })[0], /longer than 4000/);
  });

  test("the folder check wants format 1 and checks every whatsnew file, and leaves the update rules alone", () => {
    const site = mkdtempSync(join(tmpdir(), "dogr-whatsnew-site-"));
    try {
      const folder = join(site, UPDATE_RULES_DIR);
      mkdirSync(folder);
      assert.match(checkWhatsNewFolder(site)[0], /whatsnew-1\.json: missing/);
      writeFileSync(join(folder, "whatsnew-1.json"), good);
      assert.deepEqual(checkWhatsNewFolder(site), []);
      writeFileSync(join(folder, "whatsnew-2.json"), good);
      assert.match(checkWhatsNewFolder(site)[0], /whatsnew-2\.json: "schema" must be 2/);
      // The rules check does not mistake the data files for typos of a rules file name.
      writeFileSync(join(folder, "update-rules-1.json"), JSON.stringify({ schema: 1, releases: {}, appBelow: [] }));
      assert.deepEqual(checkUpdateRulesFolder(site), []);
    } finally {
      rmSync(site, { recursive: true, force: true });
    }
  });
});

describe("the real site", () => {
  const out = mkdtempSync(join(tmpdir(), "dogr-site-"));
  after(() => rmSync(out, { recursive: true, force: true }));

  test("the string table matches English and the template", () => {
    const { strings, problems } = loadStrings(STRINGS_FILE);
    assert.deepEqual(problems, []);
    // The table serves both templates, so a key is "used" when either of them asks for it.
    assert.deepEqual(checkStrings(strings, `${TEMPLATE}\n${WHATSNEW_TEMPLATE}`), []);
  });

  const result = build({ outDir: out });

  test("it builds without problems and writes one page per language", () => {
    assert.deepEqual(result.problems, []);
    assert.equal(result.pages.length, 12);
    for (const { code } of LANGUAGES) {
      assert.ok(readdirSync(join(out, code)).includes("index.html"), code);
    }
    for (const file of ["style.css", "page.js", "lang.js", "icon.svg", "sitemap.xml", "robots.txt"]) {
      assert.ok(readdirSync(out).includes(file), file);
    }
  });

  test("each page says its own language, is complete, and offers English", () => {
    for (const { code, html, name } of LANGUAGES) {
      const page = readFileSync(join(out, code, "index.html"), "utf8");
      assert.ok(page.includes(`<html lang="${html}">`), code);
      assert.ok(!page.includes("{{"), `${code}: a placeholder is left`);
      assert.ok(!page.includes("<!--"), `${code}: a comment is left`);
      assert.equal((page.match(/rel="alternate" hreflang=/g) ?? []).length, 13, `${code}: 12 languages and x-default`);
      assert.ok(page.includes('hreflang="x-default" href="https://dogr.dev/"'), code);
      const expectedCanonical = code === "en" ? "https://dogr.dev/" : `https://dogr.dev/${code}/`;
      assert.ok(page.includes(`<link rel="canonical" href="${expectedCanonical}">`), `${code}: canonical`);
      // The page ships English and its own language only; page.js adds the browser's and the country's when the menu opens.
      assert.equal((page.match(/data-code="/g) ?? []).length, code === "en" ? 1 : 2, `${code}: the menu lists English and the page's own language only`);
      assert.ok(page.includes('data-code="en"'), `${code}: English is always in the menu`);
      assert.ok(!page.includes('class="suggest"'), `${code}: no separate group of suggestions`);
      assert.equal((page.match(/aria-current="true"/g) ?? []).length, 1, `${code}: exactly one current language`);
      assert.ok(page.includes(`<span>${name}</span>`), `${code}: the button shows the language name`);
      assert.ok(page.includes(`data-current="${code}"`), code);
      assert.ok(page.includes('<a href="/en/" lang="en"'), `${code}: English is always one click away, at its fixed address`);
    }
  });

  test("the pages keep the facts that must not change", () => {
    for (const { code } of LANGUAGES) {
      const page = readFileSync(join(out, code, "index.html"), "utf8");
      assert.ok(page.includes("curl -fsSL https://dogr.dev/setup.sh | sh"), `${code}: the command`);
      assert.ok(page.includes("mailto:fb@dogr.dev"), `${code}: the address`);
      assert.ok(page.includes("800+"), `${code}: the theme count`);
      assert.ok(page.includes("data-copied="), `${code}: the copied label`);
    }
  });
  test("every page has the App Store code and badge at the right of the name and the badge and code again at the bottom, all leading to /get", () => {
    for (const { code } of LANGUAGES) {
      const page = readFileSync(join(out, code, "index.html"), "utf8");
      const hero = page.slice(page.indexOf('<section class="hero">'), page.indexOf('id="herdr"'));
      const download = page.slice(page.indexOf('<section id="download">'), page.indexOf("</main>"));
      const badge = new RegExp(`<a class="storebadge" href="/get"><img src="/img/appstore/${code}\\.svg" height="\\d+" alt="[^"]+">`);
      // The code and the badge come after the <h1> in the same row, so they sit at the right of the name.
      assert.ok(hero.indexOf('<div class="titlerow">') >= 0 && hero.indexOf("<h1>") < hero.indexOf('<div class="getit">'), `${code}: the name, then the code and badge`);
      assert.match(hero, /<a class="qrlink" href="\/get"><img src="\/img\/qr-get\.svg"[^>]* alt="[^"]+">/, `${code}: the code at the top`);
      assert.match(hero, badge, `${code}: the badge at the top`);
      assert.match(download, badge, `${code}: the badge at the bottom`);
      assert.match(download, /<a class="qr" href="\/get"><img src="\/img\/qr-get\.svg"[^>]* alt="[^"]+"/, `${code}: the code at the bottom`);
      assert.ok(!page.includes("btn soon"), `${code}: no placeholder button is left`);
    }
  });
  test("the QR code of the home page is a valid static SVG", () => {
    const svg = readFileSync(join(ROOT, "site", "img", "qr-get.svg"), "utf8");
    const box = svg.match(/viewBox="0 0 (\d+) (\d+)"/);
    // Square, and big enough for the shortest QR version (21 modules) plus a quiet zone of four modules on each side.
    assert.ok(box && box[1] === box[2] && Number(box[1]) >= 29, "a square box with a quiet zone");
    assert.equal((svg.match(/<path /g) ?? []).length, 1, "the dark modules are one path");
    assert.ok(!/<script|<image|<foreignObject|href=|onload/i.test(svg), "nothing active or outside");
    assert.ok(svg.length < 20000, "small enough to inline-load");
  });
  test("the two group cards carry a valid static code of their invite link", () => {
    for (const { code } of LANGUAGES) {
      const page = readFileSync(join(out, code, "index.html"), "utf8");
      const feedback = page.slice(page.indexOf('id="feedback"'), page.indexOf('<section id="download">'));
      assert.match(feedback, /<a class="chanqr" href="https:\/\/discord\.gg\/[A-Za-z0-9]+"><img src="\/img\/qr-discord\.svg"[^>]* alt="[^"]+"/, `${code}: the Discord code`);
      assert.match(feedback, /<a class="chanqr" href="https:\/\/t\.me\/[A-Za-z0-9_]+"><img src="\/img\/qr-telegram\.svg"[^>]* alt="[^"]+"/, `${code}: the Telegram code`);
    }
    for (const name of ["qr-discord.svg", "qr-telegram.svg"]) {
      const svg = readFileSync(join(ROOT, "site", "img", name), "utf8");
      const box = svg.match(/viewBox="0 0 (\d+) (\d+)"/);
      assert.ok(box && box[1] === box[2] && Number(box[1]) >= 29, `${name}: a square box with a quiet zone`);
      assert.equal((svg.match(/<path /g) ?? []).length, 1, `${name}: the dark modules are one path`);
      assert.ok(!/<script|<image|<foreignObject|href=|onload/i.test(svg), `${name}: nothing active or outside`);
    }
  });
  test("the App Store badges are one unchanged static SVG per language", () => {
    const dir = join(ROOT, "site", "img", "appstore");
    assert.deepEqual(readdirSync(dir).sort(), LANGUAGES.map(({ code }) => `${code}.svg`).sort());
    for (const { code } of LANGUAGES) {
      const svg = readFileSync(join(dir, `${code}.svg`), "utf8");
      assert.ok(svg.trimStart().startsWith("<svg") && svg.includes("viewBox"), `${code}: an SVG with a box`);
      assert.ok(!/<script|onload|<foreignObject/i.test(svg), `${code}: nothing active`);
      assert.ok(!svg.replaceAll("http://www.w3.org/2000/svg", "").includes("http"), `${code}: no outside address`);
    }
  });

  // TEST:tests/site.test.mjs[the What's new page]
  test("the pill of every home page shows the newest version and leads to the What's new page of its language", () => {
    const latest = latestWhatsNew(join(ROOT, "site"));
    assert.match(latest, /^\d+\.\d+/);
    for (const { code } of LANGUAGES) {
      const page = readFileSync(join(out, code, "index.html"), "utf8");
      assert.ok(page.includes(`href="/${code}/ios/whatsnew/" title="`), `${code}: the pill leads to its own language's What's new page`);
      assert.match(page, new RegExp(`<a class="pill"[^>]*>v${latest.replaceAll(".", "\\.")}</a>`), `${code}: the pill shows the newest version`);
    }
  });

  // TEST:tests/site.test.mjs[the What's new page]
  test("every language has its own What's new page, complete and linked to the others", () => {
    for (const { code, html, name } of LANGUAGES) {
      const page = readFileSync(join(out, code, "ios", "whatsnew", "index.html"), "utf8");
      assert.ok(page.includes(`<html lang="${html}">`), code);
      assert.ok(!page.includes("{{") && !page.includes("<!--"), `${code}: nothing is left of the template`);
      assert.equal((page.match(/rel="alternate" hreflang=/g) ?? []).length, 13, `${code}: 12 languages and x-default`);
      assert.ok(page.includes('hreflang="x-default" href="https://dogr.dev/ios/whatsnew/"'), `${code}: x-default`);
      assert.ok(page.includes(`<link rel="canonical" href="${canonicalOf(code, WHATSNEW_FOLDER)}">`), `${code}: canonical`);
      // The menu links lead to this same page in the other language, not to the home page.
      assert.ok(page.includes(`href="/${code}/ios/whatsnew/" lang="${html}"`), `${code}: its own entry of the menu`);
      assert.ok(page.includes('href="/en/ios/whatsnew/" lang="en"'), `${code}: English is always one click away`);
      assert.ok(page.includes(`data-folder="ios/whatsnew/"`) && page.includes(`data-current="${code}"`), `${code}: page.js knows which page the menu is on`);
      assert.ok(page.includes(`<span>${name}</span>`), `${code}: the button shows the language name`);
      // The way back and the data the script draws the list from.
      assert.ok(page.includes(`<a href="/${code}/">`), `${code}: the way back to the home page of this language`);
      assert.ok(page.includes('data-src="/ios/whatsnew-1.json"') && page.includes(`data-lang="${code}"`), `${code}: the data file and the language`);
      assert.ok(/data-loading="[^"]+" data-error="[^"]+" data-latest="[^"]+"/.test(page), `${code}: the texts of the states the script draws`);
      assert.ok(page.includes('<script type="module" src="/whatsnew.js">'), `${code}: the script`);
    }
    for (const file of ["whatsnew.js", "whatsnew.mjs"]) assert.ok(readdirSync(out).includes(file), file);
  });

  test("the data file is copied unchanged to /ios/ and the home page names the same newest version", () => {
    const source = readFileSync(join(ROOT, "site", UPDATE_RULES_DIR, "whatsnew-1.json"), "utf8");
    assert.equal(readFileSync(join(out, UPDATE_RULES_DIR, "whatsnew-1.json"), "utf8"), source);
    assert.equal(latestWhatsNew(join(ROOT, "site")), JSON.parse(source).versions[0].version);
  });

  test("the sitemap lists every language and the robots file names it", () => {
    const text = sitemap();
    // The home page and the "What's new" page of every language, then the plain pages.
    assert.equal((text.match(/<loc>/g) ?? []).length, 12 + 12 + PLAIN_PAGES.length);
    assert.ok(text.includes("<loc>https://dogr.dev/ios/whatsnew/</loc>") && text.includes("<loc>https://dogr.dev/de/ios/whatsnew/</loc>"));
    assert.ok(!text.includes("<loc>https://dogr.dev/en/ios/whatsnew/</loc>"), "English is listed once, at the address without a language");
    assert.ok(text.includes("<loc>https://dogr.dev/privacy/</loc>") && text.includes("<loc>https://dogr.dev/support/</loc>"));
    assert.ok(text.includes("<loc>https://dogr.dev/</loc>"));
    assert.ok(text.includes("<loc>https://dogr.dev/zh-tw/</loc>"));
    assert.ok(!text.includes("<loc>https://dogr.dev/en/</loc>"), "English is listed once, at the root");
    assert.equal(readFileSync(join(out, "sitemap.xml"), "utf8"), text);
    assert.ok(readFileSync(join(out, "robots.txt"), "utf8").includes("Sitemap: https://dogr.dev/sitemap.xml"));
  });

  // The App Store listing points at these two addresses, so they must exist, say who they are, and link to each other.
  test("the privacy and support pages are written, finished and linked", () => {
    assert.deepEqual(PLAIN_PAGES, ["privacy", "support"]);
    for (const name of PLAIN_PAGES) {
      const page = readFileSync(join(out, name, "index.html"), "utf8");
      assert.ok(page.includes(`<link rel="canonical" href="https://dogr.dev/${name}/">`), `${name}: canonical`);
      assert.ok(!page.includes("{{") && !/TODO|lorem/i.test(page), `${name}: nothing unfinished`);
      assert.ok(page.includes('href="mailto:fb@dogr.dev"'), `${name}: the contact`);
      assert.ok(page.includes('<link rel="stylesheet" href="/style.css">'), `${name}: the style`);
    }
    assert.ok(readFileSync(join(out, "privacy", "index.html"), "utf8").includes('href="/support/"'));
    assert.ok(readFileSync(join(out, "support", "index.html"), "utf8").includes('href="/privacy/"'));
    for (const { code } of LANGUAGES) {
      const page = readFileSync(join(out, code, "index.html"), "utf8");
      assert.ok(page.includes('href="/privacy/"') && page.includes('href="/support/"'), `${code}: the footer links`);
    }
  });

  test("a page cannot be rendered when the template asks for something that does not exist", () => {
    const { strings } = loadStrings(STRINGS_FILE);
    assert.throws(() => renderPage("{{missing.key}}", strings.en, "en"), /missing "missing.key"/);
    assert.throws(() => renderPage("{{$nope}}", strings.en, "en"), /computed value "nope"/);
  });
});

describe("worker: the home page", () => {
  /** A stand-in for the file store: serves the English page and records what was asked. */
  function files({ failFirst = false } = {}) {
    const asked = [];
    let failed = false;
    return {
      asked,
      ASSETS: {
        async fetch(request) {
          asked.push(new URL(request.url).pathname);
          if (failFirst && !failed) {
            failed = true;
            throw new Error("store down");
          }
          return new Response("<html>ENGLISH</html>", { headers: { "content-type": "text/html; charset=utf-8", etag: '"abc"' } });
        },
      },
    };
  }

  /** Builds a request for the home page with the given headers. */
  function homeRequest(headers = {}, { method = "GET", path = "/" } = {}) {
    return new Request(`https://dogr.dev${path}`, { method, headers });
  }

  test("no language information gives the English page itself, not a redirect", async () => {
    const env = files();
    const answer = await worker.fetch(homeRequest(), env);
    assert.equal(answer.status, 200);
    assert.equal(await answer.text(), "<html>ENGLISH</html>");
    assert.deepEqual(env.asked, ["/en/"]);
    assert.equal(answer.headers.get("vary"), "Accept-Language, Cookie");
    assert.match(answer.headers.get("cache-control"), /private/);
    assert.equal(answer.headers.get("etag"), '"abc"', "the headers of the page are kept");
  });

  test("a browser language of ours is a temporary redirect to its page", async () => {
    const answer = await worker.fetch(homeRequest({ "accept-language": "de-CH,fr;q=0.8" }), files());
    assert.equal(answer.status, 302);
    assert.equal(answer.headers.get("location"), "/de/");
    assert.equal(answer.headers.get("vary"), "Accept-Language, Cookie");
    assert.match(answer.headers.get("cache-control"), /no-store/);
  });

  test("the query string survives the redirect", async () => {
    const answer = await worker.fetch(homeRequest({ "accept-language": "ja" }, { path: "/?utm=a&b=2" }), files());
    assert.equal(answer.headers.get("location"), "/ja/?utm=a&b=2");
  });

  test("Traditional Chinese browsers land on the Traditional page", async () => {
    const answer = await worker.fetch(homeRequest({ "accept-language": "zh-HK,zh;q=0.9,en;q=0.5" }), files());
    assert.equal(answer.headers.get("location"), "/zh-tw/");
  });

  test("English first in the browser keeps the English page", async () => {
    const answer = await worker.fetch(homeRequest({ "accept-language": "en-US,en;q=0.9,ja;q=0.8" }), files());
    assert.equal(answer.status, 200);
  });

  test("a language we do not have falls back to English", async () => {
    const answer = await worker.fetch(homeRequest({ "accept-language": "nl,sv;q=0.7" }), files());
    assert.equal(answer.status, 200);
  });

  test("the cookie beats the browser, in both directions", async () => {
    const toEnglish = await worker.fetch(homeRequest({ "accept-language": "de", cookie: "lang=en" }), files());
    assert.equal(toEnglish.status, 200, "a German browser that picked English stays on English");
    const toJapanese = await worker.fetch(homeRequest({ "accept-language": "en", cookie: "x=1; lang=ja" }), files());
    assert.equal(toJapanese.status, 302);
    assert.equal(toJapanese.headers.get("location"), "/ja/");
  });

  test("a cookie that is not a language is ignored", async () => {
    const answer = await worker.fetch(homeRequest({ "accept-language": "fr", cookie: "lang=../../x" }), files());
    assert.equal(answer.headers.get("location"), "/fr/");
  });

  test("HEAD is answered like GET, other methods are refused", async () => {
    const head = await worker.fetch(homeRequest({}, { method: "HEAD" }), files());
    assert.equal(head.status, 200);
    const post = await worker.fetch(homeRequest({}, { method: "POST" }), files());
    assert.equal(post.status, 405);
  });

  test("a failing file store is tried once more before giving up", async () => {
    const env = files({ failFirst: true });
    const answer = await worker.fetch(homeRequest(), env);
    assert.equal(answer.status, 200);
    assert.equal(env.asked.length, 2);
  });

  // The "What's new" page is chosen like the home page, in its own folder of every language. TEST:tests/site.test.mjs[the What's new page]
  test("/ios/whatsnew gives the English page itself, with or without the closing slash", async () => {
    for (const path of ["/ios/whatsnew", "/ios/whatsnew/"]) {
      const env = files();
      const answer = await worker.fetch(homeRequest({}, { path }), env);
      assert.equal(answer.status, 200, path);
      assert.deepEqual(env.asked, ["/en/ios/whatsnew/"], path);
      assert.equal(answer.headers.get("vary"), "Accept-Language, Cookie");
    }
  });

  test("/ios/whatsnew sends other languages to their own What's new page, and keeps the query string", async () => {
    const german = await worker.fetch(homeRequest({ "accept-language": "de" }, { path: "/ios/whatsnew" }), files());
    assert.equal(german.status, 302);
    assert.equal(german.headers.get("location"), "/de/ios/whatsnew/");
    const chinese = await worker.fetch(homeRequest({ "accept-language": "zh-TW" }, { path: "/ios/whatsnew/?from=pill" }), files());
    assert.equal(chinese.headers.get("location"), "/zh-tw/ios/whatsnew/?from=pill");
    const cookie = await worker.fetch(homeRequest({ "accept-language": "en", cookie: "lang=ja" }, { path: "/ios/whatsnew" }), files());
    assert.equal(cookie.headers.get("location"), "/ja/ios/whatsnew/");
  });

  test("/ios/whatsnew: a file store that fails on the retry too is an error, never a wrong page", async () => {
    const env = {
      ASSETS: {
        async fetch() {
          throw new Error("store down");
        },
      },
    };
    await assert.rejects(() => worker.fetch(homeRequest({}, { path: "/ios/whatsnew" }), env), /store down/);
  });

  test("only GET and HEAD are answered on /ios/whatsnew", async () => {
    assert.equal((await worker.fetch(homeRequest({}, { method: "POST", path: "/ios/whatsnew" }), files())).status, 405);
    assert.equal((await worker.fetch(homeRequest({}, { method: "HEAD", path: "/ios/whatsnew" }), files())).status, 200);
  });

  test("the data file and the other files below /ios/ are not the Worker's business", async () => {
    assert.equal((await worker.fetch(homeRequest({}, { path: "/ios/whatsnew-1.json" }), files())).status, 404);
    const routes = readFileSync(join(ROOT, "wrangler.jsonc"), "utf8").match(/"run_worker_first": \[([^\]]*)\]/)[1];
    assert.match(routes, /"\/ios\/whatsnew"/);
    assert.match(routes, /"\/ios\/whatsnew\/"/);
    assert.ok(!/whatsnew-1/.test(routes), "the data file is a plain file");
  });

  test("any other address is a 404", async () => {
    const answer = await worker.fetch(homeRequest({}, { path: "/nope" }), files());
    assert.equal(answer.status, 404);
  });
});

describe("worker: /get", () => {
  test("the target is the app's page in the App Store", () => {
    assert.match(APP_STORE_URL, /^https:\/\/apps\.apple\.com\/app\/id\d+$/);
  });
  test("GET is a temporary redirect that is never kept, and the query string does not change the target", async () => {
    for (const path of ["/get", "/get?utm=x"]) {
      const answer = await worker.fetch(new Request(`https://dogr.dev${path}`), {});
      assert.equal(answer.status, 302);
      assert.equal(answer.headers.get("location"), APP_STORE_URL);
      assert.match(answer.headers.get("cache-control"), /no-store/);
    }
  });
  test("HEAD is answered the same way and other methods are refused", async () => {
    const head = await worker.fetch(new Request("https://dogr.dev/get", { method: "HEAD" }), {});
    assert.equal(head.status, 302);
    assert.equal(head.headers.get("location"), APP_STORE_URL);
    const post = await worker.fetch(new Request("https://dogr.dev/get", { method: "POST" }), {});
    assert.equal(post.status, 405);
    assert.equal(post.headers.get("location"), null);
  });
  test("wrangler.jsonc sends /get to the Worker first", () => {
    assert.match(readFileSync(join(ROOT, "wrangler.jsonc"), "utf8"), /"run_worker_first": \[[^\]]*"\/get"/);
  });
});
describe("worker: /_geo", () => {
  /** A request that carries the country Cloudflare would have put on it. */
  function geoRequest(country) {
    const request = new Request("https://dogr.dev/_geo");
    if (country !== undefined) Object.defineProperty(request, "cf", { value: { country } });
    return request;
  }

  test("answers with the language of the country, never the country", async () => {
    const answer = await worker.fetch(geoRequest("JP"), {});
    assert.deepEqual(await answer.json(), { language: "ja" });
    assert.match(answer.headers.get("content-type"), /application\/json/);
    assert.match(answer.headers.get("cache-control"), /no-store/);
  });

  test("answers null for an unknown country and when there is no country", async () => {
    assert.deepEqual(await (await worker.fetch(geoRequest("US"), {})).json(), { language: null });
    assert.deepEqual(await (await worker.fetch(geoRequest("T1"), {})).json(), { language: null });
    assert.deepEqual(await (await worker.fetch(geoRequest(undefined), {})).json(), { language: null });
  });
});

describe("worker: /setup.sh", () => {
  const realFetch = globalThis.fetch;
  after(() => {
    globalThis.fetch = realFetch;
  });

  /** Replaces the network with one answer. */
  function upstream(make) {
    globalThis.fetch = async () => make();
  }

  const setupRequest = (method = "GET") => new Request("https://dogr.dev/setup.sh", { method });

  test("a real script is passed through as plain text", async () => {
    upstream(() => new Response("#!/bin/sh\necho hi\n"));
    const answer = await worker.fetch(setupRequest(), {});
    assert.equal(answer.status, 200);
    assert.equal(await answer.text(), "#!/bin/sh\necho hi\n");
    assert.match(answer.headers.get("content-type"), /text\/plain/);
    assert.equal(answer.headers.get("x-content-type-options"), "nosniff");
  });

  test("something that is not a script never reaches sh", async () => {
    upstream(() => new Response("<html>error</html>"));
    const answer = await worker.fetch(setupRequest(), {});
    assert.equal(answer.status, 502);
  });

  test("a failed or unreachable upstream is a 502", async () => {
    upstream(() => new Response("nope", { status: 404 }));
    assert.equal((await worker.fetch(setupRequest(), {})).status, 502);
    globalThis.fetch = async () => {
      throw new Error("offline");
    };
    assert.equal((await worker.fetch(setupRequest(), {})).status, 502);
  });

  test("only GET and HEAD are answered", async () => {
    upstream(() => new Response("#!/bin/sh\n"));
    assert.equal((await worker.fetch(setupRequest("POST"), {})).status, 405);
    const head = await worker.fetch(setupRequest("HEAD"), {});
    assert.equal(head.status, 200);
    assert.equal(await head.text(), "");
  });
});
