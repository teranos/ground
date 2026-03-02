module sqlite;

import controls : Control;
import matcher : indexOf, contains;
import core.stdc.stdio : fread, FILE;
import core.stdc.time : time, time_t, tm, gmtime;

// --- sqlite3 C bindings (minimal) ---

struct sqlite3;
struct sqlite3_stmt;

enum SQLITE_OK = 0;
enum SQLITE_ROW = 100;
enum SQLITE_DONE = 101;
enum SQLITE_TRANSIENT = cast(void function(void*)) -1;

extern (C) {
    int sqlite3_open(const(char)* filename, sqlite3** ppDb);
    int sqlite3_close(sqlite3* db);
    int sqlite3_exec(sqlite3* db, const(char)* sql, void* callback, void* arg, char** errmsg);
    int sqlite3_prepare_v2(sqlite3* db, const(char)* sql, int nByte, sqlite3_stmt** ppStmt, const(char*)* pzTail);
    int sqlite3_bind_text(sqlite3_stmt* stmt, int idx, const(char)* text, int n, void function(void*) destructor);
    int sqlite3_step(sqlite3_stmt* stmt);
    int sqlite3_finalize(sqlite3_stmt* stmt);
}

extern (C) {
    FILE* popen(const(char)* command, const(char)* type);
    int pclose(FILE* stream);
}

// --- Null-terminated buffer ---

struct ZBuf {
    char[4096] data = 0;
    size_t len;

    void put(const(char)[] s) {
        foreach (c; s)
            if (len + 1 < data.length) // reserve space for \0
                data[len++] = c;
        data[len] = '\0';
    }

    void putChar(char c) {
        if (len + 1 < data.length)
            data[len++] = c;
        data[len] = '\0';
    }

    void reset() {
        len = 0;
        data[0] = '\0';
    }

    const(char)* ptr() {
        return &data[0];
    }

    const(char)[] slice() {
        return data[0 .. len];
    }
}

import controls : DB_PATH;

// --- Branch name ---

const(char)[] getBranch(const(char)[] cwd) {
    __gshared char[256] branchBuf = 0;
    __gshared ZBuf cmdBuf;

    cmdBuf.reset();
    cmdBuf.put("git -C ");
    cmdBuf.put(cwd);
    cmdBuf.put(" branch --show-current");

    auto pipe = popen(cmdBuf.ptr(), "r");
    if (pipe is null) return "unknown";

    auto n = fread(&branchBuf[0], 1, branchBuf.length - 1, pipe);
    pclose(pipe);

    if (n == 0) return "unknown";

    // Strip trailing newline
    size_t end = n;
    while (end > 0 && (branchBuf[end - 1] == '\n' || branchBuf[end - 1] == '\r'))
        end--;

    if (end == 0) return "unknown";
    return branchBuf[0 .. end];
}


// --- Timestamp ---

const(char)[] formatTimestamp() {
    __gshared char[32] tsBuf = 0;

    auto t = time(null);
    auto tmPtr = gmtime(&t);
    if (tmPtr is null) return "1970-01-01T00:00:00Z";

    auto g = *tmPtr;
    int year = g.tm_year + 1900;
    int mon = g.tm_mon + 1;
    int day = g.tm_mday;
    int hour = g.tm_hour;
    int min = g.tm_min;
    int sec = g.tm_sec;

    // Manual format: YYYY-MM-DDTHH:MM:SSZ
    tsBuf[0] = cast(char)('0' + year / 1000);
    tsBuf[1] = cast(char)('0' + (year / 100) % 10);
    tsBuf[2] = cast(char)('0' + (year / 10) % 10);
    tsBuf[3] = cast(char)('0' + year % 10);
    tsBuf[4] = '-';
    tsBuf[5] = cast(char)('0' + mon / 10);
    tsBuf[6] = cast(char)('0' + mon % 10);
    tsBuf[7] = '-';
    tsBuf[8] = cast(char)('0' + day / 10);
    tsBuf[9] = cast(char)('0' + day % 10);
    tsBuf[10] = 'T';
    tsBuf[11] = cast(char)('0' + hour / 10);
    tsBuf[12] = cast(char)('0' + hour % 10);
    tsBuf[13] = ':';
    tsBuf[14] = cast(char)('0' + min / 10);
    tsBuf[15] = cast(char)('0' + min % 10);
    tsBuf[16] = ':';
    tsBuf[17] = cast(char)('0' + sec / 10);
    tsBuf[18] = cast(char)('0' + sec % 10);
    tsBuf[19] = 'Z';

    return tsBuf[0 .. 20];
}

