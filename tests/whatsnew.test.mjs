// Tests of the "What's new" page's rules (site/whatsnew.mjs) and of the script that keeps its data file up to date
// (tools/whatsnew.mjs). No network, no App Store Connect, no Cloudflare and no git: the script is run with stand-ins for all of them.
// Run from the repository root with:  node --test tests/whatsnew.test.mjs

import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { LANGUAGES } from "../lang.js";
import { parseNotes, pickNotes, releaseModels } from "../site/whatsnew.mjs";
import {
  DATA_FILE,
  LOCALE_TO_CODE,
  appId,
  commitMessage,
  isReleased,
  main,
  mergeVersions,
  notesFromLocalizations,
  parseArgs,
  readData,
  selectNewVersions,
  serialize,
} from "../tools/whatsnew.mjs";
import { APP_STORE_URL } from "../app-store.js";

// ---- the rules of the page ---------------------------------------------------------------------------------------------

// TEST:site/whatsnew.mjs[parseNotes]
describe("splitting the notes of a version", () => {
  test("a summary, a list of bullets and a closing paragraph", () => {
    const blocks = parseNotes("Richer cards.\n\n• One\n• Two\n\nThanks for the feedback.");
    assert.deepEqual(blocks, [
      { type: "p", text: "Richer cards." },
      { type: "ul", items: ["One", "Two"] },
      { type: "p", text: "Thanks for the feedback." },
    ]);
  });

  test("bullets stay one list when blank lines separate them, and a wrapped bullet is joined", () => {
    assert.deepEqual(parseNotes("• One\n\n• Two\ncontinued\n• Three"), [{ type: "ul", items: ["One", "Two continued", "Three"] }]);
  });

  test("other bullet signs work, and a sign with no text says nothing", () => {
    assert.deepEqual(parseNotes("・一\n- two\n* three\n•"), [{ type: "ul", items: ["一", "two", "three"] }]);
  });

  test("Windows line endings and surrounding spaces do not matter, an empty text has no blocks", () => {
    assert.deepEqual(parseNotes("  Hello  \r\n\r\n•  A \r\n"), [{ type: "p", text: "Hello" }, { type: "ul", items: ["A"] }]);
    assert.deepEqual(parseNotes(""), []);
    assert.deepEqual(parseNotes("\n \n"), []);
  });

  test("the lines of one paragraph keep their line breaks, and a dash inside a line is not a bullet", () => {
    assert.deepEqual(parseNotes("One\nTwo - three"), [{ type: "p", text: "One\nTwo - three" }]);
  });
});

// TEST:site/whatsnew.mjs[pickNotes, releaseModels]
describe("choosing the text of a version", () => {
  test("the page's own language when the version has it, English otherwise", () => {
    assert.deepEqual(pickNotes({ en: "E", de: "D" }, "de"), { text: "D", lang: null });
    assert.deepEqual(pickNotes({ en: "E" }, "de"), { text: "E", lang: "en" });
    assert.deepEqual(pickNotes({ en: "E", de: "  " }, "de"), { text: "E", lang: "en" }, "an empty text counts as missing");
    assert.deepEqual(pickNotes({ en: "E" }, "en"), { text: "E", lang: null }, "English is not a fallback of itself");
  });

  test("a model per version, newest first, and only the first is the latest", () => {
    const models = releaseModels(
      { schema: 1, versions: [{ version: "0.4", notes: { en: "A\n\n• x", ja: "あ" } }, { version: "0.3", notes: { en: "B" } }] },
      "ja",
    );
    assert.deepEqual(models.map((model) => [model.version, model.latest, model.lang]), [["0.4", true, null], ["0.3", false, "en"]]);
    assert.deepEqual(models[0].blocks, [{ type: "p", text: "あ" }]);
    assert.deepEqual(models[1].blocks, [{ type: "p", text: "B" }]);
  });

  test("a file of another format is refused instead of drawn wrongly", () => {
    assert.throws(() => releaseModels({ schema: 2, versions: [] }, "en"), /format 1/);
    assert.throws(() => releaseModels(null, "en"), /format 1/);
    assert.throws(() => releaseModels({ schema: 1 }, "en"), /format 1/);
  });
});

