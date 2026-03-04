module sqlite;

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
    int sqlite3_enable_load_extension(sqlite3* db, int onoff);
    int sqlite3_load_extension(sqlite3* db, const(char)* file, const(char)* proc, char** errmsg);
    const(char)* sqlite3_column_text(sqlite3_stmt* stmt, int col);
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

import controls : DB_PATH, EXT_PATH;

// --- DB lifecycle ---

sqlite3* openDb() {
    sqlite3* db;
    if (sqlite3_open(DB_PATH.ptr, &db) != SQLITE_OK) {
        if (db !is null) sqlite3_close(db);
        return null;
    }

    if (sqlite3_exec(db, "SELECT 1 FROM attestations LIMIT 0\0".ptr, null, null, null) != SQLITE_OK) {
        sqlite3_close(db);
        return null;
    }
    return db;
}

// Check if an attestation with a given predicate exists for a session.
bool attestationExists(sqlite3* db, const(char)[] predicate, const(char)[] sessionId) {
    __gshared ZBuf ctx;
    ctx.reset();
    ctx.put("%session:");
    ctx.put(sessionId);
    ctx.put("%");

    enum sql = "SELECT 1 FROM attestations WHERE predicates LIKE ?1 AND contexts LIKE ?2 LIMIT 1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return false;

    __gshared ZBuf pred;
    pred.reset();
    pred.put("%");
    pred.put(predicate);
    pred.put("%");

    sqlite3_bind_text(stmt, 1, pred.ptr(), cast(int) pred.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);

    bool found = sqlite3_step(stmt) == SQLITE_ROW;
    sqlite3_finalize(stmt);
    return found;
}

bool loadAxExtension(sqlite3* db) {
    if (sqlite3_enable_load_extension(db, 1) != SQLITE_OK)
        return false;
    char* errmsg;
    if (sqlite3_load_extension(db, EXT_PATH.ptr, "sqlite3_qntxax_init\0".ptr, &errmsg) != SQLITE_OK)
        return false;
    return true;
}

const(char)[] axQuery(sqlite3* db, const(char)* filter, int filterLen) {
    __gshared char[16384] resultBuf = 0;

    enum sql = "SELECT ax_query(?1)\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return null;
    sqlite3_bind_text(stmt, 1, filter, filterLen, SQLITE_TRANSIENT);

    if (sqlite3_step(stmt) != SQLITE_ROW) {
        sqlite3_finalize(stmt);
        return null;
    }

    auto text = sqlite3_column_text(stmt, 0);
    if (text is null) {
        sqlite3_finalize(stmt);
        return null;
    }

    size_t len = 0;
    while (text[len] != 0 && len < resultBuf.length)
        len++;
    foreach (i; 0 .. len)
        resultBuf[i] = text[i];

    sqlite3_finalize(stmt);
    return resultBuf[0 .. len];
}

// --- Branch name ---

// NOTE: cwd is passed into popen unescaped. Trusted — comes from Claude Code's hook payload.
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

// Builds {"event":"...","detail":"...","after":<unix>} — for deferred messages
void jsonAttributesDeferred(ref ZBuf buf, const(char)[] event, const(char)[] detail, long afterUnix) {
    buf.reset();
    buf.put(`{"event":"`);
    buf.put(event);
    buf.put(`","detail":"`);
    size_t written = 0;
    foreach (c; detail) {
        if (written >= 200) break;
        if (c == '"') buf.put(`\"`);
        else if (c == '\\') buf.put(`\\`);
        else if (c == '\n') buf.put(`\n`);
        else buf.putChar(c);
        written++;
    }
    buf.put(`","after":`);
    // Write unix timestamp as decimal
    char[20] tbuf = 0;
    int tlen = 0;
    long v = afterUnix;
    if (v == 0) { tbuf[0] = '0'; tlen = 1; }
    else {
        while (v > 0 && tlen < 19) { tbuf[tlen++] = cast(char)('0' + v % 10); v /= 10; }
        foreach (i; 0 .. tlen / 2) { auto tmp = tbuf[i]; tbuf[i] = tbuf[tlen - 1 - i]; tbuf[tlen - 1 - i] = tmp; }
    }
    buf.put(tbuf[0 .. tlen]);
    buf.put(`}`);
}