// --- JSON builders ---

// Builds ["value"] in a buffer
void jsonArray1(ref ZBuf buf, const(char)[] val) {
    buf.reset();
    buf.put(`["`);
    buf.put(val);
    buf.put(`"]`);
}

// Builds {"key1":"val1","key2":"val2"} — for attributes
void jsonAttributes(ref ZBuf buf, const(char)[] controlName, const(char)[] command) {
    buf.reset();
    buf.put(`{"control":"`);
    buf.put(controlName);
    buf.put(`","command":"`);
    // Truncate command to first 200 chars, escape quotes
    size_t written = 0;
    foreach (c; command) {
        if (written >= 200) break;
        if (c == '"')
            buf.put(`\"`);
        else if (c == '\\')
            buf.put(`\\`);
        else if (c == '\n')
            buf.put(`\n`);
        else
            buf.putChar(c);
        written++;
    }
    buf.put(`"}`);
}

// --- VERSION import ---

enum VERSION = import(".version");

// Trim trailing newline from VERSION
const(char)[] versionString() {
    size_t end = VERSION.length;
    while (end > 0 && (VERSION[end - 1] == '\n' || VERSION[end - 1] == '\r'))
        end--;
    return VERSION[0 .. end];
}

// --- Main attestation writer ---

// TODO(#2): read CI attestations into graunde's control path
void writeAttestation(
    const(Control)* control,
    const(char)[] cwd,
    const(char)[] sessionId,
    const(char)[] toolUseId,
    const(char)[] command
) {
    // 1. Open db
    sqlite3* db;
    if (sqlite3_open(DB_PATH.ptr, &db) != SQLITE_OK) {
        if (db !is null) sqlite3_close(db);
        return;
    }

    // 3. Verify attestations table exists
    if (sqlite3_exec(db, "SELECT 1 FROM attestations LIMIT 0\0".ptr, null, null, null) != SQLITE_OK) {
        sqlite3_close(db);
        return;
    }

    // 4. Get branch and derive predicate
    auto branch = getBranch(cwd);
    auto pred = control.name;
    auto ts = formatTimestamp();

    // 5. Build JSON values
    __gshared ZBuf subjects;
    __gshared ZBuf predicates;
    __gshared ZBuf contexts;
    __gshared ZBuf actors;
    __gshared ZBuf source;
    __gshared ZBuf attributes;
    __gshared ZBuf idBuf;

    jsonArray1(subjects, branch);
    jsonArray1(predicates, pred);

    // contexts: ["session:<sessionId>"]
    contexts.reset();
    contexts.put(`["session:`);
    contexts.put(sessionId);
    contexts.put(`"]`);

    jsonArray1(actors, "graunde");

    source.reset();
    source.put("graunde ");
    source.put(versionString());

    jsonAttributes(attributes, control.name, command);

    // id = tool_use_id
    idBuf.reset();
    idBuf.put(toolUseId);

    // 6. Prepare INSERT
    enum sql = "INSERT OR IGNORE INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) {
        sqlite3_close(db);
        return;
    }

    // 7. Bind parameters
    sqlite3_bind_text(stmt, 1, idBuf.ptr(), cast(int) idBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, subjects.ptr(), cast(int) subjects.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, predicates.ptr(), cast(int) predicates.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, contexts.ptr(), cast(int) contexts.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, actors.ptr(), cast(int) actors.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 6, ts.ptr, cast(int) ts.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 7, source.ptr(), cast(int) source.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 8, attributes.ptr(), cast(int) attributes.len, SQLITE_TRANSIENT);

    // 8. Execute and cleanup
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    sqlite3_close(db);
}

