module db;

import matcher : indexOf, contains;
import core.stdc.stdio : FILE;
import core.stdc.time : time, time_t, tm, gmtime;

// --- sqlite3 C bindings (minimal) ---

struct sqlite3;
struct sqlite3_stmt;

enum SQLITE_OK = 0;
enum SQLITE_BUSY = 5;
enum SQLITE_CORRUPT = 11;   // malformed disk image — the store is damaged
enum SQLITE_NOTADB = 26;    // not a database file at all
enum SQLITE_ROW = 100;
enum SQLITE_DONE = 101;
enum SQLITE_TRANSIENT = cast(void function(void*)) -1;

// A damaged store is a blocker for everything ground does, and it cannot be
// reported through the store. Every read loop written as
// `while (sqlite3_step(stmt) == SQLITE_ROW)` exits after zero iterations on
// SQLITE_CORRUPT — byte-identical to a query that matched nothing. So every
// counter reads 0, every reader reads null, and a destroyed database presents
// as a calm, idle, working system. Ground must refuse to run instead.
bool isCorruptionCode(int code) {
    return code == SQLITE_CORRUPT || code == SQLITE_NOTADB;
}

// Verdict for this process. Each hook is a fresh process that opens the store
// itself, so whoever asks finds out — no sentinel to poll, no state to carry
// between invocations. The failure branch already runs; it just used to say
// nothing.
private __gshared int g_dbFailCode;

void resetDbFailure() { g_dbFailCode = 0; }
void noteDbFailure(int code) { g_dbFailCode = code; }
bool dbUnusable() { return isCorruptionCode(g_dbFailCode); }

// The report. Goes out on the hook's own stderr, never through the store —
// the store is the thing that is broken. Names the file and carries the
// recovery command, because a blocker the user has to go research is a
// blocker twice.
const(char)[] dbFailureMessage() {
    if (!dbUnusable()) return null;

    __gshared ZBuf buf;
    buf.reset();
    buf.put("ground error: the attestation database is damaged (sqlite code ");
    {
        char[8] nb = 0;
        int nl = 0;
        int v = g_dbFailCode;
        if (v == 0) { nb[0] = '0'; nl = 1; }
        else { while (v > 0 && nl < 7) { nb[nl++] = cast(char)('0' + v % 10); v /= 10; } }
        foreach_reverse (i; 0 .. nl) buf.putChar(nb[i]);
    }
    buf.put("). ground has stopped: every control, attestation and message ");
    buf.put("depends on this store, and a damaged one reads as empty rather ");
    buf.put("than broken — so continuing would report all-clear while losing ");
    buf.put("everything. File: ~/.local/share/ground/ground.db — recover with: ");
    buf.put("sqlite3 ~/.local/share/ground/ground.db .recover > /tmp/g.sql ");
    buf.put("(do not VACUUM, it can destroy what is still readable)");
    return buf.slice();
}

unittest {
    assert(isCorruptionCode(SQLITE_CORRUPT), "malformed image is corruption");
    assert(isCorruptionCode(SQLITE_NOTADB), "not-a-database is corruption");
    assert(!isCorruptionCode(SQLITE_OK));
    assert(!isCorruptionCode(SQLITE_BUSY), "lock contention is transient, not damage");
    assert(!isCorruptionCode(SQLITE_ROW));
    assert(!isCorruptionCode(SQLITE_DONE));
}

unittest {
    // Nothing observed yet — ground runs normally. Absence of a verdict must
    // not read as a failure, or every healthy session would halt.
    resetDbFailure();
    assert(!dbUnusable());
    assert(dbFailureMessage() is null);
}

