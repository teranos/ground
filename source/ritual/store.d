module ritual.store;

import ritual.position : Position, Restored, RitualState, MAX_RITES,
                         encodeStates, restore;

package immutable string[4] STATE_WORD = ["live", "done", "halted", "aborted"];

// The row on disk. Keyed on the performance; the worktree is an index.
bool writePosition(DB)(DB db, const Position p) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_bind_int64, sqlite3_stmt, SQLITE_OK, SQLITE_DONE, SQLITE_TRANSIENT;
    import exec : emitError;

    enum sql = "INSERT INTO ritual_position (id, repo, ritual, branch, worktree, current, states, state, rites, session, agent) "
        ~ "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11) ON CONFLICT(id) DO UPDATE SET "
        ~ "branch=?4, worktree=?5, current=?6, states=?7, state=?8, rites=?9, "
        ~ "session=?10, agent=?11, updated_at=CURRENT_TIMESTAMP\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) {
        emitError("ritual.write.prepare", "could not prepare the position write",
                  0, 0, "", cast(string) p.ritual, "", "", "");
        return false;
    }

    auto row = encodeStates(p);
    auto word = STATE_WORD[cast(size_t) p.state];
    sqlite3_bind_text(stmt, 1, p.id.ptr, cast(int) p.id.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, p.repo.ptr, cast(int) p.repo.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, p.ritual.ptr, cast(int) p.ritual.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, p.branch.ptr, cast(int) p.branch.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, p.worktree.ptr, cast(int) p.worktree.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 6, cast(long) p.current);
    sqlite3_bind_text(stmt, 7, row.buf.ptr, cast(int) row.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 8, word.ptr, cast(int) word.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 9, p.rites.ptr, cast(int) p.rites.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 10, p.session.ptr, cast(int) p.session.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 11, p.agent.ptr, cast(int) p.agent.length, SQLITE_TRANSIENT);

    auto rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE) {
        emitError("ritual.write.step", "could not write the position",
                  0, rc, "", cast(string) p.ritual, "", "", "");
        return false;
    }
    return true;
}

// The latest performance of a repo, whatever state it is in. Survives the
// worktree, and survives finishing — a terminal state is the verdict, and a
// query that returns only live ones hides what you walked away to collect.
Restored readPosition(DB)(DB db, const(char)[] repo) {
    enum sql = "SELECT id, repo, ritual, branch, worktree, current, states, state, rites, session, agent "
        ~ "FROM ritual_position WHERE repo = ?1 ORDER BY updated_at DESC LIMIT 1\0";
    return readOne(db, sql, repo);
}

// The performance being done in this tree.
Restored readPositionAt(DB)(DB db, const(char)[] worktree) {
    enum sql = "SELECT id, repo, ritual, branch, worktree, current, states, state, rites, session, agent "
        ~ "FROM ritual_position WHERE worktree = ?1 ORDER BY updated_at DESC LIMIT 1\0";
    return readOne(db, sql, worktree);
}

