// The rules of the "What's new" page (/ios/whatsnew), apart from the page itself: how the notes of a version are split into the
// paragraphs and bullets the page draws, and which language's text a visitor gets. It has no imports and touches no page, so the
// browser loads it as /whatsnew.mjs (from whatsnew.js) and the tests load it as a plain module.
// The notes are the text App Store Connect holds as "What's New": a short summary, then bullet lines that start with "•".
// TEST:tests/whatsnew.test.mjs

/**
 * One piece of the notes of a version.
 * @typedef {{ type: "p", text: string } | { type: "ul", items: string[] }} NoteBlock
 */

/**
 * One version as the page draws it.
 * @typedef {object} ReleaseModel
 * @property {string} version The version, for example `0.4`.
 * @property {boolean} latest True for the newest version (the first of the file).
 * @property {string | null} lang The language of the text when it is not the page's (`"en"`: this version has no text in the
 *   page's language, so the English one is shown); null when the text is in the language of the page.
 * @property {NoteBlock[]} blocks The notes, ready to draw.
 */

/**
 * A bullet line: a bullet sign (`•`, the Japanese `・`, or `-` / `*` followed by a space), then the text.
 * Group 1 is the text without the sign.
 */
const BULLET = /^(?:•|・|[-*](?=\s))\s*(.*)$/;

/**
 * Splits the notes of one version into paragraphs and bullet lists.
 * A blank line ends a paragraph. Bullets that follow each other (also with blank lines between them) are one list. A text line
 * that follows a bullet line directly is the rest of that bullet (long bullets are sometimes wrapped); after a blank line it is a
 * new paragraph. The lines of a paragraph keep their line breaks (the page draws them with `white-space: pre-line`).
 * @param {string} text The notes as the App Store holds them.
 * @returns {NoteBlock[]} The blocks in order; empty for an empty text.
 */
export function parseNotes(text) {
  /** @type {NoteBlock[]} */
  const blocks = [];
  /** @type {string[] | null} The lines of the paragraph being collected. */
  let paragraph = null;
  /** @type {{ type: "ul", items: string[] } | null} The list being collected. */
  let list = null;
  // True right after a blank line: a text line then starts a new paragraph even when a list is open.
  let afterBlank = true;
  const closeParagraph = () => {
    if (paragraph) blocks.push({ type: "p", text: paragraph.join("\n") });
    paragraph = null;
  };
  for (const raw of String(text).replace(/\r\n?/g, "\n").split("\n")) {
    const line = raw.trim();
    if (line === "") {
      closeParagraph();
      afterBlank = true;
      continue;
    }
    const bullet = BULLET.exec(line);
    if (bullet) {
      closeParagraph();
      afterBlank = false;
      if (bullet[1] === "") continue; // a bullet sign with nothing after it says nothing
      if (!list) {
        list = { type: "ul", items: [] };
        blocks.push(list);
      }
      list.items.push(bullet[1]);
      continue;
    }
    if (list && !afterBlank) {
      list.items[list.items.length - 1] += ` ${line}`;
      continue;
    }
    list = null;
    (paragraph ??= []).push(line);
    afterBlank = false;
  }
  closeParagraph();
  return blocks;
}

/**
 * Chooses the text of a version for a language: the text in that language, or English when this version has none in it.
 * @param {Record<string, string>} notes The texts of one version by language code (English is always there).
 * @param {string} code The language code of the page.
 * @returns {{ text: string, lang: string | null }} The text, and `"en"` when it is the English fallback (null otherwise).
 */
export function pickNotes(notes, code) {
  const own = notes[code];
  if (typeof own === "string" && own.trim() !== "") return { text: own, lang: null };
  return { text: notes.en ?? "", lang: code === "en" ? null : "en" };
}

/**
 * Turns the data file into what the page draws.
 * @param {{ schema: number, versions: { version: string, notes: Record<string, string> }[] }} data The parsed `whatsnew-1.json`.
 * @param {string} code The language code of the page.
 * @returns {ReleaseModel[]} One model per version, in the order of the file (the newest first).
 * @throws {Error} When the data is not a file of format 1.
 */
export function releaseModels(data, code) {
  if (!data || data.schema !== 1 || !Array.isArray(data.versions)) throw new Error("not a What's new file of format 1");
  return data.versions.map((entry, index) => {
    const { text, lang } = pickNotes(entry.notes ?? {}, code);
    return { version: String(entry.version), latest: index === 0, lang, blocks: parseNotes(text) };
  });
}
