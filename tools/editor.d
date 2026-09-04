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
import edit : rewriteProse, runSaying, ending;

enum PORT = 7777;

struct Row {
    string file;
    string chapter;
    string pbt;
    string prose;
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
            rows ~= Row(baseName(f.name), ch, c.pbt, c.prose);
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

    stderr.writefln("editor: http://127.0.0.1:%d — the notes, editable", PORT);

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
        respond(conn, "text/html; charset=utf-8", page(gather()));
    }
}

// What the browser sent back: three fields, each length-prefixed, because a
// note carries newlines and quotes and every separator is in the text itself.
string save(string body_) {
    auto parts = unpack(body_);
    if (parts.length != 3) return "editor: malformed save";

    auto file = "source/" ~ baseName(parts[0]);
    auto was = parts[1];
    auto now = parts[2];

    if (!exists(file)) return "editor: no " ~ file;
    if (was == now) return "unchanged";

    auto text = readText(file);
    auto lines = splitLines(text);
    if (!runSaying(lines, was).found)
        return "editor: " ~ baseName(file) ~ " no longer says that — reload";

    write(file, join(rewriteProse(lines, was, now), "\n") ~ ending(text));
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

string page(Row[] rows) {
    string body_;
    string current;

    size_t writable = 0;
    foreach (i, r; rows) {
        if (r.chapter != current) {
            current = r.chapter;
            body_ ~= "<h2>" ~ esc(current) ~ "</h2>\n";
        }

        auto id = to!string(i);
        body_ ~= "<div class=\"row\">\n";
        body_ ~= "<pre>" ~ esc(r.pbt) ~ "</pre>\n";
        body_ ~= "<div class=\"side\">\n";

        if (r.prose.length > 0) {
            writable++;
            body_ ~= "<textarea id=\"t" ~ id ~ "\">" ~ esc(r.prose) ~ "</textarea>\n";
            body_ ~= "<button onclick=\"save(" ~ id ~ ")\">Save</button>\n";
            body_ ~= "<span class=\"said\" id=\"s" ~ id ~ "\"></span>\n";
            body_ ~= "<script>W[" ~ id ~ "]=" ~ jsString(r.file)
                   ~ ";O[" ~ id ~ "]=" ~ jsString(r.prose) ~ ";</script>\n";
        } else {
            body_ ~= "<p class=\"none\">No note. Nothing to find this row by yet, "
                   ~ "so it is written in " ~ esc(r.file) ~ " by hand.</p>\n";
        }

        body_ ~= "</div>\n</div>\n";
    }

    return HEAD
         ~ "<p class=\"count\">" ~ to!string(writable) ~ " of "
         ~ to!string(rows.length) ~ " rows carry a note.</p>\n"
         ~ body_ ~ TAIL;
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
<title>Book of Ground — notes</title>
<style>
body { font: 15px/1.5 Charter, Georgia, serif; margin: 0; padding: 2rem 3rem 6rem;
       background: #f6f5f2; color: #1a1a1a; }
h1 { font-size: 1.6rem; font-weight: 400; font-variant: small-caps; }
h2 { font-variant: small-caps; letter-spacing: .04em; font-weight: 400;
     border-bottom: 1px solid #cfcdc7; padding-bottom: .2rem; margin-top: 2.5rem; }
p.count { color: #6b6b63; font-size: .85rem; }
div.row { display: flex; gap: 1.5rem; align-items: flex-start; margin: 1.2rem 0;
          padding-bottom: 1.2rem; border-bottom: 1px solid #e6e4de; }
pre { flex: 0 0 52%; margin: 0; padding: .8rem 1rem; background: #fff;
      border-left: 2px solid #cfcdc7; font: 12px/1.45 "Fira Code", Menlo, monospace;
      overflow-x: auto; }
div.side { flex: 1; }
textarea { width: 100%; min-height: 5.5rem; font: 14px/1.5 Charter, Georgia, serif;
           padding: .5rem; border: 1px solid #cfcdc7; background: #fff; resize: vertical; }
button { margin-top: .4rem; font: inherit; font-size: .85rem; padding: .2rem .8rem;
         border: 1px solid #cfcdc7; background: #fff; cursor: pointer; }
button:hover { background: #efeee9; }
span.said { margin-left: .6rem; font-size: .8rem; color: #6b6b63; }
p.none { color: #8a8a80; font-size: .85rem; font-style: italic; margin: 0; }
</style></head><body>
<h1>Book of Ground — notes</h1>
<script>var W = {}, O = {};
function save(i) {
  var t = document.getElementById("t" + i).value;
  var f = W[i], o = O[i];
  var b = f.length + ":" + f + o.length + ":" + o + t.length + ":" + t;
  fetch("/save", { method: "POST", body: b })
    .then(function (r) { return r.text(); })
    .then(function (m) {
      document.getElementById("s" + i).textContent = m;
      if (m.indexOf("saved") === 0) O[i] = t;
    });
}
</script>
`;

enum TAIL = "</body></html>\n";
