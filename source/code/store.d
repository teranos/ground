module code.store;

// Ground code's sessions in ground's store, so that one outlives the process
// that opened it. Every function answers whether the store did what it asked:
// a refusal is said to the client, never taken for "no such session".

import db : sqlite3, sqlite3_stmt, sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_bind_int64,
    sqlite3_step, sqlite3_finalize, sqlite3_column_text, sqlite3_column_int64, sqlite3_changes,
    SQLITE_OK, SQLITE_ROW, SQLITE_DONE, SQLITE_TRANSIENT;
import sessionmode : SessionMode, parseSessionMode, nameOf;
import code.reply : Reply;

private void bind(sqlite3_stmt* st, int idx, const(char)[] s) {
    sqlite3_bind_text(st, idx, s.ptr, cast(int) s.length, SQLITE_TRANSIENT);
}

private const(char)[] text(sqlite3_stmt* st, int col) {
    auto p = cast(const(char)*) sqlite3_column_text(st, col);
    if (p is null) return "";
    size_t n = 0;
    while (p[n] != 0) n++;
    return p[0 .. n];
}

bool storeOpen(sqlite3* db, const(char)[] id, const(char)[] cwd, const(char)[] dirs,
        const(char)[] effort, long now) {
    sqlite3_stmt* st;
    enum sql = "INSERT INTO code_session (id, cwd, opened_at, dirs, effort, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?3)\0";
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &st, null) != SQLITE_OK) return false;
    bind(st, 1, id);
    bind(st, 2, cwd);
    sqlite3_bind_int64(st, 3, now);
    bind(st, 4, dirs);
    bind(st, 5, effort);
    auto ok = sqlite3_step(st) == SQLITE_DONE;
    sqlite3_finalize(st);
    return ok;
}

bool storeClose(sqlite3* db, const(char)[] id, long now) {
    sqlite3_stmt* st;
    enum sql = "UPDATE code_session SET closed_at = ?2 WHERE id = ?1 AND closed_at = 0\0";
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &st, null) != SQLITE_OK) return false;
    bind(st, 1, id);
    sqlite3_bind_int64(st, 2, now);
    auto ok = sqlite3_step(st) == SQLITE_DONE;
    sqlite3_finalize(st);
    return ok;
}

// Resumes an open session: its cwd is its own for its life, so a resume names
// the same one, and the additional roots it names replace the ones kept. The
// mode and effort it was left at are read back, the effort into effort. 1
// resumed, 0 no open session by that id,
// 2 the session is in another cwd (written into storedCwd), 3 up refused it,
// -1 the store refused.
int storeResume(sqlite3* db, const(char)[] id, const(char)[] cwd, const(char)[] dirs,
        ref SessionMode mode, char[] storedCwd, ref size_t storedLen, char[] effort, ref size_t effortLen, long now,
        scope bool delegate() up = null) {
    sqlite3_stmt* st;
    enum find = "SELECT cwd, mode, effort FROM code_session WHERE id = ?1 AND closed_at = 0\0";
    if (sqlite3_prepare_v2(db, find.ptr, -1, &st, null) != SQLITE_OK) return -1;
    bind(st, 1, id);
    auto rc = sqlite3_step(st);
    if (rc == SQLITE_DONE) { sqlite3_finalize(st); return 0; }
    if (rc != SQLITE_ROW) { sqlite3_finalize(st); return -1; }
    auto was = text(st, 0);
    mode = parseSessionMode(text(st, 1));
    effortLen = 0;
    foreach (c; text(st, 2)) if (effortLen < effort.length) effort[effortLen++] = c;
    bool same = was == cwd;
    storedLen = 0;
    if (!same) foreach (c; was) if (storedLen < storedCwd.length) storedCwd[storedLen++] = c;
    sqlite3_finalize(st);
    if (mode == SessionMode.unknown) return -1;
    if (!same) return 2;
    // What has to come up for the session to be resumed, before its row says it was.
    if (up !is null && !up()) return 3;

    enum keep = "UPDATE code_session SET dirs = ?2, updated_at = ?3 WHERE id = ?1 AND closed_at = 0\0";
    if (sqlite3_prepare_v2(db, keep.ptr, -1, &st, null) != SQLITE_OK) return -1;
    bind(st, 1, id);
    bind(st, 2, dirs);
    sqlite3_bind_int64(st, 3, now);
    rc = sqlite3_step(st);
    sqlite3_finalize(st);
    return rc == SQLITE_DONE ? 1 : -1;
}

// Keeps the mode a session was set to. 1 kept, 0 no open session by that id,
// -1 the store refused.
int storeSetMode(sqlite3* db, const(char)[] id, SessionMode mode, long now) {
    sqlite3_stmt* st;
    enum sql = "UPDATE code_session SET mode = ?2, updated_at = ?3 WHERE id = ?1 AND closed_at = 0\0";
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &st, null) != SQLITE_OK) return -1;
    bind(st, 1, id);
    bind(st, 2, nameOf(mode));
    sqlite3_bind_int64(st, 3, now);
    auto rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return -1;
    return sqlite3_changes(db) > 0 ? 1 : 0;
}

// Keeps the effort a session was set to. 1 kept, 0 no open session by that
// id, -1 the store refused.
int storeSetEffort(sqlite3* db, const(char)[] id, const(char)[] effort, long now) {
    sqlite3_stmt* st;
    enum sql = "UPDATE code_session SET effort = ?2, updated_at = ?3 WHERE id = ?1 AND closed_at = 0\0";
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &st, null) != SQLITE_OK) return -1;
    bind(st, 1, id);
    bind(st, 2, effort);
    sqlite3_bind_int64(st, 3, now);
    auto rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return -1;
    return sqlite3_changes(db) > 0 ? 1 : 0;
}