unittest {
    // Once corruption is observed the verdict is loud, names the file, and
    // carries the recovery command — the message has to be actionable without
    // the user going and looking anything up.
    resetDbFailure();
    noteDbFailure(SQLITE_CORRUPT);
    assert(dbUnusable(), "ground must refuse to run on a damaged store");

    auto msg = dbFailureMessage();
    assert(msg !is null);
    import matcher : contains;
    assert(contains(msg, "ground.db"), "must name the file");
    assert(contains(msg, ".recover"), "must carry the recovery path");
    resetDbFailure();
}

unittest {
    // Lock contention is not damage and must not halt ground.
    resetDbFailure();
    noteDbFailure(SQLITE_BUSY);
    assert(!dbUnusable(), "transient busy must not stop the world");
    resetDbFailure();
}

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
    int sqlite3_changes(sqlite3* db);
    int sqlite3_errcode(sqlite3* db);
}

extern (C) {
    FILE* popen(const(char)* command, const(char)* type);
    int pclose(FILE* stream);
}

// All array columns are JSON arrays of strings.
// Query pattern: WHERE subjects LIKE '%"value"%' — quotes are part of JSON serialization.

public import zbuf : ZBuf;

// --- DB lifecycle ---

extern (C) {
    const(char)* getenv(const(char)* name);
    int mkdir(const(char)* path, uint mode);
    int getpid();
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
        if (db !is null) {
            noteDbFailure(sqlite3_errcode(db));
            sqlite3_close(db);
        }
        return null;
    }

    // Disable auto-checkpoint — explicit checkpoints in SessionStart/PreCompact only.
    // Prevents random 1-2s stalls when WAL crosses 4MB threshold on a large db.
    sqlite3_exec(db, "PRAGMA wal_autocheckpoint = 0\0".ptr, null, null, null);

    // 5s busy timeout — SQLite handles retries internally on lock
    // contention rather than immediately returning SQLITE_BUSY. Necessary
    // for exec wrappers to reliably persist their result rows when the
    // main ground hook + watch + other wrappers are all writing.
    sqlite3_exec(db, "PRAGMA busy_timeout = 5000\0".ptr, null, null, null);

    if (!applySchema(db)) {
        sqlite3_close(db);
        return null;
    }

    return db;
}

// The schema, in one place, applied to whatever handle is given. openDb calls
// it for the real store; tests call it for an in-memory one. Nothing else may
// write a CREATE TABLE: a second copy of the schema drifts from this one
// silently, and a test asserting against a schema the product does not have is
// worse than no test.
// Does the store already have this column? PRAGMA table_info returns nothing
// for a table that does not exist, so an absent table reads as absent columns.
bool hasColumn(sqlite3* db, const(char)[] table, const(char)[] column) {
    __gshared ZBuf sql;
    sql.reset();
    sql.put("PRAGMA table_info(");
    sql.put(table);
    sql.put(")");

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr(), -1, &stmt, null) != SQLITE_OK) return false;

    bool found = false;
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        auto name = sqlite3_column_text(stmt, 1);
        if (name is null) continue;
        size_t i = 0;
        while (i < column.length && name[i] != 0 && name[i] == column[i]) i++;
        if (i == column.length && name[i] == 0) { found = true; break; }
    }
    sqlite3_finalize(stmt);
    return found;
}

// A CREATE TABLE IF NOT EXISTS is a no-op against a store that already has an
// older shape, so the schema and the store drift while every test stays green
// — tests open :memory: and always get the new shape.
private bool ensureColumn(sqlite3* db, const(char)[] table, const(char)[] column, const(char)[] decl) {
    if (hasColumn(db, table, column)) return true;

    __gshared ZBuf sql;
    sql.reset();
    sql.put("ALTER TABLE ");
    sql.put(table);
    sql.put(" ADD COLUMN ");
    sql.put(column);
    sql.put(" ");
    sql.put(decl);

    if (sqlite3_exec(db, sql.ptr(), null, null, null) == SQLITE_OK) return true;
    noteDbFailure(sqlite3_errcode(db));
    return false;
}

