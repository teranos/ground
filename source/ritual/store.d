module ritual.store;

import ritual.position : Position, Restored, RitualState, MAX_RITES,
                         encodeStates, restore;
import mic : micWord, micFromWord;

package immutable string[4] STATE_WORD = ["live", "done", "halted", "aborted"];

// The row on disk. Keyed on the performance; the worktree is an index.
bool writePosition(DB)(DB db, const Position p) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_bind_int64, sqlite3_stmt, SQLITE_OK, SQLITE_DONE, SQLITE_TRANSIENT;
    import exec : emitError;

    enum sql = "INSERT INTO ritual_position (id, repo, ritual, branch, worktree, current, states, state, rites, session, agent, gotos, parent, agent_pid, thrown_at, throws, mic, mic_at, said, holds) "
        ~ "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20) ON CONFLICT(id) DO UPDATE SET "
        ~ "branch=?4, worktree=?5, current=?6, states=?7, state=?8, rites=?9, "
        ~ "session=?10, agent=?11, gotos=?12, parent=?13, agent_pid=?14, thrown_at=?15, throws=?16, "
        ~ "mic=?17, mic_at=?18, said=?19, holds=?20, rev=rev+1, updated_at=CURRENT_TIMESTAMP\0";

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
    sqlite3_bind_text(stmt, 10, p.agentSession.ptr, cast(int) p.agentSession.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 11, p.agent.ptr, cast(int) p.agent.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 12, cast(long) p.gotos);
    sqlite3_bind_text(stmt, 13, p.parent.ptr, cast(int) p.parent.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 14, cast(long) p.agentPid);
    sqlite3_bind_int64(stmt, 15, p.thrownAt);
    sqlite3_bind_int64(stmt, 16, cast(long) p.throws);
    auto mw = micWord(p.mic);
    sqlite3_bind_text(stmt, 17, mw.ptr, cast(int) mw.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 18, p.micAt);
    sqlite3_bind_int64(stmt, 19, p.said);
    sqlite3_bind_int64(stmt, 20, cast(long) p.holds);

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
    enum sql = "SELECT id, repo, ritual, branch, worktree, current, states, state, rites, session, agent, gotos, parent, agent_pid, thrown_at, throws, rev, mic, mic_at, said, holds "
        ~ "FROM ritual_position WHERE repo = ?1 ORDER BY updated_at DESC LIMIT 1\0";
    return readOne(db, sql, repo);
}

// The performance being done in this tree.
Restored readPositionAt(DB)(DB db, const(char)[] worktree) {
    enum sql = "SELECT id, repo, ritual, branch, worktree, current, states, state, rites, session, agent, gotos, parent, agent_pid, thrown_at, throws, rev, mic, mic_at, said, holds "
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
    __gshared char[80] parentBuf = 0;
    size_t idLen, repoLen, nameLen, branchLen, treeLen, rowLen, namesLen, sessLen, agentLen, parentLen;

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
    auto gotoCount = cast(size_t) sqlite3_column_int64(stmt, 11);
    copyText(sqlite3_column_text(stmt, 12), parentBuf.ptr, parentBuf.length, parentLen);
    auto pid = cast(int) sqlite3_column_int64(stmt, 13);
    auto thrown = sqlite3_column_int64(stmt, 14);
    auto throwCount = cast(size_t) sqlite3_column_int64(stmt, 15);
    auto revision = sqlite3_column_int64(stmt, 16);
    __gshared char[16] micBuf = 0;
    size_t micLen;
    copyText(sqlite3_column_text(stmt, 17), micBuf.ptr, micBuf.length, micLen);
    auto micHeld = sqlite3_column_int64(stmt, 18);
    auto saidHash = sqlite3_column_int64(stmt, 19);
    auto holdCount = cast(size_t) sqlite3_column_int64(stmt, 20);

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
    r.p.agentSession = sessBuf[0 .. sessLen];
    r.p.agent = agentBuf[0 .. agentLen];
    r.p.parent = parentBuf[0 .. parentLen];
    r.p.agentPid = pid;
    r.p.thrownAt = thrown;
    r.p.throws = throwCount;
    r.p.rev = revision;

    // A word this build cannot read is refused, the way an unknown state word
    // is: reading it as ground would say a rite is speaking when nothing knows.
    auto held = micFromWord(micBuf[0 .. micLen]);
    if (!held.valid) {
        emitError("ritual.read.mic", "the row names a mic holder this build does not have",
                  0, 0, "", cast(string) nameBuf[0 .. nameLen], "", "", "");
        return Restored(false);
    }
    r.p.mic = held.who;
    r.p.micAt = micHeld;
    r.p.said = saidHash;
    r.p.gotos = gotoCount;
    r.p.holds = holdCount;
    return r;
}