// No row is a verdict, not an empty Position.
private Restored readOne(DB)(DB db, string sql, const(char)[] key) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_column_text, sqlite3_column_int64, sqlite3_stmt,
                SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    import exec : emitError;

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) {
        emitError("ritual.read.prepare", "could not prepare the position read",
                  0, 0, "", "", "", "", "");
        return Restored(false);
    }
    sqlite3_bind_text(stmt, 1, key.ptr, cast(int) key.length, SQLITE_TRANSIENT);

    if (sqlite3_step(stmt) != SQLITE_ROW) {
        sqlite3_finalize(stmt);
        return Restored(false);
    }

    // sqlite frees its column memory at finalize, so every text column is
    // copied out before the statement dies.
    __gshared char[80]  idBuf = 0;
    __gshared char[256] repoBuf = 0;
    __gshared char[64]  nameBuf = 0;
    __gshared char[128] branchBuf = 0;
    __gshared char[256] treeBuf = 0;
    __gshared char[MAX_RITES] rowBuf = 0;
    __gshared char[1024] namesBuf = 0;
    __gshared char[80] sessBuf = 0;
    __gshared char[80] agentBuf = 0;
    size_t idLen, repoLen, nameLen, branchLen, treeLen, rowLen, namesLen, sessLen, agentLen;

    copyText(sqlite3_column_text(stmt, 0), idBuf.ptr, idBuf.length, idLen);
    copyText(sqlite3_column_text(stmt, 1), repoBuf.ptr, repoBuf.length, repoLen);
    copyText(sqlite3_column_text(stmt, 2), nameBuf.ptr, nameBuf.length, nameLen);
    copyText(sqlite3_column_text(stmt, 3), branchBuf.ptr, branchBuf.length, branchLen);
    copyText(sqlite3_column_text(stmt, 4), treeBuf.ptr, treeBuf.length, treeLen);
    auto current = cast(size_t) sqlite3_column_int64(stmt, 5);
    copyText(sqlite3_column_text(stmt, 6), rowBuf.ptr, rowBuf.length, rowLen);
    copyText(sqlite3_column_text(stmt, 8), namesBuf.ptr, namesBuf.length, namesLen);
    copyText(sqlite3_column_text(stmt, 9), sessBuf.ptr, sessBuf.length, sessLen);
    copyText(sqlite3_column_text(stmt, 10), agentBuf.ptr, agentBuf.length, agentLen);

    auto wordPtr = sqlite3_column_text(stmt, 7);
    RitualState st = RitualState.Live;
    bool knownWord = false;
    foreach (i, w; STATE_WORD) {
        if (colEquals(wordPtr, w)) { st = cast(RitualState) i; knownWord = true; break; }
    }
    sqlite3_finalize(stmt);

    if (!knownWord) {
        emitError("ritual.read.state", "the row names a ritual state this build does not have",
                  0, 0, "", cast(string) nameBuf[0 .. nameLen], "", "", "");
        return Restored(false);
    }

    auto r = restore(nameBuf[0 .. nameLen], current, rowBuf[0 .. rowLen], st);
    if (!r.valid) return r;
    r.p.id = idBuf[0 .. idLen];
    r.p.repo = repoBuf[0 .. repoLen];
    r.p.branch = branchBuf[0 .. branchLen];
    r.p.worktree = treeBuf[0 .. treeLen];
    r.p.rites = namesBuf[0 .. namesLen];
    r.p.session = sessBuf[0 .. sessLen];
    r.p.agent = agentBuf[0 .. agentLen];
    return r;
}

// The live performance this directory belongs to. A subagent starts in the
// parent's cwd, not the tree, so an exact worktree match would miss it —
// the repo path is what both have in common.
Restored liveHere(DB)(DB db, const(char)[] cwd) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize,
                sqlite3_column_text, sqlite3_stmt, SQLITE_OK, SQLITE_ROW;
    import matcher : contains;

    enum sql = "SELECT id, repo FROM ritual_position WHERE state = 'live' "
        ~ "ORDER BY updated_at DESC\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return Restored(false);

    __gshared char[80] idBuf = 0;
    size_t idLen;
    bool found = false;

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        __gshared char[256] repoBuf = 0;
        size_t repoLen;
        copyText(sqlite3_column_text(stmt, 1), repoBuf.ptr, repoBuf.length, repoLen);
        if (repoLen == 0 || !contains(cwd, repoBuf[0 .. repoLen])) continue;
        copyText(sqlite3_column_text(stmt, 0), idBuf.ptr, idBuf.length, idLen);
        found = true;
        break;
    }
    sqlite3_finalize(stmt);
    if (!found) return Restored(false);

    enum byId = "SELECT id, repo, ritual, branch, worktree, current, states, state, rites, session, agent "
        ~ "FROM ritual_position WHERE id = ?1\0";
    return readOne(db, byId, idBuf[0 .. idLen]);
}

private void copyText(const(char)* src, char* dst, size_t cap, ref size_t len) {
    len = 0;
    if (src is null) return;
    while (src[len] != 0 && len < cap) { dst[len] = src[len]; len++; }
}

private bool colEquals(const(char)* src, const(char)[] s) {
    if (src is null) return false;
    foreach (i, c; s) {
        if (src[i] == 0 || src[i] != c) return false;
    }
    return src[s.length] == 0;
}
