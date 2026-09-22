module effort;

// "if Fable usage is 85%+ its effort needs to be set to lowest automatically"
//
// The Fable week is a reading ug asks the usage endpoint for and writes to
// the usage table. Claude Code reads effortLevel from ~/.claude/settings.json
// and applies a change live — the same key Remote Control changes — so the
// sky, which reads the store every two seconds, pins it: at 85.0 it writes
// "low", keeps what was there in the store, and writes that back when the
// window stands under again, which is the week after. The session it runs in
// is told both times; every other session hears Claude Code's own
// ConfigChange.

import db : sqlite3, sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_int64,
            sqlite3_bind_text, sqlite3_column_text, sqlite3_column_int64, sqlite3_changes,
            sqlite3_stmt, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT, ZBuf;

// Tenths of a percent, as the usage table keeps a reading.
enum PIN_AT = 850;

// The lowest of low, medium, high, xhigh, max.
enum PINNED = "low";

// How often a sky asks. The reading itself moves every quarter hour.
enum EFFORT_EVERY = 60;

enum SETTINGS = "/.claude/settings.json";
enum KEY = `"effortLevel"`;

bool pinWanted(long fableTenths) {
    return fableTenths >= PIN_AT;
}

// ---- two windows, two ladders ----

// "i think all sessions, all models are put on low right nwo becaes i hit the
// fable limit, but the fable limit should just apply to fable sessions"
// "the other sessions have nothing to do with fable limit being hit or not"
//
// The top-level effortLevel is the default for every model at once, which is
// why one full window moved all of them. Claude Code also reads
// modelSettings.<model>.effortLevel, one key per model — that is the seam.
// Each window governs the models it is a window for, and nothing else.
//
// "for weekly 95+ should be put to low and 80+ should be set to medium"
// "fable should be set to medium if week is over 80, and fable's own 85+
// would set it to low on 85+ limit hit"
enum MEDIUM_AT = 800;
enum ACCOUNT_LOW_AT = 950;
enum FABLE_LOW_AT = 850;

enum FABLE_MODEL = "claude-fable-5-1";
immutable string[2] ACCOUNT_MODELS = ["claude-opus-5", "claude-sonnet-5"];

// What a reading asks of the models its window governs: "low", "medium", or
// "" for a reading that asks nothing. A window with no reading, and one that
// has already reset, ask nothing.
const(char)[] wantedFor(long tenths, long lowAt) {
    if (tenths < 0) return "";
    if (tenths >= lowAt) return "low";
    if (tenths >= MEDIUM_AT) return "medium";
    return "";
}

// The key modelSettings uses for a model ground wrote down. ground records
// claude-opus-5[1m]; the settings file keys on claude-opus-5, because the
// bracket is the context window and not another model.
const(char)[] modelKey(const(char)[] model) {
    foreach (i, c; model) if (c == '[') return model[0 .. i];
    return model;
}

// Where the key's value starts, past the colon and spaces, or text.length.
private size_t valueAt(const(char)[] text, ref size_t keyStart) {
    size_t i = 0;
    while (i + KEY.length < text.length) {
        if (text[i .. i + KEY.length] != KEY) { i++; continue; }
        keyStart = i;
        size_t j = i + KEY.length;
        while (j < text.length && (text[j] == ' ' || text[j] == '\t')) j++;
        if (j >= text.length || text[j] != ':') { i++; continue; }
        j++;
        while (j < text.length && (text[j] == ' ' || text[j] == '\t')) j++;
        return j;
    }
    return text.length;
}

// Where the value that starts at `at` ends: a string at its closing quote,
// anything else at the comma, brace or whitespace after it.
private size_t valueEnd(const(char)[] text, size_t at) {
    if (at >= text.length) return at;
    if (text[at] == '"') {
        size_t j = at + 1;
        while (j < text.length && text[j] != '"') { if (text[j] == '\\') j++; j++; }
        return j < text.length ? j + 1 : j;
    }
    size_t j = at;
    while (j < text.length && text[j] != ',' && text[j] != '}' && text[j] != ' '
           && text[j] != '\n' && text[j] != '\r' && text[j] != '\t') j++;
    return j;
}

// The setting as it stands: the string, or empty for null and for absent.
const(char)[] effortIn(const(char)[] text) {
    size_t keyStart;
    auto at = valueAt(text, keyStart);
    if (at >= text.length || text[at] != '"') return "";
    auto end = valueEnd(text, at);
    return text[at + 1 .. end - 1];
}