// Marks a session active now, as a prompt does. 1 marked, 0 no open session
// by that id, -1 the store refused.
// Keeps an open session's conversation. 1 kept, 0 no open session by that
// id, -1 the store refused.
int storeHistory(sqlite3* db, const(char)[] id, const(char)[] history) {
    sqlite3_stmt* st;
    enum sql = "UPDATE code_session SET history = ?2 WHERE id = ?1 AND closed_at = 0\0";
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &st, null) != SQLITE_OK) return -1;
    bind(st, 1, id);
    bind(st, 2, history);
    auto rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return -1;
    return sqlite3_changes(db) > 0 ? 1 : 0;
}

// An open session's conversation, into history. 1 read, 0 no open session by
// that id, -1 the store refused.
int storeHistoryOf(sqlite3* db, const(char)[] id, ref Reply history) {
    sqlite3_stmt* st;
    enum sql = "SELECT history FROM code_session WHERE id = ?1 AND closed_at = 0\0";
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &st, null) != SQLITE_OK) return -1;
    bind(st, 1, id);
    auto rc = sqlite3_step(st);
    if (rc == SQLITE_ROW) history.add(text(st, 0));
    sqlite3_finalize(st);
    if (rc == SQLITE_DONE) return 0;
    return rc == SQLITE_ROW && !history.full ? 1 : -1;
}

int storeTouch(sqlite3* db, const(char)[] id, long now) {
    sqlite3_stmt* st;
    enum sql = "UPDATE code_session SET updated_at = ?2 WHERE id = ?1 AND closed_at = 0\0";
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &st, null) != SQLITE_OK) return -1;
    bind(st, 1, id);
    sqlite3_bind_int64(st, 2, now);
    auto rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return -1;
    return sqlite3_changes(db) > 0 ? 1 : 0;
}

// Names an open session that has no title yet. 1 named, 0 no open session by
// that id without one, -1 the store refused.
int storeTitle(sqlite3* db, const(char)[] id, const(char)[] title) {
    sqlite3_stmt* st;
    enum sql = "UPDATE code_session SET title = ?2 WHERE id = ?1 AND closed_at = 0 AND title = ''\0";
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &st, null) != SQLITE_OK) return -1;
    bind(st, 1, id);
    bind(st, 2, title);
    auto rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return -1;
    return sqlite3_changes(db) > 0 ? 1 : 0;
}

// Clears an open session's title, so the next prompt names it. 1 cleared, 0
// no open session by that id, -1 the store refused.
int storeClearTitle(sqlite3* db, const(char)[] id) {
    sqlite3_stmt* st;
    enum sql = "UPDATE code_session SET title = '' WHERE id = ?1 AND closed_at = 0\0";
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &st, null) != SQLITE_OK) return -1;
    bind(st, 1, id);
    auto rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return -1;
    return sqlite3_changes(db) > 0 ? 1 : 0;
}

// Adds an answer's cost, in billionths of a dollar, to what an open session
// has cost so far, into total. 1 added, 0 no open session by that id, -1 the
// store refused.
int storeAddCost(sqlite3* db, const(char)[] id, long nano, ref long total) {
    sqlite3_stmt* st;
    enum add = "UPDATE code_session SET cost_nano = cost_nano + ?2 WHERE id = ?1 AND closed_at = 0\0";
    if (sqlite3_prepare_v2(db, add.ptr, -1, &st, null) != SQLITE_OK) return -1;
    bind(st, 1, id);
    sqlite3_bind_int64(st, 2, nano);
    auto rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return -1;
    if (sqlite3_changes(db) == 0) return 0;
    enum read = "SELECT cost_nano FROM code_session WHERE id = ?1 AND closed_at = 0\0";
    if (sqlite3_prepare_v2(db, read.ptr, -1, &st, null) != SQLITE_OK) return -1;
    bind(st, 1, id);
    rc = sqlite3_step(st);
    if (rc == SQLITE_ROW) total = sqlite3_column_int64(st, 0);
    sqlite3_finalize(st);
    return rc == SQLITE_ROW ? 1 : -1;
}

// Every open session, oldest first, or those in one cwd. False when the store
// refused, whatever was handed over before it did.
bool storeList(sqlite3* db, const(char)[] cwd,
        scope void delegate(const(char)[] id, const(char)[] cwd, const(char)[] dirs, const(char)[] title, long updatedAt) each) {
    sqlite3_stmt* st;
    enum all = "SELECT id, cwd, dirs, title, updated_at FROM code_session WHERE closed_at = 0 ORDER BY opened_at, rowid\0";
    enum one = "SELECT id, cwd, dirs, title, updated_at FROM code_session WHERE closed_at = 0 AND cwd = ?1 ORDER BY opened_at, rowid\0";
    if (sqlite3_prepare_v2(db, (cwd is null ? all : one).ptr, -1, &st, null) != SQLITE_OK) return false;
    if (cwd !is null) bind(st, 1, cwd);
    int rc;
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) each(text(st, 0), text(st, 1), text(st, 2), text(st, 3), sqlite3_column_int64(st, 4));
    sqlite3_finalize(st);
    return rc == SQLITE_DONE;
}

// Removes a session list would show. 1 removed, 0 no open session by that id,
// -1 the store refused.
int storeDelete(sqlite3* db, const(char)[] id) {
    sqlite3_stmt* st;
    enum sql = "DELETE FROM code_session WHERE id = ?1 AND closed_at = 0\0";
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &st, null) != SQLITE_OK) return -1;
    bind(st, 1, id);
    auto rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return -1;
    return sqlite3_changes(db) > 0 ? 1 : 0;
}