bool applySchema(sqlite3* db) {
    enum schema = "CREATE TABLE IF NOT EXISTS attestations ("
        ~ "id TEXT PRIMARY KEY, subjects JSON NOT NULL, predicates JSON NOT NULL, "
        ~ "contexts JSON NOT NULL, actors JSON NOT NULL, timestamp DATETIME NOT NULL, "
        ~ "source TEXT NOT NULL DEFAULT 'cli', attributes JSON, "
        ~ "created_at DATETIME DEFAULT CURRENT_TIMESTAMP)\0";

    // The schema exec is the first real read of the B-tree, so damage lands
    // here. Ask sqlite what went wrong before discarding the handle — this
    // branch already ran on every corrupt open, it just returned in silence.
    if (sqlite3_exec(db, schema.ptr, null, null, null) != SQLITE_OK) {
        noteDbFailure(sqlite3_errcode(db));
        return false;
    }

    enum sessionProjectSchema = "CREATE TABLE IF NOT EXISTS session_project ("
        ~ "session_id TEXT PRIMARY KEY, project TEXT NOT NULL)\0";
    sqlite3_exec(db, sessionProjectSchema.ptr, null, null, null);

    // Keyed on the performance, not on where it happens. The worktree is an
    // index: removing the tree loses a route to the record, not the record.
    enum ritualPositionSchema = "CREATE TABLE IF NOT EXISTS ritual_position ("
        ~ "id TEXT PRIMARY KEY, repo TEXT NOT NULL, ritual TEXT NOT NULL, "
        ~ "branch TEXT, worktree TEXT, current INTEGER NOT NULL, "
        ~ "states TEXT NOT NULL, state TEXT NOT NULL, rites TEXT, "
        ~ "updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)\0";
    sqlite3_exec(db, ritualPositionSchema.ptr, null, null, null);

    // collet renders the line from the row alone. Without the names it has
    // glyphs and a cursor and nothing to put brackets around.
    ensureColumn(db, "ritual_position", "rites", "TEXT");

    // Who carries the performance. SessionStart writes it, from inside the
    // background session that is doing the walk.
    ensureColumn(db, "ritual_position", "session", "TEXT");
    ensureColumn(db, "ritual_position", "agent", "TEXT");
    ensureColumn(db, "ritual_position", "gotos", "INTEGER NOT NULL DEFAULT 0");
    ensureColumn(db, "ritual_position", "parent", "TEXT");
    ensureColumn(db, "ritual_position", "agent_pid", "INTEGER NOT NULL DEFAULT 0");
    ensureColumn(db, "ritual_position", "thrown_at", "INTEGER NOT NULL DEFAULT 0");
    ensureColumn(db, "ritual_position", "throws", "INTEGER NOT NULL DEFAULT 0");
    // What throws cannot answer once the walk has moved on: how often the
    // world was not ready. Rows written before this read 0, not "never held".
    ensureColumn(db, "ritual_position", "holds", "INTEGER NOT NULL DEFAULT 0");
    ensureColumn(db, "ritual_position", "evals", "INTEGER NOT NULL DEFAULT 0");
    ensureColumn(db, "ritual_position", "rev", "INTEGER NOT NULL DEFAULT 0");
    ensureColumn(db, "ritual_position", "mic", "TEXT NOT NULL DEFAULT 'ground'");
    ensureColumn(db, "ritual_position", "mic_at", "INTEGER NOT NULL DEFAULT 0");
    ensureColumn(db, "ritual_position", "said", "INTEGER NOT NULL DEFAULT 0");
    ensureColumn(db, "ritual_position", "spoke", "INTEGER NOT NULL DEFAULT 0");
    ensureColumn(db, "ritual_position", "acted_at", "INTEGER NOT NULL DEFAULT 0");

    enum idxRitualRepo = "CREATE INDEX IF NOT EXISTS idx_ritual_position_repo ON ritual_position(repo, state)\0";
    enum idxRitualTree = "CREATE INDEX IF NOT EXISTS idx_ritual_position_worktree ON ritual_position(worktree)\0";
    sqlite3_exec(db, idxRitualRepo.ptr, null, null, null);
    sqlite3_exec(db, idxRitualTree.ptr, null, null, null);

    // Was in main.d's recordTiming: a CREATE TABLE in the one place the rule
    // above forbids one, and three ALTER TABLEs whose failures went nowhere.
    enum timingSchema = "CREATE TABLE IF NOT EXISTS timing (id INTEGER PRIMARY KEY, "
        ~ "duration_us INTEGER NOT NULL, hook_event TEXT, "
        ~ "created_at DATETIME DEFAULT CURRENT_TIMESTAMP)\0";
    sqlite3_exec(db, timingSchema.ptr, null, null, null);

    ensureColumn(db, "timing", "hook_event", "TEXT");
    ensureColumn(db, "timing", "project", "TEXT");
    ensureColumn(db, "timing", "phases", "TEXT");

    enum idxTiming = "CREATE INDEX IF NOT EXISTS idx_timing_event_project ON timing(hook_event, project, id)\0";
    sqlite3_exec(db, idxTiming.ptr, null, null, null);

    enum idxPredicate = "CREATE INDEX IF NOT EXISTS idx_attestations_predicate ON attestations(json_extract(predicates, '$[0]'))\0";
    enum idxControl = "CREATE INDEX IF NOT EXISTS idx_attestations_control ON attestations(json_extract(attributes, '$.control'))\0";
    enum idxSubject = "CREATE INDEX IF NOT EXISTS idx_attestations_subject ON attestations(json_extract(subjects, '$[0]'))\0";
    enum idxPredSession = "CREATE INDEX IF NOT EXISTS idx_attestations_pred_session ON attestations(json_extract(predicates, '$[0]'), json_extract(contexts, '$[0]'))\0";
    enum idxSubjectTs = "CREATE INDEX IF NOT EXISTS idx_attestations_subject_ts ON attestations(json_extract(subjects, '$[0]'), timestamp DESC)\0";
    sqlite3_exec(db, idxPredicate.ptr, null, null, null);
    sqlite3_exec(db, idxControl.ptr, null, null, null);
    sqlite3_exec(db, idxSubject.ptr, null, null, null);
    sqlite3_exec(db, idxPredSession.ptr, null, null, null);
    sqlite3_exec(db, idxSubjectTs.ptr, null, null, null);

    return true;
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
    ctx.put("session:");
    ctx.put(sessionId);

    // Find the control attestation's rowid — uses compound (predicate, session) index
    enum sql = "SELECT rowid FROM attestations WHERE json_extract(predicates, '$[0]') = ?1 AND json_extract(attributes, '$.control') = ?2 AND json_extract(contexts, '$[0]') = ?3 ORDER BY rowid DESC LIMIT 1\0";
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
    enum compactSql = "SELECT 1 FROM attestations WHERE json_extract(predicates, '$[0]') = 'PreCompact' AND json_extract(contexts, '$[0]') = ?1 AND rowid > ?2 LIMIT 1\0";
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

// Check if a Read/Write/Edit attestation exists for a filename in this session.
// Any of these tools means Claude has seen or produced the file contents.
// Matches against tool_input.file_path to avoid false positives from file contents.
bool fileAttestationExists(sqlite3* db, const(char)[] filename, const(char)[] sessionId) {
    __gshared ZBuf ctx, filePat;

    ctx.reset();
    ctx.put("session:");
    ctx.put(sessionId);

    // Match file_path ending with the filename (covers absolute paths)
    filePat.reset();
    filePat.put("%/");
    filePat.put(filename);
    filePat.put("%");

    // Find the most recent matching file attestation
    enum sql = "SELECT rowid FROM attestations WHERE json_extract(predicates, '$[0]') = 'PostToolUse' AND json_extract(contexts, '$[0]') = ?1 AND json_extract(attributes, '$.tool_name') IN ('Read', 'Write', 'Edit') AND json_extract(attributes, '$.tool_input.file_path') LIKE ?2 ORDER BY rowid DESC LIMIT 1\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return false;

    sqlite3_bind_text(stmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, filePat.ptr(), cast(int) filePat.len, SQLITE_TRANSIENT);

    bool found = sqlite3_step(stmt) == SQLITE_ROW;
    if (!found) {
        sqlite3_finalize(stmt);
        return false;
    }

    auto fileRowid = sqlite3_column_int64(stmt, 0);
    sqlite3_finalize(stmt);

    // Check if a compaction happened after — invalidates the attestation
    enum compactSql = "SELECT 1 FROM attestations WHERE json_extract(predicates, '$[0]') = 'PreCompact' AND json_extract(contexts, '$[0]') = ?1 AND rowid > ?2 LIMIT 1\0";
    sqlite3_stmt* compactStmt;
    if (sqlite3_prepare_v2(db, compactSql.ptr, -1, &compactStmt, null) != SQLITE_OK)
        return true; // can't check, assume valid

    sqlite3_bind_text(compactStmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
    sqlite3_bind_int64(compactStmt, 2, fileRowid);

    bool compacted = sqlite3_step(compactStmt) == SQLITE_ROW;
    sqlite3_finalize(compactStmt);

    return !compacted;
}

// Check if session has Write/Edit attestations matching a path pattern.
// pattern is a substring match against tool_input.file_path (like contains).
bool editAttestationContains(sqlite3* db, const(char)[] pattern, const(char)[] sessionId) {
    __gshared ZBuf ctx, filePat;

    ctx.reset();
    ctx.put("session:");
    ctx.put(sessionId);

    filePat.reset();
    filePat.put("%");
    filePat.put(pattern);
    filePat.put("%");

    enum sql = "SELECT 1 FROM attestations WHERE json_extract(predicates, '$[0]') = 'PostToolUse' AND json_extract(contexts, '$[0]') = ?1 AND json_extract(attributes, '$.tool_name') IN ('Write', 'Edit') AND json_extract(attributes, '$.tool_input.file_path') LIKE ?2 LIMIT 1\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return false;

    sqlite3_bind_text(stmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, filePat.ptr(), cast(int) filePat.len, SQLITE_TRANSIENT);

    bool found = sqlite3_step(stmt) == SQLITE_ROW;
    sqlite3_finalize(stmt);
    return found;
}

// Check if session has Write/Edit attestations that DON'T match ANY of the given patterns.
// Used for subtractive edited: scope — returns true if edits exist outside the listed paths.
// Temporal: git push resets the baseline — only edits AFTER the last push count.
// Scoped to cwd so incidental edits (e.g. .claude/MEMORY.md) don't leak through.
bool editAttestationOutside(sqlite3* db, const(char)[]* patterns, size_t patCount,
    const(char)[] sessionId, const(char)[] cwd)
{
    __gshared ZBuf ctx, sqlBuf, cwdPat;

    ctx.reset();
    ctx.put("session:");
    ctx.put(sessionId);

    cwdPat.reset();
    cwdPat.put("%");
    cwdPat.put(cwd);
    cwdPat.put("%");

    // Build: SELECT 1 FROM attestations WHERE ... AND file_path LIKE %cwd%
    //   AND rowid > COALESCE((last git push rowid), 0)
    //   AND file_path NOT LIKE %p1% ...
    sqlBuf.reset();
    sqlBuf.put("SELECT 1 FROM attestations WHERE json_extract(predicates, '$[0]') = 'PostToolUse' AND json_extract(contexts, '$[0]') = ?1 AND json_extract(attributes, '$.tool_name') IN ('Write', 'Edit') AND json_extract(attributes, '$.tool_input.file_path') LIKE ?2");
    sqlBuf.put(" AND rowid > COALESCE((SELECT MAX(rowid) FROM attestations WHERE json_extract(predicates, '$[0]') = 'PostToolUse' AND json_extract(contexts, '$[0]') = ?1 AND json_extract(attributes, '$.tool_name') = 'Bash' AND json_extract(attributes, '$.tool_input.command') LIKE '%git push%'), 0)");
    foreach (i; 0 .. patCount) {
        sqlBuf.put(" AND json_extract(attributes, '$.tool_input.file_path') NOT LIKE ?");
        sqlBuf.putChar(cast(char)('3' + i));
    }
    sqlBuf.put(" LIMIT 1");
    sqlBuf.putChar('\0');

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sqlBuf.ptr(), -1, &stmt, null) != SQLITE_OK)
        return false;

    sqlite3_bind_text(stmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, cwdPat.ptr(), cast(int) cwdPat.len, SQLITE_TRANSIENT);

    __gshared ZBuf[8] patBufs;
    foreach (i; 0 .. patCount) {
        patBufs[i].reset();
        patBufs[i].put("%");
        patBufs[i].put(patterns[i]);
        patBufs[i].put("%");
        sqlite3_bind_text(stmt, cast(int)(3 + i), patBufs[i].ptr(), cast(int) patBufs[i].len, SQLITE_TRANSIENT);
    }

    bool found = sqlite3_step(stmt) == SQLITE_ROW;
    sqlite3_finalize(stmt);
    return found;
}

