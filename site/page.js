// Script of the dogr.dev home page. The page works without it: the command can be selected by hand, and the language menu is a
// plain <details> that lists every language as an ordinary link. This script only adds three small things:
//   1. the Copy button of the install command,
//   2. a "Suggested" part at the top of the language menu (the browser's language, a guess from the country, and English),
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
  const current = menu.dataset.current;
  const suggestBox = menu.querySelector(".suggest");
  const suggestList = suggestBox.querySelector("ul");
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

  // The suggestions are built the first time the menu opens, so a visitor who never opens it costs the Worker nothing.
  menu.addEventListener("toggle", () => {
    if (!menu.open || asked) return;
    asked = true;
    show(browserLanguage(), null);
    fetch("/_geo", { credentials: "omit", cache: "no-store" })
      .then((answer) => (answer.ok ? answer.json() : null))
      .then((data) => show(browserLanguage(), data && isCode(data.language) ? data.language : null))
      .catch(() => { /* No guess from the country: the rest of the list stands. */ });
  });

  /**
   * Fills the "Suggested" part: the browser's language, the guess from the country, then English, each once and never the
   * language this page is already in.
   * @param {string | null} browser Code of the first language of the browser that we have, if it is not English or the current one.
   * @param {string | null} country Code guessed from the country, or null.
   */
  function show(browser, country) {
    const codes = [];
    for (const code of [browser, country, "en"]) {
      if (code && code !== current && !codes.includes(code)) codes.push(code);
    }
    suggestList.replaceChildren(...codes.map(item));
    suggestBox.hidden = codes.length === 0;
  }

  /**
   * Makes one list item for a language.
   * @param {string} code Language code.
   * @returns {HTMLLIElement} The item with its link.
   */
  function item(code) {
    const language = LANGUAGES.find((candidate) => candidate.code === code);
    const link = document.createElement("a");
    link.href = `/${code}/`;
    link.lang = language.html;
    link.hreflang = language.html;
    link.dataset.code = code;
    link.textContent = language.name;
    const entry = document.createElement("li");
    entry.append(link);
    return entry;
  }
}

/**
 * The first language the browser asks for that this site has, other than English (English is always offered separately).
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
