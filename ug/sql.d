module sql;

// Reading ground's store, and two writes. ground owns the schema and every row
// the row on screen is a view of. ug inserts a usage reading, because the
// status line is the only place Claude Code hands one out; and it inserts
// what the node left on the row for this token, because ug is the one
// process on this machine that asks the node anything every second.

extern (C) {
    struct sqlite3;
    struct sqlite3_stmt;

    int sqlite3_open_v2(const(char)* filename, sqlite3** db, int flags, const(char)* vfs);
    int sqlite3_busy_timeout(sqlite3* db, int ms);
    int sqlite3_close(sqlite3* db);
    int sqlite3_prepare_v2(sqlite3* db, const(char)* sql, int n, sqlite3_stmt** stmt, const(char)** tail);
    int sqlite3_step(sqlite3_stmt* stmt);
    int sqlite3_finalize(sqlite3_stmt* stmt);
    long sqlite3_column_int64(sqlite3_stmt* stmt, int col);
    const(char)* sqlite3_column_text(sqlite3_stmt* stmt, int col);
    int sqlite3_bind_text(sqlite3_stmt* stmt, int idx, const(char)* text, int n, void* destructor);
    int sqlite3_bind_int64(sqlite3_stmt* stmt, int idx, long value);
    int sqlite3_exec(sqlite3* db, const(char)* sql, void* callback, void* arg, char** errmsg);
    int sqlite3_changes(sqlite3* db);
    long sqlite3_last_insert_rowid(sqlite3* db);
}

enum SQLITE_OK   = 0;
enum SQLITE_ROW  = 100;
enum SQLITE_DONE = 101;

// READONLY cannot create the -shm a WAL database needs, so it fails to open
// and every count silently reads as zero. Read-write is also what the usage
// insert needs.
enum SQLITE_READWRITE = 0x00000002;

// ground writes while ug reads. Without a wait, a contended prepare comes back
// BUSY — a lock ug declined to wait for, not a table it cannot read. 50ms sits
// inside the 300ms debounce, so it costs no frame.
enum BUSY_MS = 50;

// Where the store is. Built from HOME because a fresh process knows nothing
// else about who it belongs to.
// The latest performances for this session, whatever state they are in.
// Filtering to live would delete the verdict at the moment it exists: a halt
// would vanish from the row instead of showing where it stopped.
enum PERFORMANCE_SQL =
    "SELECT ritual, rites, states, current, state, id, " ~
    "COALESCE(thrown_at, 0), COALESCE(acted_at, 0), COALESCE(throws, 0), " ~
    "COALESCE(session, ''), COALESCE(agent_pid, 0), " ~
    "CAST(strftime('%s', updated_at) AS INTEGER) " ~
    "FROM ritual_position " ~
    "WHERE rites IS NOT NULL AND rites != '' " ~
    "AND (parent = ?1 OR session = ?1) " ~
    "ORDER BY updated_at DESC, rowid DESC";

// How many performances one frame will draw. A row taller than the terminal
// is a row nobody can read, and ground has never run more than a handful.
// It bounds the read as well, which is why the query hands over the newest.
enum MAX_PERFORMANCES = 8;

// Column text belongs to sqlite and is freed the moment the statement steps
// on, so each row owns its own copy.
struct Row {
    char[64]  ritualBuf;  size_t ritualLen;
    char[512] ritesBuf;   size_t ritesLen;
    char[64]  statesBuf;  size_t statesLen;
    char[16]  stateBuf;   size_t stateLen;
    char[64]  idBuf;      size_t idLen;
    char[64]  sessionBuf; size_t sessionLen;

    long current;
    long thrownAt;
    long actedAt;
    long throws;
    long agentPid;
    long updatedAt;

    const(char)[] ritual()  const { return ritualBuf[0 .. ritualLen]; }
    const(char)[] rites()   const { return ritesBuf[0 .. ritesLen]; }
    const(char)[] states()  const { return statesBuf[0 .. statesLen]; }
    const(char)[] state()   const { return stateBuf[0 .. stateLen]; }
    const(char)[] id()      const { return idBuf[0 .. idLen]; }
    const(char)[] session() const { return sessionBuf[0 .. sessionLen]; }
}

// How the read went. Nothing found and a query that never ran are different
// answers, and drawing both as no rows made a broken table look like a quiet
// one.
enum Read { ok, noStore, cannotOpen, cannotPrepare, truncated }

struct Reading {
    Read how;
    int rc;
    size_t count;
}

private void copyInto(const(char)* src, char[] dest, ref size_t len) {
    len = 0;
    if (src is null) return;
    while (src[len] != '\0' && len < dest.length) {
        dest[len] = src[len];
        len++;
    }
}

