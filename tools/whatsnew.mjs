#!/usr/bin/env node
// Updates and publishes the "What's new" page of dogr.dev (/ios/whatsnew).
//
// The page draws itself in the browser from one data file, site/ios/whatsnew-1.json (newest version first, one text per language).
// This script keeps that file up to date from the App Store:
//   1. asks App Store Connect (through the `asc` command-line tool) for the released iOS versions of the app;
//   2. keeps those NEWER than the newest version already in the file (nothing newer: it says so and stops);
//   3. reads the "What's New" text of each of them in every language and adds them to the file;
//   4. checks the result (the site's tests and a test build), asks, then deploys with `npx wrangler@4 deploy`;
//   5. commits the data file locally. It never pushes.
//
// Usage (from anywhere): node tools/whatsnew.mjs [--dry-run] [--no-deploy] [--no-commit] [--yes] [--allow-dirty] [--skip-tests] [--app <id>]
// The App Store Connect key comes from ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY_PATH in the environment, or from the file
// ~/.config/dogr/testflight.json (the same file the TestFlight release script reads). It is never printed or written anywhere.
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import { UPDATE_VERSION, build, checkWhatsNew, compareVersions, whatsNewName, WHATSNEW_SCHEMA } from "../build-site.mjs";
import { LANGUAGES } from "../lang.js";
import { APP_STORE_URL } from "../app-store.js";

/** The root of the dogr repository (the folder above `tools`). */
const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));

/** Where the data file lives, relative to the repository root. */
export const DATA_FILE = `site/ios/${whatsNewName(WHATSNEW_SCHEMA)}`;

/** The file with the App Store Connect key (the same one `app-ios/Herdogr/scripts/release-testflight.py` reads). */
const KEY_FILE = "~/.config/dogr/testflight.json";

/**
 * The App Store Connect locale of each language of the site, which is how the App Store names the language of a "What's New" text.
 * Every language code of `lang.js` appears at least once (Italian under both spellings the App Store uses). TEST:tests/whatsnew.test.mjs[the App Store locales]
 * @type {Record<string, string>}
 */
export const LOCALE_TO_CODE = {
  "en-US": "en",
  "de-DE": "de",
  "es-ES": "es",
  ko: "ko",
  ja: "ja",
  "zh-Hans": "zh",
  "zh-Hant": "zh-tw",
  ru: "ru",
  "it-IT": "it",
  it: "it",
  "fr-FR": "fr",
  "pt-BR": "pt",
  tr: "tr",
};

/** The states of a version that has been on the App Store (a newer one has taken its place, or it is the one on sale). */
const RELEASED_STATES = new Set(["READY_FOR_DISTRIBUTION", "READY_FOR_SALE", "REPLACED_WITH_NEW_VERSION"]);

/**
 * Tells whether a version has been released to the public. A version in review, waiting for release or rejected has no public
 * notes yet and must not appear on the page.
 * @param {{ platform?: string, appVersionState?: string, appStoreState?: string }} attributes The `attributes` of an App Store Connect version.
 * @returns {boolean} True for an iOS version that is, or has been, on sale.
 * TEST:tests/whatsnew.test.mjs[selectNewVersions]
 */
export function isReleased(attributes) {
  if (attributes.platform !== "IOS") return false;
  return RELEASED_STATES.has(attributes.appVersionState) || RELEASED_STATES.has(attributes.appStoreState);
}

/**
 * Picks the versions the file does not have yet.
 * @param {Array<{ id: string, attributes: object }>} versions The `data` of `asc versions list`.
 * @param {string | null} last The newest version already in the file, or null for an empty file.
 * @returns {Array<{ id: string, version: string }>} The released versions newer than `last`, newest first, one entry per version number.
 * TEST:tests/whatsnew.test.mjs[selectNewVersions]
 */
export function selectNewVersions(versions, last) {
  const seen = new Set();
  const picked = [];
  for (const { id, attributes } of versions) {
    const version = attributes?.versionString;
    if (typeof version !== "string" || !UPDATE_VERSION.test(version) || seen.has(version)) continue;
    if (!isReleased(attributes)) continue;
    if (last !== null && compareVersions(version, last) <= 0) continue;
    seen.add(version);
    picked.push({ id, version });
  }
  return picked.sort((a, b) => compareVersions(b.version, a.version));
}

