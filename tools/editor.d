/// editor, the tool that serves the book's notes for editing and writes what
/// you type back into the comment it came from.
///
/// The page is built from the cases, not from the printed sheets: the bound
/// copy is a photograph of a typesetting and has nowhere to put a cursor.
/// Nothing here remembers a line number. A note is found again, at the moment
/// you save it, by what it says.

import std.file : dirEntries, readText, write, SpanMode, exists;
import std.algorithm : sort;
import std.array : array, join;
import std.path : baseName;
import std.stdio : stderr;
import std.socket;
import std.conv : to;

import cases : extractCases, Case, splitLines;
import concept : conceptOf;
import edit : rewriteCase, Was, ending;
import fmt : formatInto;

enum PORT = 7777;

// A row is one case: what was said above it, the note beside it, and the
// example. All three are the author's to change.
struct Row {
    string file;
    string chapter;
    string said;
    string prose;
    string pbt;
}

Row[] gather() {
    Row[] rows;

    auto files = dirEntries("source", "*.d", SpanMode.shallow)
        .array
        .sort!((a, b) => a.name < b.name);

    foreach (f; files) {
        foreach (c; extractCases(readText(f.name))) {
            if (c.heading || c.pbt.length == 0) continue;
            auto ch = conceptOf(c.pbt);
            if (ch.length == 0) continue;
            rows ~= Row(baseName(f.name), ch, c.said, c.prose, c.pbt);
        }
    }
    return rows;
}

void main() {
    if (!exists("source")) {
        stderr.writeln("editor: no source/ here");
        return;
    }

    auto listener = new TcpSocket();
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    listener.bind(new InternetAddress("127.0.0.1", PORT));
    listener.listen(8);

    stderr.writefln("http://127.0.0.1:%d", PORT);

    while (true) {
        auto conn = listener.accept();
        scope (exit) { conn.shutdown(SocketShutdown.BOTH); conn.close(); }

        // A write that throws is said to the page that asked, and the editor
        // stays up for the next one. It used to take the process down, and
        // every save after it went nowhere.
        try {
            auto req = receiveRequest(conn);
            if (req.length == 0) continue;

            if (startsWith(req, "POST /save")) {
                auto said = save(afterHeaders(req));
                respond(conn, statusOf(said), "text/plain", said);
                continue;
            }
            if (startsWith(req, "POST /fmt")) {
                respond(conn, 200, "text/plain", setPbt(afterHeaders(req)));
                continue;
            }
            respond(conn, 200, "text/html; charset=utf-8", page(gather()));
        } catch (Exception e) {
            stderr.writeln("editor: ", e.msg);
            respond(conn, 500, "text/plain", "not saved: " ~ e.msg);
        }
    }
}

// The whole request. One receive is one packet, and a note longer than that
// arrived cut short and was refused as a malformed save.
string receiveRequest(Socket conn) {
    char[65536] buf;
    string req;
    while (true) {
        auto n = conn.receive(buf[]);
        if (n <= 0) return req;
        req ~= buf[0 .. n];
        auto head = headerEnd(req);
        if (head < 0) continue;
        if (req.length >= head + contentLength(req)) return req;
    }
}

// Where the body starts, or -1 while the headers have not all arrived.
ptrdiff_t headerEnd(string req) {
    foreach (i; 0 .. req.length > 3 ? req.length - 3 : 0)
        if (req[i .. i + 4] == "\r\n\r\n") return i + 4;
    return -1;
}

// The length the browser declared for the body. Header names are not cased.
size_t contentLength(string req) {
    enum name = "content-length:";
    foreach (i; 0 .. req.length > name.length ? req.length - name.length : 0) {
        bool same = true;
        foreach (j, c; name) {
            char r = req[i + j];
            if (r >= 'A' && r <= 'Z') r = cast(char)(r + 32);
            if (r != c) { same = false; break; }
        }
        if (!same) continue;
        size_t k = i + name.length;
        while (k < req.length && req[k] == ' ') k++;
        size_t len = 0;
        while (k < req.length && req[k] >= '0' && req[k] <= '9') len = len * 10 + (req[k++] - '0');
        return len;
    }
    return 0;
}