Reading readPerformances(const(char)[] home, const(char)[] sessionId, Row[] rows) {
    import core.stdc.stdio : fopen, fclose;

    __gshared char[512] path = void;
    auto n = dbPathInto(home, path[]);
    if (n == 0) return Reading(Read.noStore, 0, 0);

    // An absent store is a machine where ground has never run, which is not a
    // fault and draws nothing.
    auto probe = fopen(&path[0], "rb");
    if (probe is null) return Reading(Read.noStore, 0, 0);
    fclose(probe);

    sqlite3* db;
    auto rc = sqlite3_open_v2(&path[0], &db, SQLITE_READWRITE, null);
    if (rc != SQLITE_OK) {
        sqlite3_close(db);
        return Reading(Read.cannotOpen, rc, 0);
    }
    sqlite3_busy_timeout(db, BUSY_MS);

    sqlite3_stmt* stmt;
    rc = sqlite3_prepare_v2(db, PERFORMANCE_SQL.ptr, cast(int) PERFORMANCE_SQL.length, &stmt, null);
    if (rc != SQLITE_OK) {
        sqlite3_close(db);
        return Reading(Read.cannotPrepare, rc, 0);
    }

    sqlite3_bind_text(stmt, 1, sessionId.ptr, cast(int) sessionId.length, cast(void*) -1);

    size_t count = 0;
    auto step = sqlite3_step(stmt);
    while (step == SQLITE_ROW && count < rows.length) {
        auto r = &rows[count];
        copyInto(sqlite3_column_text(stmt, 0), r.ritualBuf[],  r.ritualLen);
        copyInto(sqlite3_column_text(stmt, 1), r.ritesBuf[],   r.ritesLen);
        copyInto(sqlite3_column_text(stmt, 2), r.statesBuf[],  r.statesLen);
        r.current = sqlite3_column_int64(stmt, 3);
        copyInto(sqlite3_column_text(stmt, 4), r.stateBuf[],   r.stateLen);
        copyInto(sqlite3_column_text(stmt, 5), r.idBuf[],      r.idLen);
        r.thrownAt = sqlite3_column_int64(stmt, 6);
        r.actedAt = sqlite3_column_int64(stmt, 7);
        r.throws = sqlite3_column_int64(stmt, 8);
        copyInto(sqlite3_column_text(stmt, 9), r.sessionBuf[], r.sessionLen);
        r.agentPid = sqlite3_column_int64(stmt, 10);
        r.updatedAt = sqlite3_column_int64(stmt, 11);

        count++;
        step = sqlite3_step(stmt);
    }

    sqlite3_finalize(stmt);
    sqlite3_close(db);

    // The loop ends on DONE or on an error, and a read cut short otherwise
    // looks exactly like a short table.
    auto how = step == SQLITE_DONE || step == SQLITE_ROW ? Read.ok : Read.truncated;
    return Reading(how, step, count);
}

// An org's Actions minutes as ground last wrote them down. Only rows github
// has answered for: asked and not yet answered is not zero minutes.
enum ORG_MINUTES_SQL = "SELECT org, used, quota FROM org_minutes WHERE used >= 0 ORDER BY org";

enum MAX_ORGS = 8;

struct OrgMinutes {
    char[64] orgBuf;
    size_t orgLen;
    long used;
    long quota;
    const(char)[] org() const return { return orgBuf[0 .. orgLen]; }
}

// How many rows were read. A store that is not there, will not open, or has no
// such table yet reads as none, which draws nothing: the bar says what it knows.
size_t readOrgMinutes(const(char)[] home, OrgMinutes[] rows) {
    import core.stdc.stdio : fopen, fclose;

    __gshared char[512] path = void;
    if (dbPathInto(home, path[]) == 0) return 0;
    auto probe = fopen(&path[0], "rb");
    if (probe is null) return 0;
    fclose(probe);

    sqlite3* db;
    if (sqlite3_open_v2(&path[0], &db, SQLITE_READWRITE, null) != SQLITE_OK) {
        sqlite3_close(db);
        return 0;
    }
    sqlite3_busy_timeout(db, BUSY_MS);

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, ORG_MINUTES_SQL.ptr, cast(int) ORG_MINUTES_SQL.length, &stmt, null) != SQLITE_OK) {
        sqlite3_close(db);
        return 0;
    }

    size_t count = 0;
    while (count < rows.length && sqlite3_step(stmt) == SQLITE_ROW) {
        copyInto(sqlite3_column_text(stmt, 0), rows[count].orgBuf[], rows[count].orgLen);
        rows[count].used = sqlite3_column_int64(stmt, 1);
        rows[count].quota = sqlite3_column_int64(stmt, 2);
        count++;
    }
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return count;
}