/**
 * Turns the localizations of one version into the `notes` object of the data file.
 * @param {Array<{ attributes: { locale?: string, whatsNew?: string | null } }>} localizations The `data` of `asc localizations list`.
 * @returns {Record<string, string>} One text per language code of the site, in the order of the language menu. A locale the site does
 *   not know, or an empty text, is left out; line endings are made `\n`.
 * TEST:tests/whatsnew.test.mjs[notesFromLocalizations]
 */
export function notesFromLocalizations(localizations) {
  const byCode = {};
  for (const { attributes } of localizations) {
    const code = LOCALE_TO_CODE[attributes?.locale];
    const text = typeof attributes?.whatsNew === "string" ? attributes.whatsNew.replace(/\r\n?/g, "\n").trim() : "";
    // The first text wins when two locales map to the same language (it-IT and it).
    if (code && text !== "" && !(code in byCode)) byCode[code] = text;
  }
  const notes = {};
  for (const { code } of LANGUAGES) if (code in byCode) notes[code] = byCode[code];
  return notes;
}

/**
 * Puts new versions in front of the ones the file already has.
 * @param {{ schema: number, versions: Array<{ version: string, notes: Record<string, string> }> }} data The file as it is.
 * @param {Array<{ version: string, notes: Record<string, string> }>} added New versions, newest first.
 * @returns {{ schema: number, versions: Array<{ version: string, notes: Record<string, string> }> }} A new object; `data` is not changed.
 * TEST:tests/whatsnew.test.mjs[mergeVersions]
 */
export function mergeVersions(data, added) {
  return { schema: data.schema, versions: [...added, ...data.versions] };
}

/**
 * The text of the data file.
 * @param {object} data The data.
 * @returns {string} Two-space JSON with a closing newline, the form the file is kept in so that a change shows as a short diff.
 */
export function serialize(data) {
  return `${JSON.stringify(data, null, 2)}\n`;
}

/**
 * The commit message for a change of the data file.
 * @param {string[]} versions The versions that were added, newest first.
 * @returns {string} For example `feat(site): add the release notes of 0.5, 0.4`.
 * TEST:tests/whatsnew.test.mjs[commitMessage]
 */
export function commitMessage(versions) {
  return `feat(site): add the release notes of ${versions.join(", ")}`;
}

/**
 * Reads the command line.
 * @param {string[]} argv The arguments after the script's name.
 * @returns {{ dryRun: boolean, noDeploy: boolean, noCommit: boolean, yes: boolean, allowDirty: boolean, skipTests: boolean, app: string | null, help: boolean }}
 *   The options; throws for an option it does not know or `--app` without a value.
 * TEST:tests/whatsnew.test.mjs[parseArgs]
 */
export function parseArgs(argv) {
  const options = { dryRun: false, noDeploy: false, noCommit: false, yes: false, allowDirty: false, skipTests: false, app: null, help: false };
  const flags = { "--dry-run": "dryRun", "--no-deploy": "noDeploy", "--no-commit": "noCommit", "--yes": "yes", "--allow-dirty": "allowDirty", "--skip-tests": "skipTests", "--help": "help", "-h": "help" };
  for (let i = 0; i < argv.length; i++) {
    const argument = argv[i];
    if (argument === "--app") {
      const value = argv[++i];
      if (!value || !/^\d+$/.test(value)) throw new Error("--app needs the numeric App Store id of the app");
      options.app = value;
    } else if (argument in flags) {
      options[flags[argument]] = true;
    } else {
      throw new Error(`unknown option ${argument} (see --help)`);
    }
  }
  return options;
}

