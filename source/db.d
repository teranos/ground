module db;

import matcher : indexOf, contains;
import core.stdc.stdio : FILE;
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
    const(char)* sqlite3_column_text(sqlite3_stmt* stmt, int col);
    long sqlite3_column_int64(sqlite3_stmt* stmt, int col);
    int sqlite3_bind_int64(sqlite3_stmt* stmt, int idx, long value);
}

extern (C) {
    FILE* popen(const(char)* command, const(char)* type);
    int pclose(FILE* stream);
}

// Standalone db at ~/.local/share/ground/ground.db — created when QNTX node db is unavailable.
// QNTX users get the shared node db. All array columns are JSON arrays of strings.
// Query pattern: WHERE subjects LIKE '%"value"%' — quotes are part of JSON serialization.

public import zbuf : ZBuf;

// --- DB lifecycle ---

extern (C) {
    const(char)* getenv(const(char)* name);
    int mkdir(const(char)* path, uint mode);
}

// Open ground's own db at ~/.local/share/ground/ground.db
sqlite3* openDb() {
    return openStandaloneDb();
}

sqlite3* openStandaloneDb() {
    auto home = getenv("HOME\0".ptr);
    if (home is null) return null;

    // Build path: $HOME/.local/share/ground/ground.db
    __gshared ZBuf pathBuf;
    pathBuf.reset();

    size_t homeLen = 0;
    while (home[homeLen] != 0) homeLen++;
    pathBuf.put(home[0 .. homeLen]);
    pathBuf.put("/.local/share/ground");

    // mkdir -p: create each directory level
    mkdirP(pathBuf.slice());

    pathBuf.put("/ground.db");

    sqlite3* db;
    if (sqlite3_open(pathBuf.ptr(), &db) != SQLITE_OK) {
        if (db !is null) sqlite3_close(db);
        return null;
    }

    // Create table if needed
    enum schema = "CREATE TABLE IF NOT EXISTS attestations ("
        ~ "id TEXT PRIMARY KEY, subjects JSON NOT NULL, predicates JSON NOT NULL, "
        ~ "contexts JSON NOT NULL, actors JSON NOT NULL, timestamp DATETIME NOT NULL, "
        ~ "source TEXT NOT NULL DEFAULT 'cli', attributes JSON, "
        ~ "created_at DATETIME DEFAULT CURRENT_TIMESTAMP)\0";

    if (sqlite3_exec(db, schema.ptr, null, null, null) != SQLITE_OK) {
        sqlite3_close(db);
        return null;
    }

    enum sessionProjectSchema = "CREATE TABLE IF NOT EXISTS session_project ("
        ~ "session_id TEXT PRIMARY KEY, project TEXT NOT NULL)\0";
    sqlite3_exec(db, sessionProjectSchema.ptr, null, null, null);

    enum idxPredicate = "CREATE INDEX IF NOT EXISTS idx_attestations_predicate ON attestations(json_extract(predicates, '$[0]'))\0";
    enum idxControl = "CREATE INDEX IF NOT EXISTS idx_attestations_control ON attestations(json_extract(attributes, '$.control'))\0";
    enum idxSubject = "CREATE INDEX IF NOT EXISTS idx_attestations_subject ON attestations(json_extract(subjects, '$[0]'))\0";
    sqlite3_exec(db, idxPredicate.ptr, null, null, null);
    sqlite3_exec(db, idxControl.ptr, null, null, null);
    sqlite3_exec(db, idxSubject.ptr, null, null, null);

    return db;
}

// Create directory and parents. Walks the path creating each level.
void mkdirP(const(char)[] path) {
    __gshared char[512] buf = 0;
    foreach (i, c; path) {
        if (i >= buf.length - 1) break;
        buf[i] = c;
        if (c == '/' && i > 0) {
            buf[i] = '\0';
            mkdir(&buf[0], 493); // 0755
            buf[i] = '/';
        }
    }
    if (path.length < buf.length) {
        buf[path.length] = '\0';
        mkdir(&buf[0], 493); // 0755
    }
}

void walCheckpoint(sqlite3* db) {
    sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)\0".ptr, null, null, null);
}

