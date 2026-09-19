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

// ---- the pin in the store ----

// What was there before the pin, or empty for null and for absent. One open
// pin at a time: released_at 0.
struct Pin {
    bool open;
    long id;
    char[16] beforeBuf;
    size_t beforeLen;
    const(char)[] before() const return { return beforeBuf[0 .. beforeLen]; }
}

Pin openPin(sqlite3* db) {
    Pin p;
    enum sql = "SELECT id, before FROM effort_pin WHERE released_at = 0 ORDER BY id DESC LIMIT 1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return p;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        p.open = true;
        p.id = sqlite3_column_int64(stmt, 0);
        auto text = sqlite3_column_text(stmt, 1);
        if (text !is null)
            while (text[p.beforeLen] != 0 && p.beforeLen < p.beforeBuf.length) { p.beforeBuf[p.beforeLen] = text[p.beforeLen]; p.beforeLen++; }
    }
    sqlite3_finalize(stmt);
    return p;
}

bool pin(sqlite3* db, const(char)[] before, long reading, long now) {
    enum sql = "INSERT INTO effort_pin (before, reading, pinned_at) VALUES (?1, ?2, ?3)\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return false;
    sqlite3_bind_text(stmt, 1, before.ptr, cast(int) before.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 2, reading);
    sqlite3_bind_int64(stmt, 3, now);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return sqlite3_changes(db) == 1;
}

bool release(sqlite3* db, long id, long reading, long now) {
    enum sql = "UPDATE effort_pin SET released_at = ?1, released_reading = ?2 WHERE id = ?3 AND released_at = 0\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return false;
    sqlite3_bind_int64(stmt, 1, now);
    sqlite3_bind_int64(stmt, 2, reading);
    sqlite3_bind_int64(stmt, 3, id);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return sqlite3_changes(db) == 1;
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
    char[160] buf = 0;
    size_t len;
    const(char)[] text() const return { return buf[0 .. len]; }
    void put(const(char)[] s) { foreach (c; s) if (len < buf.length) buf[len++] = c; }
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

// One look: pin, release, or nothing. The reading is the Fable window's, -1
// for none; a window that has reset reads as none and releases the pin.
Pinned effortPass(sqlite3* db, long fableTenths, long now) {
    Pinned said;
    auto p = openPin(db);
    __gshared char[65536] file = void;
    __gshared char[65536 + 64] next = void;

    if (pinWanted(fableTenths) && !p.open) {
        auto n = settingsInto(file[]);
        if (n == 0) return said;
        auto before = effortIn(file[0 .. n]);
        if (before == PINNED) return said;
        auto m = settingsWith(file[0 .. n], `"` ~ PINNED ~ `"`, next[]);
        if (m == 0 || !settingsWrite(next[0 .. m])) return said;
        pin(db, before, fableTenths, now);
        said.put("effortLevel pinned to low: the Fable week stands at ");
        said.tenths(fableTenths);
        said.put("%; it goes back to ");
        said.put(before.length > 0 ? before : "the default");
        said.put(" when the week is under 85");
        return said;
    }

    if (!pinWanted(fableTenths) && p.open) {
        auto n = settingsInto(file[]);
        if (n == 0) return said;
        char[20] quoted = 0;
        size_t ql = 0;
        if (p.before().length > 0) {
            quoted[ql++] = '"';
            foreach (c; p.before()) if (ql < quoted.length - 1) quoted[ql++] = c;
            quoted[ql++] = '"';
        } else {
            foreach (c; "null") quoted[ql++] = c;
        }
        auto m = settingsWith(file[0 .. n], quoted[0 .. ql], next[]);
        if (m == 0 || !settingsWrite(next[0 .. m])) return said;
        release(db, p.id, fableTenths, now);
        said.put("effortLevel back to ");
        said.put(p.before().length > 0 ? p.before() : "the default");
        said.put(": the Fable week stands at ");
        if (fableTenths < 0) said.put("no reading"); else { said.tenths(fableTenths); said.put("%"); }
        return said;
    }
    return said;
}

unittest {
    import db : sqlite3_open, sqlite3_close, applySchema;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    assert(!openPin(db).open);
    assert(pin(db, "high", 862, 1000));
    auto p = openPin(db);
    assert(p.open && p.before() == "high");
    assert(release(db, p.id, 120, 2000));
    assert(!openPin(db).open, "released is closed");
    assert(!release(db, p.id, 120, 2001), "and not released twice");

    // A pin over an absent setting remembers nothing, and gives back null.
    assert(pin(db, "", 900, 3000));
    assert(openPin(db).before() == "");
    sqlite3_close(db);
}