/** What `--help` prints. */
export const HELP = `Updates and publishes https://dogr.dev/ios/whatsnew from the App Store.

  node tools/whatsnew.mjs [options]

  --dry-run      only show which versions would be added; change nothing
  --no-deploy    write and check the data file, but do not deploy
  --no-commit    do not commit the data file
  --yes          do not ask before deploying (needed when there is no terminal)
  --allow-dirty  go on although dogr has other uncommitted changes (they would be deployed too)
  --skip-tests   check only with a test build, without running the site tests
  --app <id>     the App Store id (default: ASC_APP_ID, else the one in worker.js)

The App Store Connect key is read from ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY_PATH, or from ${KEY_FILE}.
It never pushes: after it, push dogr yourself (with the owner's permission).
`;

/**
 * The id of the app on the App Store.
 * @param {{ app: string | null }} options The command-line options.
 * @param {Record<string, string | undefined>} env The environment variables.
 * @returns {string} The numeric id: `--app`, else `ASC_APP_ID`, else the id in the link the Worker redirects `/get` to.
 * TEST:tests/whatsnew.test.mjs[appId]
 */
export function appId(options, env) {
  if (options.app) return options.app;
  if (env.ASC_APP_ID && /^\d+$/.test(env.ASC_APP_ID)) return env.ASC_APP_ID;
  const fromLink = /\/id(\d+)/.exec(APP_STORE_URL)?.[1];
  if (!fromLink) throw new Error("cannot find the App Store id: pass --app <id> or set ASC_APP_ID");
  return fromLink;
}

/**
 * Reads the data file.
 * @param {string | null} text The file's text, or null when the file does not exist.
 * @returns {{ data: { schema: number, versions: Array<{ version: string, notes: Record<string, string> }> }, last: string | null }}
 *   The parsed file (an empty one when there is no file) and its newest version. A file that exists but is wrong is an error: the
 *   script must not write over something it does not understand.
 */
export function readData(text) {
  if (text === null) return { data: { schema: WHATSNEW_SCHEMA, versions: [] }, last: null };
  const problems = checkWhatsNew(text);
  if (problems.length > 0) throw new Error(`${DATA_FILE} is not good, fix it first:\n  ${problems.join("\n  ")}`);
  const data = JSON.parse(text);
  return { data, last: data.versions[0].version };
}

/**
 * The things the script does outside itself. The real ones are made by `realDeps`; the tests hand in stand-ins.
 * @typedef {object} Deps
 * @property {(args: string[]) => any} asc Runs `asc <args> --output json` and returns the parsed answer.
 * @property {(file: string) => string | null} read The text of a file in the repository, or null when it does not exist.
 * @property {(file: string, text: string) => void} write Writes a file in the repository.
 * @property {(file: string) => void} remove Deletes a file in the repository (no error when it is not there).
 * @property {() => string[]} dirty The `git status --porcelain` lines of the repository.
 * @property {() => string[]} verify Runs the checks (site tests unless skipped, then a test build); returns what is wrong, empty when fine.
 * @property {() => void} deploy Deploys the site; throws when it fails.
 * @property {(message: string, file: string) => void} commit Commits that one file locally.
 * @property {(question: string) => Promise<boolean>} confirm Asks a yes/no question.
 * @property {(line: string) => void} log Prints a line.
 * @property {Record<string, string | undefined>} env The environment variables.
 */

/**
 * Runs the whole update.
 * @param {string[]} argv The arguments after the script's name.
 * @param {Deps} deps The outside world.
 * @returns {Promise<number>} The exit status: 0 when done or nothing to do, 1 when something is wrong.
 * TEST:tests/whatsnew.test.mjs[main]
 */