// Builds {"event":"...","detail":"..."} — for attributes
void jsonAttributes(ref ZBuf buf, const(char)[] event, const(char)[] detail) {
    buf.reset();
    buf.put(`{"event":"`);
    buf.put(event);
    buf.put(`","detail":"`);
    // Truncate detail to first 200 chars, escape quotes
    size_t written = 0;
    foreach (c; detail) {
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

// Builds {"event":"...","detail":"...","response":"..."} — for PostToolUse
void jsonAttributes(ref ZBuf buf, const(char)[] event, const(char)[] detail, const(char)[] response) {
    buf.reset();
    buf.put(`{"event":"`);
    buf.put(event);
    buf.put(`","detail":"`);
    size_t written = 0;
    foreach (c; detail) {
        if (written >= 200) break;
        if (c == '"') buf.put(`\"`);
        else if (c == '\\') buf.put(`\\`);
        else if (c == '\n') buf.put(`\n`);
        else buf.putChar(c);
        written++;
    }
    buf.put(`","response":"`);
    written = 0;
    foreach (c; response) {
        if (written >= 200) break;
        if (c == '"') buf.put(`\"`);
        else if (c == '\\') buf.put(`\\`);
        else if (c == '\n') buf.put(`\n`);
        else buf.putChar(c);
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
void writeAttestationTo(
    sqlite3* db,
    const(char)[] predicate,
    const(char)[] cwd,
    const(char)[] sessionId,
    const(char)[] toolUseId,
    const(char)[] command
) {
    auto branch = getBranch(cwd);
    auto ts = formatTimestamp();

    __gshared ZBuf subjects;
    __gshared ZBuf predicates;
    __gshared ZBuf contexts;
    __gshared ZBuf actors;
    __gshared ZBuf source;
    __gshared ZBuf attributes;
    __gshared ZBuf idBuf;

    jsonArray1(subjects, branch);
    jsonArray1(predicates, predicate);

    // contexts: ["session:<sessionId>"]
    contexts.reset();
    contexts.put(`["session:`);
    contexts.put(sessionId);
    contexts.put(`"]`);

    jsonArray1(actors, "graunde");

    source.reset();
    source.put("graunde ");
    source.put(versionString());

    jsonAttributes(attributes, predicate, command);

    // id = tool_use_id
    idBuf.reset();
    idBuf.put(toolUseId);

    enum sql = "INSERT OR IGNORE INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return;
    sqlite3_bind_text(stmt, 1, idBuf.ptr(), cast(int) idBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, subjects.ptr(), cast(int) subjects.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, predicates.ptr(), cast(int) predicates.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, contexts.ptr(), cast(int) contexts.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, actors.ptr(), cast(int) actors.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 6, ts.ptr, cast(int) ts.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 7, source.ptr(), cast(int) source.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 8, attributes.ptr(), cast(int) attributes.len, SQLITE_TRANSIENT);

    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

void writeAttestation(
    const(char)[] predicate,
    const(char)[] cwd,
    const(char)[] sessionId,
    const(char)[] toolUseId,
    const(char)[] command
) {
    auto db = openDb();
    if (db is null) return;
    writeAttestationTo(db, predicate, cwd, sessionId, toolUseId, command);
    sqlite3_close(db);
}

void writeAttestationWithResponse(
    const(char)[] predicate,
    const(char)[] cwd,
    const(char)[] sessionId,
    const(char)[] toolUseId,
    const(char)[] command,
    const(char)[] response
) {
    auto db = openDb();
    if (db is null) return;

    auto branch = getBranch(cwd);
    auto ts = formatTimestamp();

    __gshared ZBuf subjects;
    __gshared ZBuf predicates;
    __gshared ZBuf contexts;
    __gshared ZBuf actors;
    __gshared ZBuf source;
    __gshared ZBuf attribs;
    __gshared ZBuf idBuf;

    jsonArray1(subjects, branch);
    jsonArray1(predicates, predicate);

    contexts.reset();
    contexts.put(`["session:`);
    contexts.put(sessionId);
    contexts.put(`"]`);

    jsonArray1(actors, "graunde");

    source.reset();
    source.put("graunde ");
    source.put(versionString());

    jsonAttributes(attribs, predicate, command, response);

    idBuf.reset();
    idBuf.put(toolUseId);

    enum sql = "INSERT OR IGNORE INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) {
        sqlite3_close(db);
        return;
    }
    sqlite3_bind_text(stmt, 1, idBuf.ptr(), cast(int) idBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, subjects.ptr(), cast(int) subjects.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, predicates.ptr(), cast(int) predicates.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, contexts.ptr(), cast(int) contexts.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, actors.ptr(), cast(int) actors.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 6, ts.ptr, cast(int) ts.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 7, source.ptr(), cast(int) source.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 8, attribs.ptr(), cast(int) attribs.len, SQLITE_TRANSIENT);

    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    sqlite3_close(db);
}

// --- Deferred message queue ---

struct DeferredMsg {
    const(char)[] name;    // e.g. "ci-check"
    const(char)[] message; // the context to deliver
}

// Write a deferred message attestation with a deliver-after delay.
void writeDeferredMessage(
    sqlite3* db,
    const(char)[] name,
    const(char)[] cwd,
    const(char)[] sessionId,
    const(char)[] message,
    int delaySec
) {
    auto afterUnix = cast(long) time(null) + delaySec;

    __gshared ZBuf predBuf;
    predBuf.reset();
    predBuf.put("deferred:");
    predBuf.put(name);

    __gshared ZBuf attribs;
    jsonAttributesDeferred(attribs, predBuf.slice(), message, afterUnix);

    auto branch = getBranch(cwd);
    auto ts = formatTimestamp();

    __gshared ZBuf subjects;
    __gshared ZBuf predicates;
    __gshared ZBuf contexts;
    __gshared ZBuf actors;
    __gshared ZBuf source;
    __gshared ZBuf idBuf;

    jsonArray1(subjects, branch);
    jsonArray1(predicates, predBuf.slice());

    contexts.reset();
    contexts.put(`["session:`);
    contexts.put(sessionId);
    contexts.put(`"]`);

    jsonArray1(actors, "graunde");

    source.reset();
    source.put("graunde ");
    source.put(versionString());

    // Unique id for deferred message
    import parse : buildEventId;
    auto evId = buildEventId(predBuf.slice());
    idBuf.reset();
    idBuf.put(evId);

    enum sql = "INSERT OR IGNORE INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return;
    sqlite3_bind_text(stmt, 1, idBuf.ptr(), cast(int) idBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, subjects.ptr(), cast(int) subjects.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, predicates.ptr(), cast(int) predicates.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, contexts.ptr(), cast(int) contexts.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, actors.ptr(), cast(int) actors.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 6, ts.ptr, cast(int) ts.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 7, source.ptr(), cast(int) source.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 8, attribs.ptr(), cast(int) attribs.len, SQLITE_TRANSIENT);

    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

// Read a pending deferred message for this session that's ready to deliver.
DeferredMsg readDeferredMessage(sqlite3* db, const(char)[] sessionId) {
    auto now = cast(long) time(null);

    // Find deferred attestations for this session
    enum sql = "SELECT predicates, attributes FROM attestations WHERE predicates LIKE '%deferred:%' AND contexts LIKE ?1 ORDER BY timestamp ASC LIMIT 5\0";

    __gshared ZBuf ctx;
    ctx.reset();
    ctx.put("%session:");
    ctx.put(sessionId);
    ctx.put("%");

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return DeferredMsg(null, null);

    sqlite3_bind_text(stmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);

    __gshared char[256] nameBuf = 0;
    __gshared char[512] msgBuf = 0;

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        auto predText = sqlite3_column_text(stmt, 0);
        auto attrText = sqlite3_column_text(stmt, 1);
        if (predText is null || attrText is null) continue;

        // Extract name from predicates: ["deferred:ci-check"] -> ci-check
        size_t predLen = 0;
        while (predText[predLen] != 0) predLen++;
        auto preds = (cast(const(char)*) predText)[0 .. predLen];

        // Find "deferred:" in predicates
        auto dIdx = indexOf(preds, "deferred:");
        if (dIdx < 0) continue;
        size_t nameStart = cast(size_t) dIdx + 9; // skip "deferred:"
        size_t nameEnd = nameStart;
        while (nameEnd < predLen && preds[nameEnd] != '"') nameEnd++;
        if (nameEnd == nameStart) continue;
        auto name = preds[nameStart .. nameEnd];

        // Check if already delivered
        __gshared ZBuf delPred;
        delPred.reset();
        delPred.put("delivered:");
        delPred.put(name);
        if (attestationExists(db, delPred.slice(), sessionId)) continue;

        // Extract "after" from attributes
        size_t attrLen = 0;
        while (attrText[attrLen] != 0) attrLen++;
        auto attrs = (cast(const(char)*) attrText)[0 .. attrLen];

        auto afterIdx = indexOf(attrs, `"after":`);
        if (afterIdx < 0) continue;
        size_t aPos = cast(size_t) afterIdx + 8; // skip "after":
        long afterVal = 0;
        while (aPos < attrLen && attrs[aPos] >= '0' && attrs[aPos] <= '9') {
            afterVal = afterVal * 10 + (attrs[aPos] - '0');
            aPos++;
        }
        if (now < afterVal) continue; // not ready yet

        // Extract "detail" from attributes (the message)
        auto detIdx = indexOf(attrs, `"detail":"`);
        if (detIdx < 0) continue;
        size_t mPos = cast(size_t) detIdx + 10; // skip "detail":"
        size_t mLen = 0;
        while (mPos + mLen < attrLen && mLen < msgBuf.length && attrs[mPos + mLen] != '"')
            mLen++;

        // Copy into static buffers
        size_t nLen = nameEnd - nameStart;
        if (nLen > nameBuf.length) nLen = nameBuf.length;
        foreach (i; 0 .. nLen) nameBuf[i] = name[i];
        foreach (i; 0 .. mLen) msgBuf[i] = attrs[mPos + i];

        sqlite3_finalize(stmt);
        return DeferredMsg(nameBuf[0 .. nLen], msgBuf[0 .. mLen]);
    }

    sqlite3_finalize(stmt);
    return DeferredMsg(null, null);
}

// Mark a deferred message as delivered.
void markDelivered(sqlite3* db, const(char)[] name, const(char)[] cwd, const(char)[] sessionId) {
    __gshared ZBuf predBuf;
    predBuf.reset();
    predBuf.put("delivered:");
    predBuf.put(name);

    import parse : buildEventId;
    auto evId = buildEventId(predBuf.slice());
    writeAttestationTo(db, predBuf.slice(), cwd, sessionId, evId, name);
}