// The newest reading of a window, as ug itself wrote it down. A row claimed
// for an ask that has not answered holds -1 and is not a reading.
enum WINDOW_SQL = "SELECT CAST(used_percentage AS INTEGER), resets_at FROM usage "
    ~ "WHERE window = ?1 AND used_percentage >= 0 ORDER BY seen_at DESC, id DESC LIMIT 1";

struct Week {
    bool found;
    long percent;
    long resetsAt;
}

Week readWindow(const(char)[] home, const(char)[] window) {
    import core.stdc.stdio : fopen, fclose;

    Week w;
    __gshared char[512] path = void;
    if (dbPathInto(home, path[]) == 0) return w;
    auto probe = fopen(&path[0], "rb");
    if (probe is null) return w;
    fclose(probe);

    sqlite3* db;
    if (sqlite3_open_v2(&path[0], &db, SQLITE_READWRITE, null) != SQLITE_OK) {
        sqlite3_close(db);
        return w;
    }
    sqlite3_busy_timeout(db, BUSY_MS);

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, WINDOW_SQL.ptr, cast(int) WINDOW_SQL.length, &stmt, null) != SQLITE_OK) {
        sqlite3_close(db);
        return w;
    }
    sqlite3_bind_text(stmt, 1, window.ptr, cast(int) window.length, cast(void*) -1);
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        w.found = true;
        w.percent = sqlite3_column_int64(stmt, 0);
        w.resetsAt = sqlite3_column_int64(stmt, 1);
    }
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return w;
}

// The subscription plan, as ground last asked `claude auth status` for it and
// wrote it down. ground keeps its checks as attestations rather than a table
// of their own, so this is the same query ground's own lastCheck runs; a
// second spelling of where a check lives would drift from it silently.
enum PLAN_SQL = "SELECT json_extract(attributes, '$.value') FROM attestations "
    ~ "WHERE json_extract(subjects, '$[0]') = 'plan' "
    ~ "AND json_extract(predicates, '$[0]') = 'check' "
    ~ "ORDER BY json_extract(attributes, '$.checked_at') DESC, rowid DESC LIMIT 1";

size_t readPlan(const(char)[] home, char[] dest) {
    import core.stdc.stdio : fopen, fclose;

    __gshared char[512] path = void;
    if (dbPathInto(home, path[]) == 0) return 0;
    auto probe = fopen(&path[0], "rb");
    if (probe is null) return 0;
    fclose(probe);

    sqlite3* db;
    if (sqlite3_open_v2(&path[0], &db, SQLITE_READWRITE, null) != SQLITE_OK) {
        sqlite3_close(db);
        return 0;
    }
    sqlite3_busy_timeout(db, BUSY_MS);

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, PLAN_SQL.ptr, cast(int) PLAN_SQL.length, &stmt, null) != SQLITE_OK) {
        sqlite3_close(db);
        return 0;
    }
    size_t n = 0;
    if (sqlite3_step(stmt) == SQLITE_ROW) copyInto(sqlite3_column_text(stmt, 0), dest, n);
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return n;
}

// --- News the node left, written down for sky to carry ---
//
// The node cannot reach this machine. It waits on a CI run where the socket
// is and leaves the result on the row this process already polls, under an
// id, held long enough for a once-a-second poll to see it. ug writes it into
// ground's store in the shape immediate.d's header states, and sky — which
// reads that store and nothing else — carries it to the session that pushed.

// Sky reads the name after the colon and speaks it. Not ci-status: that is
// the fact of a push, the row the node's watcher fires on, and a news row
// under that predicate would be a push that never happened.
enum newsPredicates = `["immediate:news"]`;

// The node's id, prefixed so it cannot collide with the row that caused it —
// a ci-status row's id is the very id the node hands back.
enum NEWS_PREFIX = "immediate:news:";

size_t newsIdInto(const(char)[] id, char[] dest) {
    size_t o = 0;
    foreach (c; NEWS_PREFIX) if (o < dest.length) dest[o++] = c;
    foreach (c; id) if (o < dest.length) dest[o++] = c;
    return o;
}

// To the session that pushed when the node names it; to the project when it
// does not, so every session there hears it (immediate.d's project keying).
size_t newsContextsInto(const(char)[] session, const(char)[] repo, char[] dest) {
    size_t o = 0;
    void put(const(char)[] s) { foreach (c; s) if (o < dest.length) dest[o++] = c; }
    if (session.length > 0) {
        put(`["session:`);
        put(session);
    } else {
        put(`["project:`);
        put(repo);
    }
    put(`"]`);
    return o;
}