export async function main(argv, deps) {
  const options = parseArgs(argv);
  const { log } = deps;
  if (options.help) {
    log(HELP);
    return 0;
  }
  const oldText = deps.read(DATA_FILE);
  const { data, last } = readData(oldText);
  log(last === null ? "The data file does not exist yet: every released version will be added." : `The page's newest version is ${last}.`);

  const id = appId(options, deps.env);
  const listed = deps.asc(["versions", "list", "--app", id, "--paginate"]);
  const fresh = selectNewVersions(listed.data ?? [], last);
  if (fresh.length === 0) {
    log(`Nothing new on the App Store (no released version after ${last ?? "the start"}).`);
    return 0;
  }
  log(`Newer released versions on the App Store: ${fresh.map((entry) => entry.version).join(", ")}.`);

  // Read the notes of each new version; a version the App Store has no English text for cannot be shown (English is what the
  // other languages fall back to), so it is skipped with a warning rather than guessed.
  const added = [];
  for (const { id: versionId, version } of fresh) {
    const localizations = deps.asc(["localizations", "list", "--version", versionId, "--paginate"]);
    const notes = notesFromLocalizations(localizations.data ?? []);
    if (!("en" in notes)) {
      log(`  ${version}: skipped, the App Store has no English "What's New" text for it.`);
      continue;
    }
    const missing = LANGUAGES.map((language) => language.code).filter((code) => !(code in notes));
    log(`  ${version}: ${Object.keys(notes).length} languages${missing.length ? `, shown in English for ${missing.join(" ")}` : ""}.`);
    added.push({ version, notes });
  }
  if (added.length === 0) {
    log("No version could be added.");
    return 0;
  }

  const merged = mergeVersions(data, added);
  const newText = serialize(merged);
  // The same rules the build applies, so that a wrong file is never written.
  const problems = checkWhatsNew(newText);
  if (problems.length > 0) throw new Error(`the new data would not pass the checks:\n  ${problems.join("\n  ")}`);

  if (options.dryRun) {
    log(`--dry-run: would add ${added.map((entry) => entry.version).join(", ")} to ${DATA_FILE}. Nothing was changed.`);
    return 0;
  }

  // A deploy publishes the whole working tree, so other uncommitted changes in dogr would go out with this update. (The commit
  // below names only the data file, so it is not affected.)
  if (!options.allowDirty && !options.noDeploy) {
    const others = deps.dirty().filter((line) => !line.endsWith(DATA_FILE));
    if (others.length > 0) {
      throw new Error(`dogr has other uncommitted changes, and a deploy would publish them too:\n  ${others.join("\n  ")}\nCommit them first, or pass --allow-dirty, or use --no-deploy.`);
    }
  }

  deps.write(DATA_FILE, newText);
  const restore = () => (oldText === null ? deps.remove(DATA_FILE) : deps.write(DATA_FILE, oldText));
  const versions = added.map((entry) => entry.version);
  try {
    const failures = deps.verify();
    if (failures.length > 0) throw new Error(`the checks failed:\n  ${failures.join("\n  ")}`);
    log("The checks pass.");

    if (!options.noDeploy) {
      if (!options.yes && !(await deps.confirm(`Deploy ${versions.join(", ")} to dogr.dev now?`))) throw new Error("not deployed (answered no)");
      deps.deploy();
      log("Deployed.");
    }
  } catch (error) {
    // Put the old file back, so that running the script again redoes the whole update (nothing is left half-done).
    restore();
    throw error;
  }

  if (!options.noCommit) {
    deps.commit(commitMessage(versions), DATA_FILE);
    log(`Committed ${DATA_FILE} (not pushed).`);
  }
  if (options.noDeploy) log("Not deployed. To publish: cd dogr && npx wrangler@4 deploy");
  log("Pushing dogr needs the owner's permission; it is not done here.");
  return 0;
}

/**
 * The App Store Connect key, as the environment variables `asc` reads.
 * @param {Record<string, string | undefined>} env The environment variables.
 * @returns {Record<string, string>} The three variables: from the environment, else from `~/.config/dogr/testflight.json`.
 */
export function keyEnvironment(env) {
  const names = ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY_PATH"];
  if (names.every((name) => env[name])) return Object.fromEntries(names.map((name) => [name, env[name]]));
  const file = KEY_FILE.replace(/^~/, homedir());
  if (!existsSync(file)) throw new Error(`set ${names.join(", ")} or create ${KEY_FILE}`);
  const config = JSON.parse(readFileSync(file, "utf8"));
  const missing = names.filter((name) => !config[name] && !env[name]);
  if (missing.length > 0) throw new Error(`${KEY_FILE} lacks ${missing.join(", ")}`);
  return Object.fromEntries(names.map((name) => [name, env[name] || config[name]]));
}