// A write that loses if the row moved since it was read. Three callers advance
// a position and none of them coordinated: the willow recorded START twice and
// JACKFRUIT twice, and a throw-back count was put back by a stale reader.
bool writePositionIf(DB)(DB db, const Position p, long expectedRev) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize,
                sqlite3_bind_text, sqlite3_bind_int64, sqlite3_changes,
                sqlite3_stmt, SQLITE_OK, SQLITE_DONE, SQLITE_TRANSIENT;

    // An upsert and not an UPDATE: a performance's first write creates the row,
    // and a guarded UPDATE would refuse it for having no revision to match.
    enum sql = "INSERT INTO ritual_position (id, repo, ritual, branch, worktree, current, states, state, rites, session, agent, gotos, parent, agent_pid, thrown_at, throws, rev, mic, mic_at, said, holds) "
        ~ "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17 + 1, ?18, ?19, ?20, ?21) ON CONFLICT(id) DO UPDATE SET "
        ~ "branch=?4, worktree=?5, current=?6, states=?7, state=?8, rites=?9, "
        ~ "session=?10, agent=?11, gotos=?12, parent=?13, agent_pid=?14, thrown_at=?15, throws=?16, "
        ~ "mic=?18, mic_at=?19, said=?20, holds=?21, rev=rev+1, updated_at=CURRENT_TIMESTAMP WHERE ritual_position.rev=?17\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return false;

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
    sqlite3_bind_text(stmt, 10, p.agentSession.ptr, cast(int) p.agentSession.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 11, p.agent.ptr, cast(int) p.agent.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 12, cast(long) p.gotos);
    sqlite3_bind_text(stmt, 13, p.parent.ptr, cast(int) p.parent.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 14, cast(long) p.agentPid);
    sqlite3_bind_int64(stmt, 15, p.thrownAt);
    sqlite3_bind_int64(stmt, 16, cast(long) p.throws);
    sqlite3_bind_int64(stmt, 17, expectedRev);
    auto mw = micWord(p.mic);
    sqlite3_bind_text(stmt, 18, mw.ptr, cast(int) mw.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 19, p.micAt);
    sqlite3_bind_int64(stmt, 20, p.said);
    sqlite3_bind_int64(stmt, 21, cast(long) p.holds);

    auto rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE) return false;
    return sqlite3_changes(db) > 0;
}

// The agent did something. Stamped per tool call, so blue on the line means
// work is happening rather than a colour asserting it. An UPDATE and not a
// read: this runs on every tool call in every session, live performance or no.
void stampActed(DB)(DB db, const(char)[] sessionId, long unixSeconds) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize,
                sqlite3_bind_text, sqlite3_bind_int64, sqlite3_stmt,
                SQLITE_OK, SQLITE_TRANSIENT;

    if (sessionId.length == 0) return;
    enum sql = "UPDATE ritual_position SET acted_at = ?2 "
        ~ "WHERE session = ?1 AND state = 'live'\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return;
    sqlite3_bind_text(stmt, 1, sessionId.ptr, cast(int) sessionId.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 2, unixSeconds);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

// The performance whose three characters you are reading off the line. The
// handle is derived, not stored, so this walks the live rows and computes it.
Restored byHandle(DB)(DB db, const(char)[] handle) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize,
                sqlite3_column_text, sqlite3_stmt, SQLITE_OK, SQLITE_ROW;
    import ritual.position : shortId;

    enum sql = "SELECT id FROM ritual_position WHERE state = 'live' ORDER BY id\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return Restored(false);

    __gshared char[80] idBuf = 0;
    size_t idLen;
    bool found = false;

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        __gshared char[80] scratch = 0;
        size_t n;
        copyText(sqlite3_column_text(stmt, 0), scratch.ptr, scratch.length, n);
        if (n == 0) continue;
        if (shortId(scratch[0 .. n]).text() != handle) continue;
        foreach (i; 0 .. n) idBuf[i] = scratch[i];
        idLen = n;
        found = true;
        break;
    }
    sqlite3_finalize(stmt);
    if (!found) return Restored(false);

    enum byId = "SELECT id, repo, ritual, branch, worktree, current, states, state, rites, session, agent, gotos, parent, agent_pid, thrown_at, throws, rev, mic, mic_at, said, holds "
        ~ "FROM ritual_position WHERE id = ?1\0";
    return readOne(db, byId, idBuf[0 .. idLen]);
}

// The performance in this directory that stopped and is waiting to be read.
Restored haltedHere(DB)(DB db, const(char)[] cwd) { return stateHere(db, cwd, "halted"); }

private Restored stateHere(DB)(DB db, const(char)[] cwd, const(char)[] want) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_column_text, sqlite3_stmt, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    import matcher : contains;

    enum sql = "SELECT id, repo FROM ritual_position WHERE state = ?1 "
        ~ "ORDER BY updated_at DESC\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return Restored(false);
    sqlite3_bind_text(stmt, 1, want.ptr, cast(int) want.length, SQLITE_TRANSIENT);

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

    enum byId = "SELECT id, repo, ritual, branch, worktree, current, states, state, rites, session, agent, gotos, parent, agent_pid, thrown_at, throws, rev, mic, mic_at, said, holds "
        ~ "FROM ritual_position WHERE id = ?1\0";
    return readOne(db, byId, idBuf[0 .. idLen]);
}

// The rite already ran, so a write that lost its revision needs the current
// one — not a second run of the rite.
Restored byPerformanceId(DB)(DB db, const(char)[] id) {
    enum sql = "SELECT id, repo, ritual, branch, worktree, current, states, state, rites, session, agent, gotos, parent, agent_pid, thrown_at, throws, rev, mic, mic_at, said, holds "
        ~ "FROM ritual_position WHERE id = ?1\0";
    return readOne(db, sql, id);
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