// The settings with effortLevel set to `value` — JSON as written, `"low"` or
// `null` — and nothing else touched, into dest: replaced where it is, put
// first where it is not. Text that is not a settings object is copied as it
// is. The length written, 0 when it did not fit.
size_t settingsWith(const(char)[] text, const(char)[] value, char[] dest) {
    size_t o = 0;
    bool over = false;
    void put(const(char)[] s) { foreach (c; s) { if (o < dest.length) dest[o++] = c; else over = true; } }

    size_t keyStart;
    auto at = valueAt(text, keyStart);
    if (at < text.length) {
        auto end = valueEnd(text, at);
        put(text[0 .. at]);
        put(value);
        put(text[end .. $]);
        return over ? 0 : o;
    }
    size_t brace = 0;
    while (brace < text.length && (text[brace] == ' ' || text[brace] == '\n' || text[brace] == '\r' || text[brace] == '\t')) brace++;
    if (brace >= text.length || text[brace] != '{') { put(text); return over ? 0 : o; }
    put(text[0 .. brace + 1]);
    // The line the next key sits on says how the file is indented.
    size_t j = brace + 1;
    if (j < text.length && text[j] == '\n') {
        size_t k = j + 1;
        while (k < text.length && (text[k] == ' ' || text[k] == '\t')) k++;
        put("\n");
        put(text[j + 1 .. k]);
        put(KEY);
        put(": ");
        put(value);
        put(",");
        put(text[j .. $]);
        return over ? 0 : o;
    }
    put(KEY);
    put(": ");
    put(value);
    put(", ");
    put(text[brace + 1 .. $]);
    return over ? 0 : o;
}

// ---- the settings file, one model at a time ----

// The nested keys are read by walking the objects, not by finding the text.
// valueAt above takes the first "effortLevel" anywhere in the file, which was
// safe while there was one; with a key per model under modelSettings there are
// several, and the one that comes first is not the one that was asked for.

private size_t skipSpace(const(char)[] text, size_t at) {
    while (at < text.length && (text[at] == ' ' || text[at] == '\n'
                                || text[at] == '\r' || text[at] == '\t')) at++;
    return at;
}

// One past the closing quote of the string opening at text[at].
private size_t skipString(const(char)[] text, size_t at) {
    size_t j = at + 1;
    while (j < text.length) {
        if (text[j] == '\\') { j += 2; continue; }
        if (text[j] == '"') return j + 1;
        j++;
    }
    return j;
}

// One past a value of any kind: a string at its closing quote, an object or
// array at its matching bracket, anything else at what ends it.
private size_t skipValue(const(char)[] text, size_t at) {
    if (at >= text.length) return at;
    auto c = text[at];
    if (c == '"') return skipString(text, at);
    if (c == '{' || c == '[') {
        size_t depth = 0;
        size_t j = at;
        while (j < text.length) {
            auto d = text[j];
            if (d == '"') { j = skipString(text, j); continue; }
            if (d == '{' || d == '[') depth++;
            else if (d == '}' || d == ']') { depth--; if (depth == 0) return j + 1; }
            j++;
        }
        return j;
    }
    size_t j = at;
    while (j < text.length && text[j] != ',' && text[j] != '}' && text[j] != ']'
           && text[j] != ' ' && text[j] != '\n' && text[j] != '\r' && text[j] != '\t') j++;
    return j;
}

private struct Member {
    bool ok;
    size_t keyAt;
    size_t valAt;
    size_t valEnd;
}

// An immediate member of the object opening at text[at]. Immediate is the
// whole point: a key nested deeper, or one spelled inside a string value, is
// not this object's and must not answer for it.
private Member memberOf(const(char)[] text, size_t at, const(char)[] key) {
    Member m;
    if (at >= text.length || text[at] != '{') return m;
    size_t i = skipSpace(text, at + 1);
    while (i < text.length && text[i] != '}') {
        if (text[i] != '"') return m;
        auto keyAt = i;
        auto keyEnd = skipString(text, i);
        if (keyEnd < 2 || keyEnd > text.length) return m;
        auto name = text[keyAt + 1 .. keyEnd - 1];
        i = skipSpace(text, keyEnd);
        if (i >= text.length || text[i] != ':') return m;
        i = skipSpace(text, i + 1);
        auto valAt = i;
        auto valEnd = skipValue(text, i);
        if (name == key) {
            m.ok = true;
            m.keyAt = keyAt;
            m.valAt = valAt;
            m.valEnd = valEnd;
            return m;
        }
        i = skipSpace(text, valEnd);
        if (i < text.length && text[i] == ',') i = skipSpace(text, i + 1);
        else break;
    }
    return m;
}