// Only a write, or nothing to write, is a 200. What fetch can tell apart
// without reading the words is what the page can never mistake for saved.
int statusOf(string said) {
    if (startsWith(said, "saved") || said == "unchanged") return 200;
    if (said == "malformed save") return 400;
    if (startsWith(said, "no ")) return 404;
    return 409;
}

// "i expect there to be a small fmt button in, lets say a footerbar, where save should also be"
// The example in the one layout, or the text as it was when fmt cannot read it.
string setPbt(string pbt) {
    auto buf = new char[](65536);
    auto n = formatInto(pbt ~ "\n", buf);
    if (n < 0) return pbt;
    auto set = buf[0 .. cast(size_t) n];
    if (set.length > 0 && set[$ - 1] == '\n') set = set[0 .. $ - 1];
    return set.idup;
}

// What the browser sent back: the file and the case as it was and as it is
// now, each field length-prefixed, because a note carries newlines and quotes
// and every separator is in the text itself.
string save(string body_) {
    auto parts = unpack(body_);
    if (parts.length != 7) return "malformed save";

    auto file = "source/" ~ baseName(parts[0]);
    auto was = Was(parts[1], parts[2], parts[3]);
    auto now = Was(parts[4], parts[5], parts[6]);

    if (!exists(file)) return "no " ~ file;
    if (was == now) return "unchanged";

    auto text = readText(file);
    auto lines = splitLines(text);
    auto out_ = rewriteCase(lines, was, now);
    if (out_ == lines)
        return baseName(file) ~ " moved on";

    write(file, join(out_, "\n") ~ ending(text));
    return "saved to " ~ baseName(file);
}

// Fields as `<length>:<bytes>`, so nothing in a note can be read as a
// separator. Form encoding would have to escape prose that is already prose.
string[] unpack(string s) {
    string[] out_;
    size_t i = 0;
    while (i < s.length) {
        size_t j = i;
        while (j < s.length && s[j] != ':') j++;
        if (j >= s.length) break;

        size_t len = 0;
        foreach (c; s[i .. j]) {
            if (c < '0' || c > '9') return out_;
            len = len * 10 + (c - '0');
        }
        j++;
        if (j + len > s.length) break;
        out_ ~= s[j .. j + len];
        i = j + len;
    }
    return out_;
}

void respond(Socket conn, int status, string type, string body_) {
    auto head = "HTTP/1.1 " ~ to!string(status) ~ " " ~ (status == 200 ? "OK" : "Not Saved")
              ~ "\r\nContent-Type: " ~ type
              ~ "\r\nContent-Length: " ~ to!string(body_.length)
              ~ "\r\nConnection: close\r\n\r\n";
    conn.send(head);
    conn.send(body_);
}

string afterHeaders(string req) {
    auto head = headerEnd(req);
    return head < 0 ? "" : req[head .. $];
}

bool startsWith(string s, string p) {
    return s.length >= p.length && s[0 .. p.length] == p;
}

string esc(string s) {
    string out_;
    foreach (c; s) {
        if (c == '&')  { out_ ~= "&amp;";  continue; }
        if (c == '<')  { out_ ~= "&lt;";   continue; }
        if (c == '>')  { out_ ~= "&gt;";   continue; }
        if (c == '"')  { out_ ~= "&quot;"; continue; }
        out_ ~= c;
    }
    return out_;
}

