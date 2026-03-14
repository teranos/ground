module sqlite;

import matcher : indexOf, contains;
import core.stdc.stdio : fread, fopen, fclose, FILE;
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

// Standalone db at ~/.local/share/graunde/graunde.db — created when QNTX node db is unavailable.
// QNTX users get the shared node db. All array columns are JSON arrays of strings.
// Query pattern: WHERE subjects LIKE '%"value"%' — quotes are part of JSON serialization.

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

// --- DB lifecycle ---

extern (C) {
    const(char)* getenv(const(char)* name);
    int mkdir(const(char)* path, uint mode);
}

// Open graunde's own db at ~/.local/share/graunde/graunde.db
sqlite3* openDb() {
    return openStandaloneDb();
}

sqlite3* openStandaloneDb() {
    auto home = getenv("HOME\0".ptr);
    if (home is null) return null;

    // Build path: $HOME/.local/share/graunde/graunde.db
    __gshared ZBuf pathBuf;
    pathBuf.reset();

    size_t homeLen = 0;
    while (home[homeLen] != 0) homeLen++;
    pathBuf.put(home[0 .. homeLen]);
    pathBuf.put("/.local/share/graunde");

    // mkdir -p: create each directory level
    mkdirP(pathBuf.slice());

    pathBuf.put("/graunde.db");

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

// Check if a Grounded attestation exists for a control in this session,
// and hasn't been invalidated by a subsequent compaction.
bool attestationExists(sqlite3* db, const(char)[] graundedPredicate, const(char)[] controlName, const(char)[] sessionId) {
    __gshared ZBuf ctx;
    ctx.reset();
    ctx.put("%session:");
    ctx.put(sessionId);
    ctx.put("%");

    // Find the control attestation's rowid
    enum sql = "SELECT rowid FROM attestations WHERE predicates LIKE ?1 AND attributes LIKE ?2 AND contexts LIKE ?3 ORDER BY rowid DESC LIMIT 1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return false;

    __gshared ZBuf pred;
    pred.reset();
    pred.put("%");
    pred.put(graundedPredicate);
    pred.put("%");

    __gshared ZBuf ctrl;
    ctrl.reset();
    ctrl.put(`%"control":"`);
    ctrl.put(controlName);
    ctrl.put(`"%`);

    sqlite3_bind_text(stmt, 1, pred.ptr(), cast(int) pred.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, ctrl.ptr(), cast(int) ctrl.len, SQLITE_TRANSIENT);
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
    enum compactSql = "SELECT 1 FROM attestations WHERE predicates LIKE '%PreCompact%' AND contexts LIKE ?1 AND rowid > ?2 LIMIT 1\0";
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

// Extract last two path components from cwd.
// "/Users/s.b.vanhouten/SBVH/teranos/tmp/graunde" → "tmp/graunde"
const(char)[] cwdTail(const(char)[] path) {
    if (path.length == 0) return "unknown";
    // Find last slash
    size_t last = path.length;
    while (last > 0 && path[last - 1] != '/') last--;
    if (last == 0) return path;
    // Find second-to-last slash
    size_t prev = last - 1;
    while (prev > 0 && path[prev - 1] != '/') prev--;
    return path[prev .. $];
}

// Build subject as "parent/repo:branch" for attestations and loom UDP.
// Single source of truth — used by attestEvent and notifyLoomHook.
// Uses the git repo root (not raw cwd) so subdirectories don't change the subject.
void buildSubject(ref ZBuf buf, const(char)[] cwd, const(char)[] branch) {
    buf.reset();
    // Find repo root by walking up to .git
    size_t repoRootLen;
    auto f = findGitHead(cwd, repoRootLen);
    if (f !is null) {
        fclose(f);
        buf.put(cwdTail(gitdirBuf[0 .. repoRootLen]));
    } else {
        buf.put(cwdTail(cwd));
    }
    buf.put(":");
    buf.put(branch);
}

// --- Branch name ---

// NOTE: cwd is passed into popen unescaped. Trusted — comes from Claude Code's hook payload.

// Shared git discovery — walks up from cwd to find .git, returns repo root length
// and opens .git/HEAD for branch reading. Used by both getBranch and getRepoRoot.
__gshared char[512] gitdirBuf = 0;

private FILE* findGitHead(const(char)[] cwd, out size_t repoRootLen) {
    __gshared ZBuf pathBuf;

    // Read .git/HEAD directly — avoids ~46ms popen subprocess
    // Walk up from cwd to find .git (handles subdirectories of a repo)
    // .git can be a directory (normal) or a file (worktrees: "gitdir: /path/...")

    if (cwd.length == 0 || cwd.length >= gitdirBuf.length) { repoRootLen = 0; return null; }
    foreach (i, c; cwd) gitdirBuf[i] = c;
    size_t cwdLen = cwd.length;

    FILE* f = null;
    while (cwdLen > 0) {
        // Try cwd/.git/HEAD (normal repo)
        pathBuf.reset();
        pathBuf.put(gitdirBuf[0 .. cwdLen]);
        pathBuf.put("/.git/HEAD");
        f = fopen(pathBuf.ptr(), "r");
        if (f !is null) break;

        // Try cwd/.git as a file (worktrees)
        pathBuf.reset();
        pathBuf.put(gitdirBuf[0 .. cwdLen]);
        pathBuf.put("/.git");
        f = fopen(pathBuf.ptr(), "r");
        if (f !is null) {
            __gshared char[512] gdBuf = 0;
            auto gn = fread(&gdBuf[0], 1, gdBuf.length - 1, f);
            fclose(f);
            f = null;
            enum gdPrefix = "gitdir: ";
            if (gn > gdPrefix.length && gdBuf[0 .. gdPrefix.length] == gdPrefix) {
                size_t end = gn;
                while (end > 0 && (gdBuf[end - 1] == '\n' || gdBuf[end - 1] == '\r'))
                    end--;
                if (end > gdPrefix.length) {
                    pathBuf.reset();
                    pathBuf.put(gdBuf[gdPrefix.length .. end]);
                    pathBuf.put("/HEAD");
                    f = fopen(pathBuf.ptr(), "r");
                    if (f !is null) break;
                }
            }
        }

        // Walk up one directory
        while (cwdLen > 0 && gitdirBuf[cwdLen - 1] != '/') cwdLen--;
        if (cwdLen > 0) cwdLen--; // skip the '/'
    }

    repoRootLen = cwdLen;
    return f;
}

const(char)[] getBranch(const(char)[] cwd) {
    __gshared char[256] branchBuf = 0;

    size_t repoRootLen;
    auto f = findGitHead(cwd, repoRootLen);
    if (f is null) return "unknown";

    auto n = fread(&branchBuf[0], 1, branchBuf.length - 1, f);
    fclose(f);

    if (n == 0) return "unknown";

    // .git/HEAD contains "ref: refs/heads/<branch>\n"
    enum prefix = "ref: refs/heads/";
    if (n > prefix.length && branchBuf[0 .. prefix.length] == prefix) {
        size_t end = n;
        while (end > 0 && (branchBuf[end - 1] == '\n' || branchBuf[end - 1] == '\r'))
            end--;
        if (end > prefix.length)
            return branchBuf[prefix.length .. end];
    }

    return "unknown";
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

// --- VERSION import ---

enum VERSION = import(".version");

// Trim trailing newline from VERSION
const(char)[] versionString() {
    size_t end = VERSION.length;
    while (end > 0 && (VERSION[end - 1] == '\n' || VERSION[end - 1] == '\r'))
        end--;
    return VERSION[0 .. end];
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

    jsonArray1(actors, "graunde");

    source.reset();
    source.put("graunde ");
    source.put(versionString());

    idBuf.reset();
    idBuf.put("graunde:payload:");
    idBuf.put(eventName);
    idBuf.put(":");
    idBuf.put(ts);

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

// --- Type attestation ---
// Attests a type definition so QNTX knows what to do with the data.
// ID encodes version — re-attested when graunde updates. INSERT OR IGNORE prevents duplicates.

void attestType(sqlite3* db, const(char)[] name, const(char)[] context, const(char)[] attributes) {
    auto ts = formatTimestamp();

    __gshared ZBuf idBuf;
    __gshared ZBuf subjects;
    __gshared ZBuf actors;
    __gshared ZBuf ctxBuf;

    idBuf.reset();
    idBuf.put("graunde:type:");
    idBuf.put(name);
    idBuf.put(":");
    idBuf.put(versionString());

    jsonArray1(subjects, name);
    jsonArray1(actors, name);
    jsonArray1(ctxBuf, context);

    enum preds = `["type"]` ~ "\0";
    enum src = "graunde\0";
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