// Where the settings object opens, or text.length when this is not one.
private size_t rootAt(const(char)[] text) {
    auto i = skipSpace(text, 0);
    return (i < text.length && text[i] == '{') ? i : text.length;
}

// What modelSettings.<model>.effortLevel holds: the string, or empty for null
// and for absent. The top-level key is a different setting and never answers
// here — standing in for every model at once is what it did wrong.
const(char)[] modelEffortIn(const(char)[] text, const(char)[] model) {
    auto root = rootAt(text);
    if (root >= text.length) return "";
    auto ms = memberOf(text, root, "modelSettings");
    if (!ms.ok) return "";
    auto one = memberOf(text, ms.valAt, model);
    if (!one.ok) return "";
    auto lvl = memberOf(text, one.valAt, "effortLevel");
    if (!lvl.ok || lvl.valAt >= text.length || text[lvl.valAt] != '"') return "";
    return text[lvl.valAt + 1 .. lvl.valEnd - 1];
}

// The settings with modelSettings.<model>.effortLevel set to `value` — JSON as
// written, `"low"` or `null` — and nothing else touched, into dest. Each level
// that is missing is put in first, in front of what is already there. Text
// that is not a settings object is copied as it is. The length written, 0 when
// it did not fit.
size_t settingsWithModel(const(char)[] text, const(char)[] model,
                         const(char)[] value, char[] dest) {
    size_t o = 0;
    bool over = false;
    void put(const(char)[] s) {
        foreach (c; s) { if (o < dest.length) dest[o++] = c; else over = true; }
    }

    // A new member goes in at the front of the object opening at `brace`, in
    // the shape that object is already written in. A settings file is read by
    // a person: a compact insert across a file written one key to a line is a
    // seam, and the file's own indentation is right there to be copied.
    //
    // A newline straight after the brace is the object saying it is written a
    // key to a line; the spaces after that newline are its indent.
    bool perLine(size_t brace) {
        return brace + 1 < text.length && text[brace + 1] == '\n';
    }

    bool isEmpty(size_t brace) {
        auto rest = skipSpace(text, brace + 1);
        return rest >= text.length || text[rest] == '}';
    }

    // Everything between the brace and the new member.
    void before(size_t brace) {
        if (isEmpty(brace) || !perLine(brace)) return;
        size_t k = brace + 2;
        while (k < text.length && (text[k] == ' ' || text[k] == '\t')) k++;
        put(text[brace + 1 .. k]);
    }

    // Everything after it: the separator, then the object as it stood.
    void after(size_t brace) {
        if (isEmpty(brace)) { put(text[brace + 1 .. $]); return; }
        put(perLine(brace) ? "," : ", ");
        put(text[brace + 1 .. $]);
    }

    auto root = rootAt(text);
    if (root >= text.length) { put(text); return over ? 0 : o; }

    auto ms = memberOf(text, root, "modelSettings");
    if (!ms.ok) {
        put(text[0 .. root + 1]);
        before(root);
        put(`"modelSettings": {"`);
        put(model);
        put(`": {"effortLevel": `);
        put(value);
        put(`}}`);
        after(root);
        return over ? 0 : o;
    }

    auto one = memberOf(text, ms.valAt, model);
    if (!one.ok) {
        put(text[0 .. ms.valAt + 1]);
        before(ms.valAt);
        put(`"`);
        put(model);
        put(`": {"effortLevel": `);
        put(value);
        put(`}`);
        after(ms.valAt);
        return over ? 0 : o;
    }

    auto lvl = memberOf(text, one.valAt, "effortLevel");
    if (!lvl.ok) {
        put(text[0 .. one.valAt + 1]);
        before(one.valAt);
        put(`"effortLevel": `);
        put(value);
        after(one.valAt);
        return over ? 0 : o;
    }

    put(text[0 .. lvl.valAt]);
    put(value);
    put(text[lvl.valEnd .. $]);
    return over ? 0 : o;
}

