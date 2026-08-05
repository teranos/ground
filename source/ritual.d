module ritual;

import rite : Verdict;

// The two pendings are distinct because a rite waiting for the first time
// and one waiting again are not the same fact.
enum RiteState {
    Never,    // darker gray
    Ran,      // lighter gray — held, will run again
    Running,  // blinking blue
    Passed,   // green
    Halted,   // blinking red
}

// Done and Halted are reached by running, not by a command. Aborted is the
// exception: "it ends when it ends, not because i ran ritual stop".
enum RitualState { Live, Done, Halted, Aborted }

enum MAX_RITES = 32;

struct Position {
    const(char)[] ritual;
    size_t current;
    size_t riteCount;
    RiteState[MAX_RITES] states;
    RitualState state;
}

Position start(const(char)[] name, size_t riteCount) {
    Position p;
    p.ritual = name;
    p.riteCount = riteCount;
    p.state = RitualState.Live;
    return p;
}

// The verdict of the rite at `current`, applied.
Position step(Position p, Verdict v) {
    if (p.state != RitualState.Live) return p;
    if (p.current >= p.riteCount) return p;

    final switch (v) {
    case Verdict.Advance:
        p.states[p.current] = RiteState.Passed;
        p.current++;
        if (p.current >= p.riteCount) p.state = RitualState.Done;
        break;
    case Verdict.Hold:
        p.states[p.current] = RiteState.Ran;
        break;
    case Verdict.Halt:
        p.states[p.current] = RiteState.Halted;
        p.state = RitualState.Halted;
        break;
    }
    return p;
}

// One character per rite. The row is legible without a decoder, and collet
// renders the line straight from it.
private immutable char[5] GLYPH = ['.', '-', '>', '+', '!'];

struct Encoded {
    char[MAX_RITES] buf = 0;
    size_t len;
    const(char)[] text() const return { return buf[0 .. len]; }
    bool opEquals(const(char)[] s) const { return text() == s; }
}

Encoded encodeStates(const Position p) {
    Encoded e;
    foreach (i; 0 .. p.riteCount) {
        if (i >= MAX_RITES) break;
        e.buf[e.len++] = GLYPH[cast(size_t) p.states[i]];
    }
    return e;
}

// A row this process cannot read is a row it must not render. Restoring is
// therefore a verdict, not a Position.
struct Restored { bool valid; Position p; }

Restored restore(const(char)[] name, size_t current,
                 const(char)[] states, RitualState st) {
    if (states.length == 0 || states.length > MAX_RITES) return Restored(false);
    if (current > states.length) return Restored(false);

    Position p;
    p.ritual = name;
    p.current = current;
    p.riteCount = states.length;
    p.state = st;

    foreach (i, c; states) {
        bool known = false;
        foreach (g, glyph; GLYPH) {
            if (c == glyph) { p.states[i] = cast(RiteState) g; known = true; break; }
        }
        if (!known) return Restored(false);
    }
    return Restored(true, p);
}

private immutable string[4] STATE_WORD = ["live", "done", "halted", "aborted"];

// The row on disk. Keyed on project — one ritual live per project.
bool writePosition(DB)(DB db, const(char)[] project, const Position p) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_bind_int64, sqlite3_stmt, SQLITE_OK, SQLITE_DONE, SQLITE_TRANSIENT;
    import exec : emitError;

    enum sql = "INSERT INTO ritual_position (project, ritual, current, states, state) "
        ~ "VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT(project) DO UPDATE SET "
        ~ "ritual=?2, current=?3, states=?4, state=?5, updated_at=CURRENT_TIMESTAMP\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) {
        emitError("ritual.write.prepare", "could not prepare the position write",
                  0, 0, "", cast(string) p.ritual, "", "", "");
        return false;
    }

    auto row = encodeStates(p);
    auto word = STATE_WORD[cast(size_t) p.state];
    sqlite3_bind_text(stmt, 1, project.ptr, cast(int) project.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, p.ritual.ptr, cast(int) p.ritual.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 3, cast(long) p.current);
    sqlite3_bind_text(stmt, 4, row.buf.ptr, cast(int) row.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, word.ptr, cast(int) word.length, SQLITE_TRANSIENT);

    auto rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE) {
        emitError("ritual.write.step", "could not write the position",
                  0, rc, "", cast(string) p.ritual, "", "", "");
        return false;
    }
    return true;
}

// No row is a verdict, not an empty Position.
Restored readPosition(DB)(DB db, const(char)[] project) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_column_text, sqlite3_column_int64, sqlite3_stmt,
                SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    import exec : emitError;

    enum sql = "SELECT ritual, current, states, state FROM ritual_position WHERE project = ?1\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) {
        emitError("ritual.read.prepare", "could not prepare the position read",
                  0, 0, "", "", "", "", "");
        return Restored(false);
    }
    sqlite3_bind_text(stmt, 1, project.ptr, cast(int) project.length, SQLITE_TRANSIENT);

    if (sqlite3_step(stmt) != SQLITE_ROW) {
        sqlite3_finalize(stmt);
        return Restored(false);
    }

    // sqlite frees its column memory at finalize, so both text columns are
    // copied out before the statement dies.
    __gshared char[64] nameBuf = 0;
    __gshared char[MAX_RITES] rowBuf = 0;
    size_t nameLen, rowLen;
    copyCol(sqlite3_column_text(stmt, 0), nameBuf, nameLen);
    auto current = cast(size_t) sqlite3_column_int64(stmt, 1);
    copyCol(sqlite3_column_text(stmt, 2), rowBuf, rowLen);

    auto wordPtr = sqlite3_column_text(stmt, 3);
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
    return restore(nameBuf[0 .. nameLen], current, rowBuf[0 .. rowLen], st);
}

private void copyCol(const(char)* src, ref char[64] dst, ref size_t len) {
    len = 0;
    if (src is null) return;
    while (src[len] != 0 && len < dst.length - 1) { dst[len] = src[len]; len++; }
}

private void copyCol(const(char)* src, ref char[MAX_RITES] dst, ref size_t len) {
    len = 0;
    if (src is null) return;
    while (src[len] != 0 && len < dst.length) { dst[len] = src[len]; len++; }
}

private bool colEquals(const(char)* src, const(char)[] s) {
    if (src is null) return false;
    foreach (i, c; s) {
        if (src[i] == 0 || src[i] != c) return false;
    }
    return src[s.length] == 0;
}

// goto. History is left alone: a rite that passed still passed, even if the
// ritual is about to walk over it again.
Position jump(Position p, size_t target) {
    if (target >= p.riteCount) return p;
    p.current = target;
    if (p.state == RitualState.Done) p.state = RitualState.Live;
    return p;
}
