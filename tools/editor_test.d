module editor_test;

// CTFE tests — failure shows as a compile error.

// "i would have stopped, and fix it first, instead the system lies to me"
// "resolved/failed/neutral all have the same state"

import editor : statusOf, contentLength, PAGE_SCRIPT;

// Only a write is a 200. Every other answer is one the page must show as a
// failure, and a status is what fetch can tell apart without reading prose.
static assert(statusOf("saved to hooks.d") == 200);
static assert(statusOf("unchanged") == 200);
static assert(statusOf("hooks.d moved on") == 409);
static assert(statusOf("no source/x.d") == 404);
static assert(statusOf("malformed save") == 400);

// A note longer than one packet arrived cut short and was refused as malformed.
// The body is read to the length the browser declared.
static assert(contentLength("POST /save HTTP/1.1\r\nContent-Length: 70000\r\n\r\n") == 70000);
static assert(contentLength("POST /save HTTP/1.1\r\ncontent-length: 12\r\nHost: x\r\n\r\n") == 12);
static assert(contentLength("GET / HTTP/1.1\r\n\r\n") == 0);

// An editor nobody is listening to is a failure on the page, not silence.
static assert(has(PAGE_SCRIPT, ".catch("));
static assert(has(PAGE_SCRIPT, "r.ok"));

// "so i can even use it offline"
// What is typed is in the browser before it is anywhere else.
static assert(has(PAGE_SCRIPT, "localStorage"));

// "can we take command+s ? for save?"
// The keystroke saves instead of asking the browser to save the page.
static assert(has(PAGE_SCRIPT, `e.key === "s"`));
static assert(has(PAGE_SCRIPT, "e.metaKey"));

// "i want the old text to always be there and the new text left of it, on save the old text should be replaced with the new"
// "empty, but the old one needs to be copyable easily by just clicking on it"
// "i was talking about the quotes"
import editor : page, Row;
enum onePage = page([Row("x_test.d", "ritual", `"said"`, "a note", "project {\n}")]);
static assert(has(onePage, `<textarea class="said new" id="q0" autocomplete="off"></textarea>`));
static assert(has(onePage, `<textarea class="said old" id="oq0" autocomplete="off" readonly>&quot;said&quot;</textarea>`));
// "and when clicing on the old , i want it to set it to the new, so i can edit fast and save"
static assert(has(PAGE_SCRIPT, `el("q" + i).value = O[i][0];`));
static assert(!has(PAGE_SCRIPT, "clipboard"));

// The example and the note are written over in place, as they always were.
static assert(has(onePage, `<textarea class="pbt" id="p0" autocomplete="off">project {` ~ "\n" ~ `}</textarea>`));
static assert(has(onePage, `<textarea class="prose" id="t0" autocomplete="off">a note</textarea>`));

// A reload put back what each box held before, by position, so a page that
// gained a box showed one case's example in another case's quotes.

// Quotes left empty are quotes kept. The rest is saved as it was typed.
import edit : Was, kept;
static assert(kept(Was("q", "n", "p"), Was("", "N", "P")) == Was("q", "N", "P"));
static assert(kept(Was("q", "n", "p"), Was("Q", "n", "p")) == Was("Q", "n", "p"));

private bool has(string s, string n) {
    if (n.length > s.length) return false;
    foreach (i; 0 .. s.length - n.length + 1)
        if (s[i .. i + n.length] == n) return true;
    return false;
}