// ---- the pin in the store ----

// What was there before the pin and what the pin put there, for one model.
// One open pin per model: released_at 0.
struct Pin {
    bool open;
    long id;
    char[16] beforeBuf;
    size_t beforeLen;
    char[16] wroteBuf;
    size_t wroteLen;
    const(char)[] before() const return { return beforeBuf[0 .. beforeLen]; }
    const(char)[] wrote() const return { return wroteBuf[0 .. wroteLen]; }
}

private void copyInto(const(char)* src, char[] dest, ref size_t len) {
    len = 0;
    if (src is null) return;
    while (src[len] != 0 && len < dest.length) { dest[len] = src[len]; len++; }
}

Pin openPin(sqlite3* db, const(char)[] model) {
    Pin p;
    enum sql = "SELECT id, before, wrote FROM effort_pin WHERE released_at = 0 AND model = ?1 "
        ~ "ORDER BY id DESC LIMIT 1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return p;
    sqlite3_bind_text(stmt, 1, model.ptr, cast(int) model.length, SQLITE_TRANSIENT);
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        p.open = true;
        p.id = sqlite3_column_int64(stmt, 0);
        copyInto(sqlite3_column_text(stmt, 1), p.beforeBuf[], p.beforeLen);
        copyInto(sqlite3_column_text(stmt, 2), p.wroteBuf[], p.wroteLen);
    }
    sqlite3_finalize(stmt);
    return p;
}

bool pin(sqlite3* db, const(char)[] model, const(char)[] before, const(char)[] wrote,
         long reading, long now) {
    enum sql = "INSERT INTO effort_pin (model, before, wrote, reading, pinned_at) "
        ~ "VALUES (?1, ?2, ?3, ?4, ?5)\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return false;
    sqlite3_bind_text(stmt, 1, model.ptr, cast(int) model.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, before.ptr, cast(int) before.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, wrote.ptr, cast(int) wrote.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 4, reading);
    sqlite3_bind_int64(stmt, 5, now);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return sqlite3_changes(db) == 1;
}

// What the pin now holds, when the window asks for a different room than the
// one it took. The pin keeps its `before`, because that is still what the key
// held before ground ever touched it.
bool moved(sqlite3* db, long id, const(char)[] wrote, long reading, long now) {
    enum sql = "UPDATE effort_pin SET wrote = ?1, reading = ?2, pinned_at = ?3 "
        ~ "WHERE id = ?4 AND released_at = 0\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return false;
    sqlite3_bind_text(stmt, 1, wrote.ptr, cast(int) wrote.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 2, reading);
    sqlite3_bind_int64(stmt, 3, now);
    sqlite3_bind_int64(stmt, 4, id);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return sqlite3_changes(db) == 1;
}

private bool close_(sqlite3* db, long id, long reading, long now, const(char)[] by) {
    enum sql = "UPDATE effort_pin SET released_at = ?1, released_reading = ?2, released_by = ?3 "
        ~ "WHERE id = ?4 AND released_at = 0\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return false;
    sqlite3_bind_int64(stmt, 1, now);
    sqlite3_bind_int64(stmt, 2, reading);
    sqlite3_bind_text(stmt, 3, by.ptr, cast(int) by.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 4, id);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return sqlite3_changes(db) == 1;
}

// The window fell and ground gave the key back.
bool release(sqlite3* db, long id, long reading, long now, const(char)[] by = "window") {
    return close_(db, id, reading, now, by);
}

// A person changed the key, so ground stopped owning it. The row says which of
// the two ended the pin, because they are not the same event and a reader
// should never have to guess which one this was.
bool overridden(sqlite3* db, long id, long reading, long now) {
    return close_(db, id, reading, now, "person");
}

// ---- what one look decides ----

enum Move {
    nothing,  // the key is where it should be
    take,     // no pin, and the window asks for a room
    move,     // the pin holds, and the window now asks for another room
    give,     // the window fell; put back what was there before
    letGo,    // the key is not what the pin wrote: a person put it there
}

