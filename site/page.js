// Script of the dogr.dev home page. The page works without it: the command can be selected by hand, and the language menu is a
// plain <details> that lists English and the language of the page as ordinary links. This script only adds three small things:
//   1. the Copy button of the install command,
//   2. the languages that are likely for this visitor, added to the language menu when it is opened: the browser's language
//      and the one guessed from the country (the menu never lists the other languages),
//   3. a cookie that remembers a language, written only when the visitor clicks one in the menu.
// It loads nothing from other sites. The country guess is asked from this site's own Worker (/_geo), and only when the menu is opened.
// TEST:tests/site.test.mjs covers the rules in lang.js; this file is checked by hand in a browser.

import { COOKIE_NAME, LANGUAGES, isCode, matchTag } from "/lang.js";

// ---------- 1. Copy button ----------
document.querySelectorAll("[data-copy]").forEach((button) => {
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(button.dataset.copy);
      const label = button.textContent;
      button.textContent = button.dataset.copied || label;
      setTimeout(() => { button.textContent = label; }, 1600);
    } catch {
      // Clipboard blocked: nothing to do; the command is still on the page to select.
    }
  });
});

// ---------- 2 and 3. Language menu ----------
const menu = document.querySelector("details.lang");
if (menu) setUpLanguageMenu(menu);

/**
 * Wires the language menu.
 * @param {HTMLDetailsElement} menu The `<details class="lang">` element.
 */
function setUpLanguageMenu(menu) {
  const list = menu.querySelector("ul");
  let asked = false;

  // Any click on a language link remembers the choice, so the root address stops guessing for this visitor.
  menu.addEventListener("click", (event) => {
    const link = event.target.closest("a[data-code]");
    if (link && isCode(link.dataset.code)) remember(link.dataset.code);
  });

  // Close the menu on a click elsewhere and on Escape.
  document.addEventListener("click", (event) => {
    if (menu.open && !menu.contains(event.target)) menu.open = false;
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && menu.open) {
      menu.open = false;
      menu.querySelector("summary").focus();
    }
  });

  // The likely languages are added the first time the menu opens, so a visitor who never opens it costs the Worker nothing.
  // The page already lists English and its own language; a language that is listed is never added twice.
  menu.addEventListener("toggle", () => {
    if (!menu.open || asked) return;
    asked = true;
    add(browserLanguage());
    fetch("/_geo", { credentials: "omit", cache: "no-store" })
      .then((answer) => (answer.ok ? answer.json() : null))
      .then((data) => add(data && isCode(data.language) ? data.language : null))
      .catch(() => { /* No guess from the country: the list stands as it is. */ });
  });

  /**
   * Adds one language to the end of the list, unless it is not a language of this site or is already listed.
   * @param {string | null} code Language code, or null for nothing to add.
   */
  function add(code) {
    if (!code || list.querySelector(`a[data-code="${code}"]`)) return;
    const language = LANGUAGES.find((candidate) => candidate.code === code);
    if (!language) return;
    const link = document.createElement("a");
    link.href = `/${code}/`;
    link.lang = language.html;
    link.hreflang = language.html;
    link.dataset.code = code;
    link.textContent = language.name;
    const entry = document.createElement("li");
    entry.append(link);
    list.append(entry);
  }
}

/**
 * The first language the browser asks for that this site has, other than English (English is always in the list).
 * @returns {string | null} A language code, or null.
 */
function browserLanguage() {
  for (const tag of navigator.languages || [navigator.language]) {
    const code = matchTag(tag || "");
    if (code && code !== "en") return code;
    if (code === "en") return null; // English first in the browser's list: nothing to suggest besides English itself.
  }
  return null;
}

/**
 * Remembers a language for a year. Only the code is stored, and only because the visitor picked it.
 * @param {string} code Language code.
 */
function remember(code) {
  const secure = location.protocol === "https:" ? "; Secure" : "";
  document.cookie = `${COOKIE_NAME}=${code}; Path=/; Max-Age=31536000; SameSite=Lax${secure}`;
}
