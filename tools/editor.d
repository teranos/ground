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

        char[65536] buf;
        auto n = conn.receive(buf[]);
        if (n <= 0) continue;
        auto req = cast(string) buf[0 .. n].idup;

        if (startsWith(req, "POST /save")) {
            auto body_ = afterHeaders(req);
            respond(conn, "text/plain", save(body_));
            continue;
        }
        if (startsWith(req, "POST /fmt")) {
            auto body_ = afterHeaders(req);
            respond(conn, "text/plain", setPbt(body_));
            continue;
        }
        respond(conn, "text/html; charset=utf-8", page(gather()));
    }
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

void respond(Socket conn, string type, string body_) {
    auto head = "HTTP/1.1 200 OK\r\nContent-Type: " ~ type
              ~ "\r\nContent-Length: " ~ to!string(body_.length)
              ~ "\r\nConnection: close\r\n\r\n";
    conn.send(head);
    conn.send(body_);
}

string afterHeaders(string req) {
    foreach (i; 0 .. req.length > 3 ? req.length - 3 : 0)
        if (req[i .. i + 4] == "\r\n\r\n") return req[i + 4 .. $];
    return "";
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
        body_ ~= "<textarea class=\"said\" id=\"q" ~ id ~ "\">" ~ esc(r.said) ~ "</textarea>\n";
        body_ ~= "<div class=\"row\">\n";
        body_ ~= "<textarea class=\"pbt\" id=\"p" ~ id ~ "\">" ~ esc(r.pbt) ~ "</textarea>\n";
        body_ ~= "<textarea class=\"prose\" id=\"t" ~ id ~ "\">" ~ esc(r.prose) ~ "</textarea>\n";
        body_ ~= "</div>\n";
        body_ ~= "<script>W[" ~ id ~ "]=" ~ jsString(r.file)
               ~ ";O[" ~ id ~ "]=[" ~ jsString(r.said) ~ "," ~ jsString(r.prose) ~ "," ~ jsString(r.pbt) ~ "];</script>\n";
        body_ ~= "</div>\n";
    }

    return HEAD ~ body_ ~ FOOT ~ TAIL;
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
<script>var W = {}, O = {}, sel = -1;
function field(s) { return s.length + ":" + s; }
function read(i) {
  return [document.getElementById("q" + i).value,
          document.getElementById("t" + i).value,
          document.getElementById("p" + i).value];
}
function same(a, b) { return a[0] === b[0] && a[1] === b[1] && a[2] === b[2]; }
function section(i) { return document.getElementById("c" + i); }
function status(m) { document.getElementById("status").textContent = m; }
function select(i) {
  if (sel >= 0) section(sel).classList.remove("on");
  sel = i;
  section(i).classList.add("on");
}
function dirty(i) { section(i).classList.toggle("dirty", !same(read(i), O[i])); }
function save() {
  if (sel < 0) return;
  var i = sel, n = read(i), o = O[i], f = W[i];
  var b = field(f) + field(o[0]) + field(o[1]) + field(o[2]) + field(n[0]) + field(n[1]) + field(n[2]);
  fetch("/save", { method: "POST", body: b })
    .then(function (r) { return r.text(); })
    .then(function (m) {
      status(m);
      if (m.indexOf("saved") === 0) { O[i] = n; dirty(i); }
    });
}
function fmt() {
  if (sel < 0) return;
  var i = sel, p = document.getElementById("p" + i);
  fetch("/fmt", { method: "POST", body: p.value })
    .then(function (r) { return r.text(); })
    .then(function (m) { p.value = m; fit(p); dirty(i); });
}
function fit(t) { t.style.height = "auto"; t.style.height = t.scrollHeight + "px"; }
document.addEventListener("DOMContentLoaded", function () {
  var all = document.querySelectorAll("textarea");
  for (var k = 0; k < all.length; k++) {
    fit(all[k]);
    var i = parseInt(all[k].id.substring(1), 10);
    all[k].addEventListener("input", (function (i) { return function (e) { fit(e.target); dirty(i); }; })(i));
    all[k].addEventListener("focus", (function (i) { return function () { select(i); }; })(i));
  }
});
</script>
`;

// One footer bar for the page: fmt and save act on the section being
// written in.
enum FOOT = `<div class="foot"><button onclick="fmt()">fmt</button><button onclick="save()">save</button><span class="status" id="status"></span></div>
`;

enum TAIL = "</body></html>\n";