// "i dont want to think about anything else than the task of authoring"
// A row: the quotes above, the example on the left, the note on the right,
// and a footer bar with fmt and save. Nothing on the page but the cases.
string page(Row[] rows) {
    string body_;

    foreach (i, r; rows) {
        auto id = to!string(i);
        body_ ~= "<div class=\"case\" id=\"c" ~ id ~ "\">\n";
        body_ ~= "<span class=\"file\">" ~ esc(r.file) ~ "</span>\n";
        body_ ~= "<span class=\"state\" id=\"s" ~ id ~ "\"></span>\n";
        body_ ~= "<textarea class=\"said\" id=\"q" ~ id ~ "\">" ~ esc(r.said) ~ "</textarea>\n";
        body_ ~= "<div class=\"row\">\n";
        body_ ~= "<textarea class=\"pbt\" id=\"p" ~ id ~ "\">" ~ esc(r.pbt) ~ "</textarea>\n";
        body_ ~= "<textarea class=\"prose\" id=\"t" ~ id ~ "\">" ~ esc(r.prose) ~ "</textarea>\n";
        body_ ~= "</div>\n";
        body_ ~= "<script>W[" ~ id ~ "]=" ~ jsString(r.file)
               ~ ";O[" ~ id ~ "]=[" ~ jsString(r.said) ~ "," ~ jsString(r.prose) ~ "," ~ jsString(r.pbt) ~ "];</script>\n";
        body_ ~= "</div>\n";
    }

    return HEAD ~ STRAYS ~ body_ ~ FOOT ~ TAIL;
}

// A D string as a JavaScript one. The notes carry quotes and backslashes, and
// one unescaped quote would take the whole page down rather than one row.
string jsString(string s) {
    string out_ = "\"";
    foreach (c; s) {
        if (c == '\\') { out_ ~= "\\\\"; continue; }
        if (c == '"')  { out_ ~= "\\\""; continue; }
        if (c == '\n') { out_ ~= "\\n";  continue; }
        if (c == '\r') continue;
        out_ ~= c;
    }
    return out_ ~ "\"";
}