// ---- the update script -------------------------------------------------------------------------------------------------

/** A version as `asc versions list` answers. */
const ascVersion = (id, versionString, state = "READY_FOR_DISTRIBUTION", platform = "IOS") => ({ id, attributes: { versionString, appVersionState: state, appStoreState: state, platform } });
/** A localization as `asc localizations list` answers. */
const ascLocalization = (locale, whatsNew) => ({ attributes: { locale, whatsNew } });

// TEST:tools/whatsnew.mjs[LOCALE_TO_CODE]
describe("the App Store locales", () => {
  test("every language of the site has an App Store locale, and every locale leads to a language of the site", () => {
    const codes = new Set(Object.values(LOCALE_TO_CODE));
    for (const { code } of LANGUAGES) assert.ok(codes.has(code), `${code} has no App Store locale`);
    for (const code of codes) assert.ok(LANGUAGES.some((language) => language.code === code), `${code} is not a language of the site`);
  });
});

// TEST:tools/whatsnew.mjs[selectNewVersions, isReleased]
describe("picking the new versions", () => {
  const list = [
    ascVersion("a", "0.2"),
    ascVersion("b", "0.3", "REPLACED_WITH_NEW_VERSION"),
    ascVersion("c", "0.4", "READY_FOR_SALE"),
    ascVersion("d", "0.5", "IN_REVIEW"),
    ascVersion("e", "0.6", "PREPARE_FOR_SUBMISSION"),
    ascVersion("f", "0.10", "READY_FOR_DISTRIBUTION"),
    ascVersion("g", "0.7", "READY_FOR_DISTRIBUTION", "MAC_OS"),
  ];

  test("only released iOS versions count, and a version in review does not", () => {
    assert.equal(isReleased(list[3].attributes), false);
    assert.equal(isReleased(list[4].attributes), false);
    assert.equal(isReleased(list[6].attributes), false, "another platform");
    assert.equal(isReleased(list[2].attributes), true);
    assert.equal(isReleased({ platform: "IOS", appVersionState: "PENDING", appStoreState: "READY_FOR_SALE" }), true, "either state field may say it");
  });

  test("everything newer than the last version, newest first and compared as numbers", () => {
    assert.deepEqual(selectNewVersions(list, "0.3"), [{ id: "f", version: "0.10" }, { id: "c", version: "0.4" }]);
    assert.deepEqual(selectNewVersions(list, "0.10"), []);
    assert.deepEqual(selectNewVersions(list, null).map((entry) => entry.version), ["0.10", "0.4", "0.3", "0.2"]);
  });

  test("a version that appears twice or has an odd name is taken once or not at all", () => {
    const odd = [ascVersion("a", "0.4"), ascVersion("b", "0.4"), ascVersion("c", "beta"), { id: "d", attributes: {} }];
    assert.deepEqual(selectNewVersions(odd, "0.3"), [{ id: "a", version: "0.4" }]);
  });
});