// Check if a Grounded attestation exists for a control in this session,
// and hasn't been invalidated by a subsequent compaction.
bool attestationExists(sqlite3* db, const(char)[] groundedPredicate, const(char)[] controlName, const(char)[] sessionId) {
    __gshared ZBuf ctx;
    ctx.reset();
    ctx.put("%session:");
    ctx.put(sessionId);
    ctx.put("%");

    // Find the control attestation's rowid — uses json_extract indexes
    enum sql = "SELECT rowid FROM attestations WHERE json_extract(predicates, '$[0]') = ?1 AND json_extract(attributes, '$.control') = ?2 AND contexts LIKE ?3 ORDER BY rowid DESC LIMIT 1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return false;

    sqlite3_bind_text(stmt, 1, groundedPredicate.ptr, cast(int) groundedPredicate.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, controlName.ptr, cast(int) controlName.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);

    bool found = sqlite3_step(stmt) == SQLITE_ROW;
    if (!found) {
        sqlite3_finalize(stmt);
        return false;
    }

    // Get the rowid of the control attestation
    auto controlRowid = sqlite3_column_int64(stmt, 0);
    sqlite3_finalize(stmt);

    // Check if a PreCompact event occurred after this attestation in the same session
    enum compactSql = "SELECT 1 FROM attestations WHERE json_extract(predicates, '$[0]') = 'PreCompact' AND contexts LIKE ?1 AND rowid > ?2 LIMIT 1\0";
    sqlite3_stmt* compactStmt;
    if (sqlite3_prepare_v2(db, compactSql.ptr, -1, &compactStmt, null) != SQLITE_OK)
        return true; // can't check, assume still valid

    sqlite3_bind_text(compactStmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
    sqlite3_bind_int64(compactStmt, 2, controlRowid);

    bool compacted = sqlite3_step(compactStmt) == SQLITE_ROW;
    sqlite3_finalize(compactStmt);

    // If compaction happened after the attestation, it's invalidated
    return !compacted;
}

// Check if a Read tool attestation exists for a filename in this session.
// Searches PostToolUse attestations where attributes contain "Read" and the filename.
bool readAttestationExists(sqlite3* db, const(char)[] filename, const(char)[] sessionId) {
    __gshared ZBuf ctx, filePat;

    ctx.reset();
    ctx.put("%session:");
    ctx.put(sessionId);
    ctx.put("%");

    filePat.reset();
    filePat.put("%");
    filePat.put(filename);
    filePat.put("%");

    enum sql = "SELECT 1 FROM attestations WHERE json_extract(predicates, '$[0]') = 'PostToolUse' AND contexts LIKE ?1 AND attributes LIKE '%\"Read\"%' AND attributes LIKE ?2 LIMIT 1\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return false;

    sqlite3_bind_text(stmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, filePat.ptr(), cast(int) filePat.len, SQLITE_TRANSIENT);

    bool found = sqlite3_step(stmt) == SQLITE_ROW;
    sqlite3_finalize(stmt);
    return found;
}

public import git : cwdTail, buildSubject, getBranch;


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

// --- VERSION import ---

enum VERSION = import(".version");

// Trim trailing newline from VERSION
const(char)[] versionString() {
    size_t end = VERSION.length;
    while (end > 0 && (VERSION[end - 1] == '\n' || VERSION[end - 1] == '\r'))
        end--;
    return VERSION[0 .. end];
}

bool jsonValid(sqlite3* db, const(char)[] payload) {
    enum checkSql = "SELECT json_valid(?1)\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, checkSql.ptr, -1, &stmt, null) != SQLITE_OK)
        return true; // can't check, let it through
    sqlite3_bind_text(stmt, 1, payload.ptr, cast(int) payload.length, SQLITE_TRANSIENT);
    bool valid = sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int64(stmt, 0) == 1;
    sqlite3_finalize(stmt);
    return valid;
}

// --- Universal event attestation ---
// Stores the full hook payload as attributes — no field extraction, no truncation.

void attestEvent(
    sqlite3* db,
    const(char)[] eventName,
    const(char)[] cwd,
    const(char)[] sessionId,
    const(char)[] payload
) {
    auto branch = getBranch(cwd);
    auto ts = formatTimestamp();

    __gshared ZBuf subjects;
    __gshared ZBuf predicates;
    __gshared ZBuf contexts;
    __gshared ZBuf actors;
    __gshared ZBuf source;
    __gshared ZBuf idBuf;

    // Build subject: "parent/repo:branch" — e.g. "tmp3/QNTX:feat/weave-panel"
    // Project part cached in session_project table to avoid cwd drift from cd.
    __gshared ZBuf subjectVal;
    __gshared char[256] sessionProjectBuf = 0;
    const(char)[] sessionProject = null;

    {
        enum lookupSql = "SELECT project FROM session_project WHERE session_id = ?1\0";
        sqlite3_stmt* spStmt;
        if (sqlite3_prepare_v2(db, lookupSql.ptr, -1, &spStmt, null) == SQLITE_OK) {
            __gshared ZBuf sidBuf;
            sidBuf.reset();
            sidBuf.put(sessionId);
            sqlite3_bind_text(spStmt, 1, sidBuf.ptr(), cast(int) sidBuf.len, SQLITE_TRANSIENT);
            if (sqlite3_step(spStmt) == SQLITE_ROW) {
                auto text = sqlite3_column_text(spStmt, 0);
                if (text !is null) {
                    size_t sLen = 0;
                    while (text[sLen] != 0) sLen++;
                    if (sLen > 0 && sLen < sessionProjectBuf.length) {
                        foreach (i; 0 .. sLen) sessionProjectBuf[i] = (cast(const(char)*) text)[i];
                        sessionProject = sessionProjectBuf[0 .. sLen];
                    }
                }
            }
            sqlite3_finalize(spStmt);
        }
    }

    if (sessionProject !is null) {
        subjectVal.reset();
        subjectVal.put(sessionProject);
        subjectVal.put(":");
        subjectVal.put(branch);
    } else {
        buildSubject(subjectVal, cwd, branch);
    }
    jsonArray1(subjects, subjectVal.slice());
    jsonArray1(predicates, eventName);

    contexts.reset();
    contexts.put(`["session:`);
    contexts.put(sessionId);
    contexts.put(`"]`);

    jsonArray1(actors, "ground");

    source.reset();
    source.put("ground ");
    source.put(versionString());

    idBuf.reset();
    idBuf.put("ground:payload:");
    idBuf.put(eventName);
    idBuf.put(":");
    idBuf.put(ts);

    // Validate payload is valid JSON — truncated payloads (>64KB) break json_extract indexes
    if (payload.length > 0 && !jsonValid(db, payload)) {
        import core.stdc.stdio : stderr, fputs;
        fputs("ground: dropped attestation — payload is not valid JSON (truncated?)\n\0".ptr, stderr);
        return;
    }

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
    sqlite3_bind_text(stmt, 8, payload.ptr, cast(int) payload.length, SQLITE_TRANSIENT);

    sqlite3_step(stmt);
    sqlite3_finalize(stmt);

    // Fire-and-forget UDP to loom
    import loom : sendToLoom;
    sendToLoom(subjects, predicates, contexts, payload);
}

// --- Control fire attestation ---
// Attests that a control fired. Handles the {"control":"<name>"} JSON and openDb lifecycle.
// If db is null, opens and closes its own handle.

void attestControlFire(sqlite3* db, const(char)[] predicate, const(char)[] controlName,
                       const(char)[] cwd, const(char)[] sessionId) {
    __gshared ZBuf cfAttrs;
    cfAttrs.reset();
    cfAttrs.put(`{"control":"`);
    cfAttrs.put(controlName);
    cfAttrs.put(`"}`);

    bool ownDb = db is null;
    if (ownDb) {
        db = openDb();
        if (db is null) return;
    }
    attestEvent(db, predicate, cwd, sessionId, cfAttrs.slice());
    if (ownDb) sqlite3_close(db);
}

// --- Type attestation ---
// Attests a type definition so QNTX knows what to do with the data.
// ID encodes version — re-attested when ground updates. INSERT OR IGNORE prevents duplicates.

void attestType(sqlite3* db, const(char)[] name, const(char)[] context, const(char)[] attributes) {
    auto ts = formatTimestamp();

    __gshared ZBuf idBuf;
    __gshared ZBuf subjects;
    __gshared ZBuf actors;
    __gshared ZBuf ctxBuf;

    idBuf.reset();
    idBuf.put("ground:type:");
    idBuf.put(name);
    idBuf.put(":");
    idBuf.put(versionString());

    jsonArray1(subjects, name);
    jsonArray1(actors, name);
    jsonArray1(ctxBuf, context);

    enum preds = `["type"]` ~ "\0";
    enum src = "ground\0";
    enum sql = "INSERT OR IGNORE INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return;
    sqlite3_bind_text(stmt, 1, idBuf.ptr(), cast(int) idBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, subjects.ptr(), cast(int) subjects.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, preds.ptr, cast(int) preds.length - 1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, ctxBuf.ptr(), cast(int) ctxBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, actors.ptr(), cast(int) actors.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 6, ts.ptr, cast(int) ts.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 7, src.ptr, cast(int) src.length - 1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 8, attributes.ptr, cast(int) attributes.length, SQLITE_TRANSIENT);

    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}