enum HEAD = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>author</title>
<style>
` ~ import("tokens.css") ~ import("author.css") ~ `</style></head><body>
<script>` ~ PAGE_SCRIPT ~ `</script>
`;

// "i would have stopped, and fix it first, instead the system lies to me"
// A case is in one of three states and each looks like itself: unsaved, saved
// because the editor said it wrote the comment, or failed with the reason.
// "so i can even use it offline"
// What is typed goes into this browser first. It leaves only once a save has
// landed, so an editor that is down, dead or restarted loses nothing.
enum PAGE_SCRIPT = `var W = {}, O = {}, sel = -1;
function field(s) { return s.length + ":" + s; }
function el(id) { return document.getElementById(id); }
function read(i) { return [el("q" + i).value, el("t" + i).value, el("p" + i).value]; }
function same(a, b) { return a[0] === b[0] && a[1] === b[1] && a[2] === b[2]; }
function section(i) { return el("c" + i); }
function status(m, failed) {
  var s = el("status");
  s.textContent = m;
  s.className = failed ? "status failed" : "status";
}
function select(i) {
  if (sel >= 0) section(sel).classList.remove("on");
  sel = i;
  section(i).classList.add("on");
}
function mark(i, state, m) {
  var c = section(i);
  c.classList.remove("unsaved", "saved", "failed");
  if (state) c.classList.add(state);
  el("s" + i).textContent = m;
}
// A draft is keyed by the case as the source had it, so it is found again on
// the next load for as long as the source still says that.
function key(i) { return "author:" + JSON.stringify([W[i], O[i]]); }
function keep(i) {
  try {
    if (same(read(i), O[i])) localStorage.removeItem(key(i));
    else localStorage.setItem(key(i), JSON.stringify(read(i)));
  } catch (e) {
    mark(i, "failed", "this browser would not keep the draft: " + e.message);
    status("a draft is only on this page: " + e.message, true);
  }
}
function edited(i) {
  keep(i);
  if (same(read(i), O[i])) mark(i, "", "");
  else if (!section(i).classList.contains("failed")) mark(i, "unsaved", "unsaved");
}
function pending() {
  var p = [];
  for (var i in O) if (!same(read(i), O[i])) p.push(parseInt(i, 10));
  return p;
}
function saveOne(i) {
  var n = read(i), o = O[i];
  var b = field(W[i]) + field(o[0]) + field(o[1]) + field(o[2]) + field(n[0]) + field(n[1]) + field(n[2]);
  return fetch("/save", { method: "POST", body: b })
    .then(function (r) { return r.text().then(function (m) { return { ok: r.ok, m: m }; }); })
    .then(function (a) {
      if (!a.ok) { mark(i, "failed", "not saved: " + a.m); return false; }
      try { localStorage.removeItem(key(i)); } catch (e) {}
      O[i] = n;
      keep(i);
      mark(i, "saved", a.m);
      return true;
    })
    .catch(function (e) {
      mark(i, "failed", "not saved: the editor did not answer (" + e.message + "). The draft is kept in this browser.");
      return false;
    });
}
// Every case carrying an edit, not only the one being written in.
function save() {
  var p = pending();
  if (p.length === 0) { status("nothing to save"); return; }
  status("saving " + p.length);
  var failed = 0, chain = Promise.resolve();
  p.forEach(function (i) {
    chain = chain.then(function () { return saveOne(i).then(function (ok) { if (!ok) failed++; }); });
  });
  chain.then(function () {
    if (failed > 0) status(failed + " of " + p.length + " not saved", true);
    else status("saved " + p.length);
  });
}
function fmt() {
  if (sel < 0) { status("select a case to fmt", true); return; }
  var i = sel, p = el("p" + i);
  fetch("/fmt", { method: "POST", body: p.value })
    .then(function (r) { if (!r.ok) throw new Error("status " + r.status); return r.text(); })
    .then(function (m) { p.value = m; fit(p); edited(i); status("fmt"); })
    .catch(function (e) { status("fmt did not run: the editor did not answer (" + e.message + ")", true); });
}
function fit(t) { t.style.height = "auto"; t.style.height = t.scrollHeight + "px"; }
// Drafts come back into the case they were written in. One whose case the
// source no longer has is shown whole, never dropped.
function restore() {
  var claimed = {};
  for (var i in O) {
    try {
      var d = localStorage.getItem(key(i));
      claimed[key(i)] = true;
      if (!d) continue;
      d = JSON.parse(d);
      el("q" + i).value = d[0]; el("t" + i).value = d[1]; el("p" + i).value = d[2];
      mark(i, "unsaved", "unsaved, kept in this browser");
    } catch (e) {
      status("drafts in this browser could not be read: " + e.message, true);
      return;
    }
  }
  var strays = [];
  try {
    for (var k = 0; k < localStorage.length; k++) {
      var name = localStorage.key(k);
      if (name.indexOf("author:") === 0 && !claimed[name])
        strays.push(JSON.parse(name.substring(7))[0] + "\n\n" + JSON.parse(localStorage.getItem(name)).join("\n\n"));
    }
  } catch (e) {
    status("drafts in this browser could not be read: " + e.message, true);
    return;
  }
  if (strays.length > 0) {
    el("strays").hidden = false;
    el("strays-text").textContent = strays.join("\n\n----\n\n");
    status(strays.length + " draft(s) no longer match a case, shown at the top", true);
  }
}
// "can we take command+s ? for save?"
document.addEventListener("keydown", function (e) {
  if ((e.metaKey || e.ctrlKey) && e.key === "s") { e.preventDefault(); save(); }
});
window.addEventListener("beforeunload", function (e) {
  if (pending().length > 0) { e.preventDefault(); e.returnValue = ""; }
});
document.addEventListener("DOMContentLoaded", function () {
  restore();
  var all = document.querySelectorAll("textarea");
  for (var k = 0; k < all.length; k++) {
    fit(all[k]);
    var i = parseInt(all[k].id.substring(1), 10);
    all[k].addEventListener("input", (function (i) { return function (e) { fit(e.target); edited(i); }; })(i));
    all[k].addEventListener("focus", (function (i) { return function () { select(i); }; })(i));
  }
});
`;

// Drafts this browser holds for a case the source no longer has.
enum STRAYS = `<div class="strays" id="strays" hidden><span class="state">drafts that no longer match a case</span><pre id="strays-text"></pre></div>
`;

// One footer bar for the page: fmt and save act on the section being
// written in.
enum FOOT = `<div class="foot"><button onclick="fmt()">fmt</button><button onclick="save()">save</button><span class="status" id="status"></span></div>
`;

enum TAIL = "</body></html>\n";