// TEST:tools/whatsnew.mjs[notesFromLocalizations, mergeVersions, commitMessage, parseArgs, appId, readData]
describe("the small pieces of the script", () => {
  test("notes keep the order of the language menu, drop empty texts and unknown locales, and fix the line endings", () => {
    const notes = notesFromLocalizations([
      ascLocalization("ja", "あ"),
      ascLocalization("en-US", "  Hello\r\nthere  "),
      ascLocalization("de-DE", ""),
      ascLocalization("fr-CA", "Canada"),
      ascLocalization("zh-Hant", "繁"),
      ascLocalization("tr", null),
    ]);
    assert.deepEqual(Object.keys(notes), ["en", "ja", "zh-tw"]);
    assert.equal(notes.en, "Hello\nthere");
  });

  test("when two locales mean one language the first text wins", () => {
    assert.deepEqual(notesFromLocalizations([ascLocalization("it-IT", "uno"), ascLocalization("it", "due")]), { it: "uno" });
  });

  test("new versions go in front and the old data is not touched", () => {
    const data = { schema: 1, versions: [{ version: "0.3", notes: { en: "x" } }] };
    const merged = mergeVersions(data, [{ version: "0.4", notes: { en: "y" } }]);
    assert.deepEqual(merged.versions.map((entry) => entry.version), ["0.4", "0.3"]);
    assert.equal(data.versions.length, 1);
  });

  test("the file is two-space JSON with a closing line break; the commit message names the versions", () => {
    assert.equal(serialize({ a: 1 }), '{\n  "a": 1\n}\n');
    assert.equal(commitMessage(["0.5", "0.4"]), "feat(site): add the release notes of 0.5, 0.4");
  });

  test("options: flags, the app id, and refusing what it does not know", () => {
    assert.deepEqual(parseArgs([]), { dryRun: false, noDeploy: false, noCommit: false, yes: false, allowDirty: false, skipTests: false, app: null, help: false });
    const all = parseArgs(["--dry-run", "--no-deploy", "--no-commit", "--yes", "--allow-dirty", "--skip-tests", "--app", "123", "-h"]);
    assert.deepEqual(all, { dryRun: true, noDeploy: true, noCommit: true, yes: true, allowDirty: true, skipTests: true, app: "123", help: true });
    assert.throws(() => parseArgs(["--deploy"]), /unknown option --deploy/);
    assert.throws(() => parseArgs(["--app"]), /--app needs/);
    assert.throws(() => parseArgs(["--app", "abc"]), /--app needs/);
  });

  test("the app id: the option, then the environment, then the one the /get link names", () => {
    assert.equal(appId({ app: "1" }, { ASC_APP_ID: "2" }), "1");
    assert.equal(appId({ app: null }, { ASC_APP_ID: "2" }), "2");
    assert.equal(appId({ app: null }, { ASC_APP_ID: "not a number" }), /\/id(\d+)/.exec(APP_STORE_URL)[1]);
    assert.equal(appId({ app: null }, {}), /\/id(\d+)/.exec(APP_STORE_URL)[1]);
  });

  test("a missing file is an empty start, a good one gives its newest version, a wrong one is refused", () => {
    assert.deepEqual(readData(null), { data: { schema: 1, versions: [] }, last: null });
    const text = serialize({ schema: 1, versions: [{ version: "0.4", notes: { en: "x" } }, { version: "0.3", notes: { en: "y" } }] });
    assert.equal(readData(text).last, "0.4");
    assert.throws(() => readData("{nope"), /not good, fix it first/);
  });
});

/**
 * Stand-ins for everything the script touches. The "file" is a string in memory; every call is recorded in `calls`.
 * @param {object} [options] What the stand-ins answer.
 * @returns {{ deps: object, calls: string[], files: Map<string, string> }} The dependencies, what happened, and the files.
 */
function world({ file = null, versions = [], localizations = {}, dirty = [], verify = [], confirm = true, deployFails = false, env = {} } = {}) {
  const files = new Map();
  if (file !== null) files.set(DATA_FILE, file);
  const calls = [];
  const deps = {
    env,
    log: (line) => calls.push(`log: ${line}`),
    asc(args) {
      calls.push(`asc ${args.slice(0, 2).join(" ")}`);
      if (args[0] === "versions") return { data: versions };
      return { data: localizations[args[args.indexOf("--version") + 1]] ?? [] };
    },
    read: (name) => files.get(name) ?? null,
    write(name, text) {
      calls.push(`write ${text === "" ? "(empty)" : "data"}`);
      files.set(name, text);
    },
    remove(name) {
      calls.push("remove");
      files.delete(name);
    },
    dirty: () => dirty,
    verify() {
      calls.push("verify");
      return verify;
    },
    deploy() {
      calls.push("deploy");
      if (deployFails) throw new Error("wrangler deploy failed");
    },
    commit(message, name) {
      calls.push(`commit ${message} | ${name}`);
    },
    async confirm(question) {
      calls.push(`confirm ${question}`);
      return confirm;
    },
  };
  return { deps, calls, files };
}