/**
 * Runs a command in the repository and waits for it.
 * @param {string} command The program.
 * @param {string[]} args Its arguments.
 * @param {{ inherit?: boolean, env?: Record<string, string | undefined> }} [options] `inherit` shows its output as it runs.
 * @returns {{ status: number, stdout: string, stderr: string }} The result.
 */
function run(command, args, { inherit = false, env = process.env } = {}) {
  const result = spawnSync(command, args, { cwd: ROOT, env, encoding: "utf8", stdio: inherit ? "inherit" : "pipe", maxBuffer: 64 * 1024 * 1024 });
  if (result.error) throw new Error(`cannot run ${command}: ${result.error.message}`);
  return { status: result.status ?? 1, stdout: result.stdout ?? "", stderr: result.stderr ?? "" };
}

/**
 * The real outside world: `asc`, the file system, git, the test run and wrangler.
 * @param {{ skipTests: boolean }} options Whether to leave out the site tests.
 * @returns {Deps} The dependencies for `main`.
 */
export function realDeps({ skipTests }) {
  const env = process.env;
  return {
    env,
    log: (line) => console.log(line),
    asc(args) {
      const result = run("asc", [...args, "--output", "json"], { env: { ...env, ...keyEnvironment(env) } });
      // Only the tool's own message is shown, never the key.
      if (result.status !== 0) throw new Error(`asc ${args.slice(0, 2).join(" ")} failed: ${result.stderr.trim().split("\n").slice(0, 3).join(" ")}`);
      return JSON.parse(result.stdout);
    },
    read(file) {
      const path = join(ROOT, file);
      return existsSync(path) ? readFileSync(path, "utf8") : null;
    },
    write(file, text) {
      writeFileSync(join(ROOT, file), text);
    },
    remove(file) {
      rmSync(join(ROOT, file), { force: true });
    },
    dirty() {
      const result = run("git", ["status", "--porcelain"]);
      if (result.status !== 0) throw new Error("git status failed");
      return result.stdout.split("\n").filter((line) => line !== "");
    },
    verify() {
      const problems = [];
      if (!skipTests) {
        const tests = readdirSync(join(ROOT, "tests")).filter((name) => name.endsWith(".test.mjs")).map((name) => join("tests", name));
        const result = run("node", ["--test", ...tests]);
        if (result.status !== 0) problems.push(`the site tests failed:\n${result.stdout.split("\n").slice(-30).join("\n")}`);
      }
      // A test build in a scratch folder: the real dist/ is built again by the deploy.
      const out = mkdtempSync(join(tmpdir(), "dogr-whatsnew-"));
      try {
        build({ outDir: out });
      } catch (error) {
        problems.push(`the build failed: ${error.message}`);
      } finally {
        rmSync(out, { recursive: true, force: true });
      }
      return problems;
    },
    deploy() {
      const result = run("npx", ["wrangler@4", "deploy"], { inherit: true });
      if (result.status !== 0) throw new Error("wrangler deploy failed");
    },
    commit(message, file) {
      // `--` limits the commit to that one file even if something else is staged.
      const add = run("git", ["add", "--", file]);
      const result = add.status === 0 ? run("git", ["commit", "-m", message, "--", file]) : add;
      if (result.status !== 0) throw new Error(`git commit failed: ${result.stderr.trim() || result.stdout.trim()}`);
    },
    async confirm(question) {
      if (!process.stdin.isTTY) throw new Error("there is no terminal to ask on: pass --yes to deploy without asking");
      const reader = createInterface({ input: process.stdin, output: process.stdout });
      try {
        return /^y(es)?$/i.test((await reader.question(`${question} [y/N] `)).trim());
      } finally {
        reader.close();
      }
    },
  };
}

// Run only when started from the command line, not when the tests import this file.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const options = parseArgs(process.argv.slice(2));
    process.exitCode = await main(process.argv.slice(2), realDeps(options));
  } catch (error) {
    console.error(`whatsnew: ${error.message}`);
    process.exitCode = 1;
  }
}