// Already written, whatever poll saw it first.
enum NEWS_SEEN_SQL = "SELECT 1 FROM attestations WHERE id = ?1";

// One row, the shape sky reads: detail is what it speaks, after is the gate.
enum NEWS_SQL = "INSERT OR IGNORE INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) "
    ~ "VALUES (?1, '[\"ci\"]', ?2, ?3, '[\"ug\"]', strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'ug', ?4)";

// What goes between the quotes of a JSON string.
private size_t putJsonInto(const(char)[] s, char[] dest, size_t o) {
    foreach (c; s) {
        if (o + 2 > dest.length) break;
        if (c == '"') { dest[o++] = '\\'; dest[o++] = '"'; }
        else if (c == '\\') { dest[o++] = '\\'; dest[o++] = '\\'; }
        else if (c == '\n') { dest[o++] = '\\'; dest[o++] = 'n'; }
        else if (c == '\r') { dest[o++] = '\\'; dest[o++] = 'r'; }
        else if (c == '\t') { dest[o++] = '\\'; dest[o++] = 't'; }
        else if (c < 0x20) continue;
        else dest[o++] = c;
    }
    return o;
}

// Whether the store already holds this item. A store that is not there or will
// not open answers "seen", because writing into it is not possible either.
bool newsSeen(const(char)[] home, const(char)[] id) {
    import core.stdc.stdio : fopen, fclose;

    __gshared char[512] path = void;
    if (dbPathInto(home, path[]) == 0) return true;
    auto probe = fopen(&path[0], "rb");
    if (probe is null) return true;
    fclose(probe);

    __gshared char[256] rowId = void;
    auto n = newsIdInto(id, rowId[]);

    sqlite3* db;
    if (sqlite3_open_v2(&path[0], &db, SQLITE_READWRITE, null) != SQLITE_OK) {
        sqlite3_close(db);
        return true;
    }
    sqlite3_busy_timeout(db, BUSY_MS);

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, NEWS_SEEN_SQL.ptr, cast(int) NEWS_SEEN_SQL.length, &stmt, null) != SQLITE_OK) {
        sqlite3_close(db);
        return true;
    }
    sqlite3_bind_text(stmt, 1, rowId.ptr, cast(int) n, cast(void*) -1);
    auto seen = sqlite3_step(stmt) == SQLITE_ROW;
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return seen;
}

// Writes the item down. True when the row is in the store, whether this call
// put it there or an earlier poll did.
bool leaveNews(const(char)[] home, const(char)[] id, const(char)[] session,
               const(char)[] repo, const(char)[] detail) {
    import core.stdc.stdio : fopen, fclose;

    __gshared char[512] path = void;
    if (dbPathInto(home, path[]) == 0) return false;
    auto probe = fopen(&path[0], "rb");
    if (probe is null) return false;
    fclose(probe);

    __gshared char[256] rowId = void;
    auto idLen = newsIdInto(id, rowId[]);
    __gshared char[512] ctx = void;
    auto ctxLen = newsContextsInto(session, repo, ctx[]);

    __gshared char[4096] attrs = void;
    size_t a = 0;
    foreach (c; `{"detail":"`) attrs[a++] = c;
    a = putJsonInto(detail, attrs[], a);
    foreach (c; `","after":0}`) if (a < attrs.length) attrs[a++] = c;

    sqlite3* db;
    if (sqlite3_open_v2(&path[0], &db, SQLITE_READWRITE, null) != SQLITE_OK) {
        sqlite3_close(db);
        return false;
    }
    sqlite3_busy_timeout(db, BUSY_MS);

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, NEWS_SQL.ptr, cast(int) NEWS_SQL.length, &stmt, null) != SQLITE_OK) {
        sqlite3_close(db);
        return false;
    }
    sqlite3_bind_text(stmt, 1, rowId.ptr, cast(int) idLen, cast(void*) -1);
    sqlite3_bind_text(stmt, 2, newsPredicates.ptr, cast(int) newsPredicates.length, cast(void*) -1);
    sqlite3_bind_text(stmt, 3, ctx.ptr, cast(int) ctxLen, cast(void*) -1);
    sqlite3_bind_text(stmt, 4, attrs.ptr, cast(int) a, cast(void*) -1);
    auto rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return rc == SQLITE_DONE;
}

enum STORE = ".local/share/ground/ground.db";

size_t dbPathInto(const(char)[] home, char[] dest) {
    if (home.length == 0) return 0;
    if (home.length + STORE.length + 2 > dest.length) return 0;

    size_t o = 0;
    foreach (c; home) dest[o++] = c;
    if (dest[o - 1] != '/') dest[o++] = '/';
    foreach (c; STORE) dest[o++] = c;
    dest[o] = 0;
    return o;
}