// The whole decision, with no file and no store in it, so it can be read in
// one sitting and asserted on without either.
//   held   — is there an open pin for this model
//   wanted — what the window asks for now, "" for nothing
//   wrote  — what the pin put in the key
//   now_   — what the key holds this moment
//   before — what the key held when the pin took it
Move decide(bool held, const(char)[] wanted, const(char)[] wrote,
            const(char)[] now_, const(char)[] before) {
    if (!held) return wanted.length == 0 ? Move.nothing : Move.take;
    // "setting it manuall should override any setting ground puts" — a key
    // that no longer says what ground wrote is a key ground no longer owns,
    // and that is true whether the window has fallen or not.
    if (now_ != wrote) return Move.letGo;
    if (wanted.length == 0) return Move.give;
    return wanted == wrote ? Move.nothing : Move.move;
}

// ---- the file ----

// The settings file whole into dest, or 0.
size_t settingsInto(char[] dest) {
    import errors : getenv, open, read, close, O_RDONLY;
    auto home = getenv("HOME\0".ptr);
    if (home is null) return 0;
    __gshared ZBuf path;
    path.reset();
    size_t hl = 0;
    while (home[hl] != 0) hl++;
    path.put(home[0 .. hl]);
    path.put(SETTINGS);
    auto fd = open(path.ptr(), O_RDONLY, 0);
    if (fd < 0) return 0;
    size_t n = 0;
    while (n < dest.length) {
        auto got = read(fd, &dest[n], dest.length - n);
        if (got <= 0) break;
        n += got;
    }
    close(fd);
    return n < dest.length ? n : 0;
}

// The settings file replaced whole, through a rename, so a reader sees the
// old file or the new one and never half of either.
extern (C) int rename(const(char)* from, const(char)* to);

bool settingsWrite(const(char)[] text) {
    import errors : getenv, open, write, close, unlink, O_WRONLY, O_CREAT, O_TRUNC;
    auto home = getenv("HOME\0".ptr);
    if (home is null) return false;
    __gshared ZBuf path;
    __gshared ZBuf fresh;
    path.reset();
    fresh.reset();
    size_t hl = 0;
    while (home[hl] != 0) hl++;
    path.put(home[0 .. hl]);
    path.put(SETTINGS);
    fresh.put(path.slice());
    fresh.put(".ground-effort");
    auto fd = open(fresh.ptr(), O_WRONLY | O_CREAT | O_TRUNC, 0x1A4);
    if (fd < 0) return false;
    size_t done = 0;
    while (done < text.length) {
        auto w = write(fd, text.ptr + done, text.length - done);
        if (w <= 0) { close(fd); unlink(fresh.ptr()); return false; }
        done += w;
    }
    close(fd);
    if (rename(fresh.ptr(), path.ptr()) != 0) { unlink(fresh.ptr()); return false; }
    return true;
}

// ---- the pass ----

// What a pass did, in words for the session, or nothing.
struct Pinned {
    // Three models can move in one pass, each with its own line.
    char[512] buf = 0;
    size_t len;
    const(char)[] text() const return { return buf[0 .. len]; }
    void put(const(char)[] s) { foreach (c; s) if (len < buf.length) buf[len++] = c; }
    // Each model that moved says so on its own line: a pass can move more
    // than one, and two of them run together read as one wrong sentence.
    void line() { if (len > 0 && len < buf.length) buf[len++] = '\n'; }
    void tenths(long v) {
        char[24] d = void; size_t dl = 0; auto w = v / 10;
        if (w <= 0) d[dl++] = '0';
        while (w > 0 && dl < d.length) { d[dl++] = cast(char)('0' + w % 10); w /= 10; }
        foreach_reverse (i; 0 .. dl) put(d[i .. i + 1]);
        put(".");
        char[1] t = [cast(char)('0' + v % 10)];
        put(t[]);
    }
}

// A value as JSON: the string, or null for the nothing a key held before
// ground ever wrote it.
private size_t quote(const(char)[] value, char[] dest) {
    size_t o = 0;
    void put(const(char)[] s) { foreach (c; s) if (o < dest.length) dest[o++] = c; }
    if (value.length == 0) { put("null"); return o; }
    put(`"`); put(value); put(`"`);
    return o;
}