// Check if a Bash command matching a pattern was run this session.
bool cmdAttestationExists(sqlite3* db, const(char)[] cmdPattern, const(char)[] sessionId) {
    __gshared ZBuf ctx, cmdPat;

    ctx.reset();
    ctx.put("session:");
    ctx.put(sessionId);

    cmdPat.reset();
    cmdPat.put("%");
    cmdPat.put(cmdPattern);
    cmdPat.put("%");

    enum sql = "SELECT 1 FROM attestations WHERE json_extract(predicates, '$[0]') = 'PostToolUse' AND json_extract(contexts, '$[0]') = ?1 AND json_extract(attributes, '$.tool_name') = 'Bash' AND json_extract(attributes, '$.tool_input.command') LIKE ?2 LIMIT 1\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return false;

    sqlite3_bind_text(stmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, cmdPat.ptr(), cast(int) cmdPat.len, SQLITE_TRANSIENT);

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
    attestEventAt(db, eventName, cwd, sessionId, payload, formatTimestamp(), getpid());
}

// Same, with the two values that differ between concurrent hooks supplied
// rather than read from the environment: the second they landed in, and which
// process they were. Both are needed to reproduce the collision in a test, and
// neither can be observed from inside a single test process.
void attestEventAt(
    sqlite3* db,
    const(char)[] eventName,
    const(char)[] cwd,
    const(char)[] sessionId,
    const(char)[] payload,
    const(char)[] ts,
    int pid
) {
    auto branch = getBranch(cwd);
    if (branch is null) branch = "unknown";

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

    // The pid is what makes two hooks in the same second two facts rather than
    // one. Every hook is its own ground process, so the pid identifies the
    // invocation exactly, and a single process re-attesting the same event
    // still collapses to one row, which is the deduplication INSERT OR IGNORE
    // was there to provide.
    //
    // Timestamp resolution is one second and the timestamp column is compared
    // as text elsewhere, so widening it was not an option. The discriminator
    // belongs in the id, which nothing reads by format.
    idBuf.reset();
    idBuf.put("ground:payload:");
    idBuf.put(eventName);
    idBuf.put(":");
    idBuf.put(ts);
    idBuf.put(":");
    idBuf.putUint(pid);

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

    // Every hook of every session lands here, which makes this the one write
    // that touches the damaged trees on every invocation — the schema tree
    // openDb reads can be intact while the table and its indexes are not, so
    // a corrupt store opens cleanly and only fails once real data moves.
    // Discarding this return is what let that stay invisible.
    if (sqlite3_step(stmt) != SQLITE_DONE)
        noteDbFailure(sqlite3_errcode(db));
    sqlite3_finalize(stmt);

    // Fire-and-forget UDP to loom
    import loom : sendToLoom;
    sendToLoom(subjects, predicates, contexts, payload);
}

