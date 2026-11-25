// Script of the "What's new" page (/whatsnew). The page is the same in every language except for its texts; this script
// reads the data file (/whatsnew-1.json), which holds the notes of every version in every language, and draws the list for
// the language of the page. Every text goes in as plain text (textContent), never as HTML, so the data cannot add markup.
// Only the newest version is drawn open: the earlier ones are in the page but hidden until the button under the newest version is pressed.
// Without the script the page shows its own note instead of the list (the <noscript> in the template).
// The rules for splitting and choosing the text are in whatsnew.mjs (TEST:tests/whatsnew.test.mjs); this file is checked by hand
// in a browser.

import { releaseModels } from "/whatsnew.mjs";

const root = document.getElementById("releases");
/** Shows the earlier versions (a no-op when there are none or they are already shown); set by `load` once the list is drawn. */
let showEarlier = () => {};
if (root) load(root);

/**
 * Loads the data file and draws the list into the element, or says that it could not.
 * @param {HTMLElement} root The `#releases` element. Its data attributes carry the address of the file (`data-src`), the language
 *   of the page (`data-lang`) and the page's own texts for the states the script draws (`data-loading`, `data-error`, `data-latest`,
 *   `data-older`: the text of the button that shows the earlier versions).
 */
async function load(root) {
  root.replaceChildren(note(root.dataset.loading, "status"));
  try {
    // "no-cache" asks the server whether the file changed (a cheap answer when it did not), so a new version shows up at once after a deploy.
    const response = await fetch(root.dataset.src, { cache: "no-cache", headers: { accept: "application/json" } });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const releases = releaseModels(await response.json(), root.dataset.lang);
    root.replaceChildren(...layout(releases.map((release) => draw(release, root.dataset.latest)), root.dataset.older));
  } catch {
    root.replaceChildren(note(root.dataset.error, "status error"));
    return;
  }
  scrollToFragment();
}

/**
 * Puts the drawn versions in order for the page: the newest one open, and the earlier ones in a hidden group with a button
 * under it that shows them (the button then goes away). With one version only there is no group and no button.
 * @param {HTMLElement[]} articles The drawn versions, newest first.
 * @param {string} olderLabel The text of the button (the page's words for "Show earlier versions").
 * @returns {HTMLElement[]} What goes into the page, in order.
 */
function layout(articles, olderLabel) {
  const [newest, ...earlier] = articles;
  if (!newest || earlier.length === 0) return articles;
  const group = document.createElement("div");
  group.id = "earlier";
  group.hidden = true;
  group.append(...earlier);
  const button = document.createElement("button");
  button.type = "button";
  button.className = "btn ghost more";
  button.textContent = olderLabel;
  button.setAttribute("aria-controls", group.id);
  button.setAttribute("aria-expanded", "false");
  showEarlier = () => {
    group.hidden = false;
    button.remove();
  };
  button.addEventListener("click", showEarlier);
  return [newest, group, button];
}

/**
 * Scrolls to the version named in the address (`#v0.4`). The page had no content when the browser looked for the fragment, so
 * this does it once the list is drawn. A version among the hidden earlier ones is shown first, so a link to it works. A
 * fragment that is not valid text or names nothing is ignored.
 */
function scrollToFragment() {
  try {
    const target = location.hash.length > 1 ? document.getElementById(decodeURIComponent(location.hash.slice(1))) : null;
    if (target?.closest("[hidden]")) showEarlier();
    if (target) target.scrollIntoView();
  } catch {
    // A broken fragment (for example a lone %) is not worth an error message on the page.
  }
}

/**
 * A paragraph with a text that is the same in every case (a state of the page).
 * @param {string} text The text.
 * @param {string} className The class of the paragraph.
 * @returns {HTMLParagraphElement} The paragraph.
 */
function note(text, className) {
  const paragraph = document.createElement("p");
  paragraph.className = className;
  paragraph.textContent = text;
  return paragraph;
}

/**
 * Draws one version: its number (with a mark on the newest) and its notes.
 * @param {import("/whatsnew.mjs").ReleaseModel} release The version.
 * @param {string} latestLabel The page's word for "Latest", shown beside the newest version.
 * @returns {HTMLElement} The `<article>` of the version; its `id` is `v<version>`, so `#v0.4` links to it.
 */
function draw(release, latestLabel) {
  const article = document.createElement("article");
  article.className = "release";
  article.id = `v${release.version}`;
  const heading = document.createElement("h2");
  const link = document.createElement("a");
  link.href = `#${article.id}`;
  link.textContent = `v${release.version}`;
  heading.append(link);
  if (release.latest) {
    const mark = document.createElement("span");
    mark.className = "latest";
    mark.textContent = latestLabel;
    heading.append(mark);
  }
  const body = document.createElement("div");
  body.className = "notes";
  // A version without a text in the page's language shows the English one, marked as such for screen readers and fonts.
  if (release.lang) body.lang = release.lang;
  for (const block of release.blocks) {
    if (block.type === "p") {
      body.append(note(block.text, block === release.blocks[0] ? "summary" : "para"));
    } else {
      const list = document.createElement("ul");
      for (const item of block.items) {
        const entry = document.createElement("li");
        entry.textContent = item;
        list.append(entry);
      }
      body.append(list);
    }
  }
  article.append(heading, body);
  return article;
}