const OLD_FILE = serialize({ schema: 1, versions: [{ version: "0.3", notes: { en: "Old three" } }] });
const STORE = [ascVersion("v3", "0.3"), ascVersion("v4", "0.4"), ascVersion("v5", "0.5", "IN_REVIEW")];
const NOTES = { v4: [ascLocalization("en-US", "Summary\n\n• One"), ascLocalization("de-DE", "Zusammenfassung")] };
/** The version numbers in a data file, newest first. */
const versionsIn = (text) => JSON.parse(text).versions.map((entry) => entry.version);
/** The recorded calls without the log lines. */
const doing = (calls) => calls.filter((call) => !call.startsWith("log: "));

// TEST:tools/whatsnew.mjs[main]
describe("the update, step by step", () => {
  test("nothing newer on the App Store: it says so and changes nothing", async () => {
    const { deps, calls, files } = world({ file: OLD_FILE, versions: [ascVersion("v3", "0.3"), ascVersion("v5", "0.5", "IN_REVIEW")] });
    assert.equal(await main([], deps), 0);
    assert.deepEqual(doing(calls), ["asc versions list"]);
    assert.equal(files.get(DATA_FILE), OLD_FILE);
    assert.ok(calls.some((call) => call.includes("Nothing new")));
  });

  test("a new version is written, checked, deployed after asking, and committed", async () => {
    const { deps, calls, files } = world({ file: OLD_FILE, versions: STORE, localizations: NOTES });
    assert.equal(await main([], deps), 0);
    assert.deepEqual(versionsIn(files.get(DATA_FILE)), ["0.4", "0.3"]);
    assert.deepEqual(JSON.parse(files.get(DATA_FILE)).versions[0].notes, { en: "Summary\n\n• One", de: "Zusammenfassung" });
    assert.deepEqual(doing(calls), [
      "asc versions list",
      "asc localizations list",
      "write data",
      "verify",
      "confirm Deploy 0.4 to dogr.dev now?",
      "deploy",
      `commit feat(site): add the release notes of 0.4 | ${DATA_FILE}`,
    ]);
  });

  test("--yes does not ask, --no-deploy neither asks nor deploys, --no-commit leaves the commit to the person", async () => {
    const yes = world({ file: OLD_FILE, versions: STORE, localizations: NOTES });
    await main(["--yes"], yes.deps);
    assert.ok(!doing(yes.calls).some((call) => call.startsWith("confirm")));
    assert.ok(doing(yes.calls).includes("deploy"));

    const noDeploy = world({ file: OLD_FILE, versions: STORE, localizations: NOTES });
    await main(["--no-deploy"], noDeploy.deps);
    assert.deepEqual(doing(noDeploy.calls).slice(-2), ["verify", `commit feat(site): add the release notes of 0.4 | ${DATA_FILE}`]);
    assert.ok(noDeploy.calls.some((call) => call.includes("npx wrangler@4 deploy")), "it tells how to deploy by hand");

    const noCommit = world({ file: OLD_FILE, versions: STORE, localizations: NOTES });
    await main(["--yes", "--no-commit"], noCommit.deps);
    assert.ok(!doing(noCommit.calls).some((call) => call.startsWith("commit")));
    assert.deepEqual(versionsIn(noCommit.files.get(DATA_FILE)), ["0.4", "0.3"], "the file stays changed");
  });

  test("--dry-run shows what it would do and writes nothing", async () => {
    const { deps, calls, files } = world({ file: OLD_FILE, versions: STORE, localizations: NOTES });
    assert.equal(await main(["--dry-run"], deps), 0);
    assert.deepEqual(doing(calls), ["asc versions list", "asc localizations list"]);
    assert.equal(files.get(DATA_FILE), OLD_FILE);
  });

  test("a version without an English text is skipped, and the others are still added", async () => {
    const versions = [ascVersion("v4", "0.4"), ascVersion("v5", "0.5")];
    const localizations = { v4: [ascLocalization("de-DE", "nur Deutsch")], v5: [ascLocalization("en-US", "Five")] };
    const { deps, calls, files } = world({ file: OLD_FILE, versions, localizations });
    await main(["--yes"], deps);
    assert.deepEqual(versionsIn(files.get(DATA_FILE)), ["0.5", "0.3"]);
    assert.ok(calls.some((call) => call.includes("0.4: skipped")));
  });

  test("when no version can be added nothing is written", async () => {
    const { deps, calls, files } = world({ file: OLD_FILE, versions: [ascVersion("v4", "0.4")], localizations: { v4: [] } });
    assert.equal(await main(["--yes"], deps), 0);
    assert.ok(!doing(calls).includes("write data"));
    assert.equal(files.get(DATA_FILE), OLD_FILE);
  });

  test("a missing data file starts from nothing, and several versions come out newest first", async () => {
    const versions = [ascVersion("v3", "0.3"), ascVersion("v4", "0.4")];
    const localizations = { v3: [ascLocalization("en-US", "Three")], v4: [ascLocalization("en-US", "Four")] };
    const { deps, files } = world({ versions, localizations });
    await main(["--yes", "--no-commit"], deps);
    assert.deepEqual(versionsIn(files.get(DATA_FILE)), ["0.4", "0.3"]);
  });

  test("other uncommitted work in dogr stops a deploy before anything is written, unless allowed", async () => {
    const dirty = [" M worker.js", ` M ${DATA_FILE}`];
    const blocked = world({ file: OLD_FILE, versions: STORE, localizations: NOTES, dirty });
    await assert.rejects(() => main(["--yes"], blocked.deps), /other uncommitted changes[\s\S]*worker\.js/);
    assert.ok(!doing(blocked.calls).includes("write data"));
    assert.equal(blocked.files.get(DATA_FILE), OLD_FILE);

    const allowed = world({ file: OLD_FILE, versions: STORE, localizations: NOTES, dirty });
    assert.equal(await main(["--yes", "--allow-dirty"], allowed.deps), 0);
    const withoutDeploy = world({ file: OLD_FILE, versions: STORE, localizations: NOTES, dirty });
    assert.equal(await main(["--yes", "--no-deploy"], withoutDeploy.deps), 0, "without a deploy, other work does not matter");
    // A change of the data file alone is the expected state of a run that stopped half way.
    const own = world({ file: OLD_FILE, versions: STORE, localizations: NOTES, dirty: [` M ${DATA_FILE}`] });
    assert.equal(await main(["--yes"], own.deps), 0);
  });

  test("failed checks put the old file back, and nothing is deployed or committed", async () => {
    const { deps, calls, files } = world({ file: OLD_FILE, versions: STORE, localizations: NOTES, verify: ["the build failed: x"] });
    await assert.rejects(() => main(["--yes"], deps), /the checks failed:\s+the build failed: x/);
    assert.equal(files.get(DATA_FILE), OLD_FILE);
    assert.ok(!doing(calls).includes("deploy") && !doing(calls).some((call) => call.startsWith("commit")));
  });

  test("a failed deploy puts the old file back, so running it again redoes everything", async () => {
    const { deps, calls, files } = world({ file: OLD_FILE, versions: STORE, localizations: NOTES, deployFails: true });
    await assert.rejects(() => main(["--yes"], deps), /wrangler deploy failed/);
    assert.equal(files.get(DATA_FILE), OLD_FILE);
    assert.ok(!doing(calls).some((call) => call.startsWith("commit")));
  });

  test("answering no puts the old file back, and a file that did not exist is removed again", async () => {
    const declined = world({ file: OLD_FILE, versions: STORE, localizations: NOTES, confirm: false });
    await assert.rejects(() => main([], declined.deps), /not deployed/);
    assert.equal(declined.files.get(DATA_FILE), OLD_FILE);
    assert.ok(!doing(declined.calls).includes("deploy"));

    const fresh = world({ versions: [ascVersion("v4", "0.4")], localizations: NOTES, confirm: false });
    await assert.rejects(() => main([], fresh.deps), /not deployed/);
    assert.ok(!fresh.files.has(DATA_FILE), "no half-made file is left behind");
  });

  test("a data file that is wrong is never written over", async () => {
    const { deps, calls } = world({ file: "{broken", versions: STORE, localizations: NOTES });
    await assert.rejects(() => main(["--yes"], deps), /not good, fix it first/);
    assert.deepEqual(doing(calls), []);
  });

  test("--help prints the usage and does nothing else", async () => {
    const { deps, calls } = world();
    assert.equal(await main(["--help"], deps), 0);
    assert.deepEqual(doing(calls), []);
    assert.ok(calls[0].includes("--no-deploy"));
  });
});