unittest {
    // Tool calls run in parallel, so several hooks of the same type stamping
    // one second is the normal case. The id carries the pid; without it the
    // second event cannot land.
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);
    assert(applySchema(db), "test runs against the product schema, not a copy of it");

    enum sameSecond = "2026-07-28T09:49:50Z";
    attestEventAt(db, "PreToolUse", "/tmp", "sess-parallel", `{"probe":"alpha"}`, sameSecond, 4111);
    attestEventAt(db, "PreToolUse", "/tmp", "sess-parallel", `{"probe":"charlie"}`, sameSecond, 4112);
    assert(attestationRowCount(db) == 2,
           "both hook events must be stored; one was silently dropped");

    // The deduplication INSERT OR IGNORE provides has to survive the fix. One
    // process re-attesting the same event is a repeat, not a new fact.
    attestEventAt(db, "PreToolUse", "/tmp", "sess-parallel", `{"probe":"alpha"}`, sameSecond, 4111);
    assert(attestationRowCount(db) == 2,
           "a repeat from the same process must not create a second row");

    sqlite3_close(db);
}

version (unittest)
private long attestationRowCount(sqlite3* db) {
    enum countSql = "SELECT COUNT(*) FROM attestations\0";
    sqlite3_stmt* stmt;
    assert(sqlite3_prepare_v2(db, countSql.ptr, -1, &stmt, null) == SQLITE_OK);
    assert(sqlite3_step(stmt) == SQLITE_ROW);
    auto rows = sqlite3_column_int64(stmt, 0);
    sqlite3_finalize(stmt);
    return rows;
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

// Exec-fire attestation keyed on (control, session, tool_use_id). Dedup at
// tool-call granularity — each Claude Code tool call has a unique
// tool_use_id, so repeated PostToolUse invocations for the same tool call
// see the fire and skip. Distinct tool calls each fire once.
void attestExecFire(sqlite3* db, const(char)[] controlName, const(char)[] cwd,
                    const(char)[] sessionId, const(char)[] toolUseId) {
    __gshared ZBuf efAttrs;
    efAttrs.reset();
    efAttrs.put(`{"control":"`);
    efAttrs.put(controlName);
    efAttrs.put(`","tool_use_id":"`);
    efAttrs.put(toolUseId);
    efAttrs.put(`"}`);

    bool ownDb = db is null;
    if (ownDb) {
        db = openDb();
        if (db is null) return;
    }
    attestEvent(db, "GroundedExec", cwd, sessionId, efAttrs.slice());
    if (ownDb) sqlite3_close(db);
}

bool execFireExists(sqlite3* db, const(char)[] controlName,
                    const(char)[] sessionId, const(char)[] toolUseId) {
    __gshared ZBuf ctx;
    ctx.reset();
    ctx.put("session:");
    ctx.put(sessionId);

    enum sql = "SELECT 1 FROM attestations WHERE json_extract(predicates, '$[0]') = 'GroundedExec' AND json_extract(attributes, '$.control') = ?1 AND json_extract(attributes, '$.tool_use_id') = ?2 AND json_extract(contexts, '$[0]') = ?3 LIMIT 1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return false;
    sqlite3_bind_text(stmt, 1, controlName.ptr, cast(int) controlName.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, toolUseId.ptr, cast(int) toolUseId.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
    bool found = sqlite3_step(stmt) == SQLITE_ROW;
    sqlite3_finalize(stmt);
    return found;
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