// One model's key, one window's reading, one look. `decide` holds the whole
// rule; this carries it out and says what it did.
private void onePass(sqlite3* db, const(char)[] model, const(char)[] window,
                     long tenths, long lowAt, long now, ref Pinned said) {
    __gshared char[65536] file = void;
    __gshared char[65536 + 96] next = void;

    auto p = openPin(db, model);
    auto wanted = wantedFor(tenths, lowAt);

    // A file that will not read decides nothing. A pin left open over one
    // stays open, which is what it should do.
    auto n = settingsInto(file[]);
    if (n == 0) return;
    auto standing = modelEffortIn(file[0 .. n], model);

    final switch (decide(p.open, wanted, p.wrote(), standing, p.before())) {
        case Move.nothing:
            return;

        case Move.letGo:
            // Not a character of the file is touched. The value there is the
            // person's, and ground's only move is to stop claiming it.
            overridden(db, p.id, tenths, now);
            said.line();
            said.put(model);
            said.put(" effort is ");
            said.put(standing.length > 0 ? standing : "the default");
            said.put(", set by hand — ground has let go of it");
            return;

        case Move.take:
        case Move.move:
            __gshared char[24] taking = void;
            auto tl = quote(wanted, taking[]);
            auto tm = settingsWithModel(file[0 .. n], model, taking[0 .. tl], next[]);
            if (tm == 0 || !settingsWrite(next[0 .. tm])) return;
            if (p.open) moved(db, p.id, wanted, tenths, now);
            else pin(db, model, standing, wanted, tenths, now);
            said.line();
            said.put(model);
            said.put(" effort set to ");
            said.put(wanted);
            said.put(": the ");
            said.put(window);
            said.put(" stands at ");
            said.tenths(tenths);
            said.put("%");
            return;

        case Move.give:
            __gshared char[24] giving = void;
            auto gl = quote(p.before(), giving[]);
            auto gm = settingsWithModel(file[0 .. n], model, giving[0 .. gl], next[]);
            if (gm == 0 || !settingsWrite(next[0 .. gm])) return;
            release(db, p.id, tenths, now);
            said.line();
            said.put(model);
            said.put(" effort back to ");
            said.put(p.before().length > 0 ? p.before() : "the default");
            said.put(": the ");
            said.put(window);
            said.put(" stands at ");
            if (tenths < 0) said.put("no reading"); else { said.tenths(tenths); said.put("%"); }
            return;
    }
}

// The pin from before there was a model, which wrote the top-level key. It
// names no model, so no ladder will ever meet it again.
Pin legacyPin(sqlite3* db) {
    return openPin(db, "");
}

// Handing that key back, once. The top-level effortLevel is the default for
// every model, and leaving ground's "low" in it would keep doing the very
// thing this change is for — quietly, and with nothing left to undo it.
private void legacyHandBack(sqlite3* db, long now, ref Pinned said) {
    auto old = legacyPin(db);
    if (!old.open) return;

    __gshared char[65536] file = void;
    __gshared char[65536 + 96] next = void;
    auto n = settingsInto(file[]);
    if (n == 0) return;

    // Only if it still says what that pin wrote. Anything else there is a
    // person's, and a person's setting is not ground's to take back.
    auto standing = effortIn(file[0 .. n]);
    if (standing != PINNED) {
        overridden(db, old.id, -1, now);
        return;
    }

    __gshared char[24] quoted = void;
    auto ql = quote(old.before(), quoted[]);
    auto m = settingsWith(file[0 .. n], quoted[0 .. ql], next[]);
    if (m == 0 || !settingsWrite(next[0 .. m])) return;
    release(db, old.id, -1, now, "legacy");

    said.line();
    said.put("the effortLevel that stood for every model is back to ");
    said.put(old.before().length > 0 ? old.before() : "the default");
    said.put("; each model now follows its own window");
}

// "the fable limit should just apply to fable sessions"
// "the other sessions have nothing to do with fable limit being hit or not"
// Each window against the models it governs, and never against the others.
// The top-level effortLevel is touched by none of this: it stands for every
// model at once, which is the whole of what went wrong.
Pinned effortPass(sqlite3* db, long accountTenths, long fableTenths, long now) {
    Pinned said;
    legacyHandBack(db, now, said);
    onePass(db, FABLE_MODEL, "Fable week", fableTenths, FABLE_LOW_AT, now, said);
    foreach (model; ACCOUNT_MODELS)
        onePass(db, model, "week", accountTenths, ACCOUNT_LOW_AT, now, said);
    return said;
}

// The pin's own tests moved to effort_pass_test.d when it became one pin per
// model: a pin is no longer a thing this module can demonstrate on its own.
