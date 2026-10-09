module quoteremoval;

// "what i need is probably the slow enforcement on qntx side to see that quotes were removed during some commit ad report back"
// A commit's patch is read for the quoted spans it took out and put back
// nowhere. Which of them the person said is asked on the node.

import zbuf : ZBuf;
import db : sqlite3;

enum QUOTE_REMOVED = "quote:removed";

enum REMOVALS_MAX = 32;

// The quoted spans a commit took out and put back nowhere, each with the file
// it left. Slices of the patch they were read from.
struct Removals {
    const(char)[][REMOVALS_MAX] files;
    const(char)[][REMOVALS_MAX] spans;
    size_t count;
}

private bool startsWith(const(char)[] s, const(char)[] p) {
    return s.length >= p.length && s[0 .. p.length] == p;
}

// Whether `"span"` stands anywhere in the line.
private bool quotedIn(const(char)[] line, const(char)[] span) {
    if (line.length < span.length + 2) return false;
    foreach (i; 0 .. line.length - span.length - 1) {
        if (line[i] != '"' || line[i + 1 + span.length] != '"') continue;
        if (line[i + 1 .. i + 1 + span.length] == span) return true;
    }
    return false;
}

// Every line the patch's hunks add or remove, with the file it belongs to. A
// removed line is the old path's, so a deleted file keeps the name it had.
private void eachChanged(const(char)[] patch,
                         scope void delegate(char sign, const(char)[] file, const(char)[] text) each) {
    const(char)[] oldPath, newPath;
    bool inHunk;
    size_t pos;
    while (pos < patch.length) {
        size_t end = pos;
        while (end < patch.length && patch[end] != '\n') end++;
        auto line = patch[pos .. end];
        pos = end + 1;
        if (startsWith(line, "diff --git ")) { inHunk = false; oldPath = null; newPath = null; continue; }
        if (!inHunk) {
            if (startsWith(line, "--- a/")) oldPath = line[6 .. $];
            else if (startsWith(line, "+++ b/")) newPath = line[6 .. $];
            else if (startsWith(line, "@@")) inHunk = true;
            continue;
        }
        if (line.length == 0 || startsWith(line, "@@")) continue;
        if (line[0] == '-') each('-', oldPath, line[1 .. $]);
        else if (line[0] == '+') each('+', newPath.length > 0 ? newPath : oldPath, line[1 .. $]);
    }
}

// The spans the claim side would count, read off the removed lines, less the
// ones an added line still carries.
Removals removedQuotes(const(char)[] patch) {
    import provenance : nextQuotedSpan, onProseLine, isWord;
    Removals r;
    eachChanged(patch, (char sign, const(char)[] file, const(char)[] text) {
        if (sign != '-') return;
        size_t from = 0;
        while (r.count < REMOVALS_MAX) {
            auto sp = nextQuotedSpan(text, from);
            if (!sp.ok) break;
            from = sp.end + 1;
            if (sp.end == sp.start) continue;
            if (!onProseLine(text, sp, file)) continue;
            if (isWord(text, sp)) continue;
            auto span = text[sp.start .. sp.end];
            bool kept;
            eachChanged(patch, (char s, const(char)[] f, const(char)[] t) {
                if (s == '+' && !kept && quotedIn(t, span)) kept = true;
            });
            if (kept) continue;
            r.files[r.count] = file;
            r.spans[r.count] = span;
            r.count++;
        }
    });
    return r;
}

// Whether this commit's removals were attested already: a PostToolUse can be heard twice.
private bool attestedAlready(sqlite3* db, const(char)[] sha) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_stmt, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    enum sql = "SELECT 1 FROM attestations WHERE predicates = '[\"" ~ QUOTE_REMOVED ~ "\"]' "
        ~ "AND json_extract(attributes, '$.commit') = ?1 LIMIT 1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return false;
    sqlite3_bind_text(stmt, 1, sha.ptr, cast(int) sha.length, SQLITE_TRANSIENT);
    auto found = sqlite3_step(stmt) == SQLITE_ROW;
    sqlite3_finalize(stmt);
    return found;
}

// The commit's removed quotes, attested for sky to carry to the node. Runs in
// the probe's detached child, so what goes wrong is recorded, not printed.
void attestRemovals(const(char)[] sha, const(char)[] tree, const(char)[] sessionId) {
    import errors : sayQuietly;
    import libgit2 : Repo;
    import db : openDb, sqlite3_close, attestEvent;

    __gshared Repo g;
    if (!g.open(tree)) {
        sayQuietly("quote.removal", "the tree would not open, so this commit was not read for removed quotes",
                   -1, sessionId, QUOTE_REMOVED, sha);
        return;
    }
    __gshared char[4 * 1024 * 1024] patch = 0;
    auto shown = g.show(sha, patch[]);
    auto over = g.overflowed;
    g.close();
    if (shown is null) {
        sayQuietly("quote.removal", "the commit would not read, so it was not read for removed quotes",
                   -1, sessionId, QUOTE_REMOVED, sha);
        return;
    }
    if (over)
        sayQuietly("quote.removal", "the commit's diff is larger than ground reads; quotes removed past it were not seen",
                   -1, sessionId, QUOTE_REMOVED, sha);

    auto r = removedQuotes(shown);
    if (r.count == 0) return;

    auto db = openDb();
    if (db is null) {
        sayQuietly("quote.removal", "the store would not open, so this commit's removed quotes were not attested",
                   -1, sessionId, QUOTE_REMOVED, sha);
        return;
    }
    scope (exit) sqlite3_close(db);
    if (attestedAlready(db, sha)) return;
    __gshared ZBuf body_;
    body_.reset();
    removalsInto(body_, sha, r);
    attestEvent(db, QUOTE_REMOVED, tree, sessionId, body_.slice(), "quote");
}

// immediate.d has the same, behind an import of every control ground holds.
private void putJsonString(ref ZBuf o, const(char)[] s) {
    foreach (c; s) {
        if (c == '"') o.put(`\"`);
        else if (c == '\\') o.put(`\\`);
        else if (c == '\n') o.put(`\n`);
        else if (c == '\r') o.put(`\r`);
        else if (c == '\t') o.put(`\t`);
        else if (c < 0x20) continue;
        else o.putChar(c);
    }
}

private void putList(ref ZBuf o, const(char[])[] items) {
    o.put("[");
    foreach (i, s; items) {
        if (i > 0) o.put(",");
        o.put(`"`);
        putJsonString(o, s);
        o.put(`"`);
    }
    o.put("]");
}

// What the node is sent: the commit, and the files and spans side by side.
void removalsInto(ref ZBuf o, const(char)[] sha, const ref Removals r) {
    o.put(`{"commit":"`);
    putJsonString(o, sha);
    o.put(`","files":`);
    putList(o, r.files[0 .. r.count]);
    o.put(`,"spans":`);
    putList(o, r.spans[0 .. r.count]);
    o.put("}");
}
