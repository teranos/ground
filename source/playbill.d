module playbill;

// What could be performed where you are standing, and what starts it. A session
// met the rituals of its own project only when one interrupted, so a halted rite
// arrived as a word from a tool the session had never run.

import ritual.position : MAX_RITES;
import db : ZBuf;

// A ritual named by several controls is several cues, and every one of them is
// something a session would otherwise not be told. The assert is deliberate:
// dropping one silently is the failure this exists to end.
enum MAX_CUES = 32;

struct Cue {
    string ritual;
    string event;
    // Carried whole so scopeMatches decides, negations included. The rule that
    // says whether the ritual fires is the rule that says whether it is named.
    string[8] paths;
    ubyte pathCount;
    string[8] cmds;
    ubyte cmdCount;
    // In walk order, which is the order a halt line counts to.
    string[MAX_RITES] rites;
    size_t riteCount;
}

struct Bill {
    Cue[MAX_CUES] cues;
    size_t len;
}

// CTFE. Every control that names a ritual, paired with the scope that starts it.
Bill cuesOf(PR)(const PR parsed) {
    import ritual.resolve : flatten;

    Bill b;
    foreach (si; 0 .. parsed.scopeCount) {
        auto sc = parsed.scopes[si];
        foreach (ci; sc.controlStart .. sc.controlEnd) {
            auto name = parsed.ctrlPool[ci].ritual;
            if (name.length == 0) continue;

            assert(b.len < MAX_CUES, "cue overflow — bump MAX_CUES");

            Cue cue;
            cue.ritual = name;
            cue.event = sc.event;
            cue.paths = sc.paths;
            cue.pathCount = sc.pathCount;
            cue.cmds = sc.cmds;
            cue.cmdCount = sc.cmdCount;

            foreach (ri; 0 .. parsed.ritualCount) {
                if (parsed.rituals[ri].name != name) continue;
                auto flat = flatten(parsed, ri);
                foreach (k; 0 .. flat.count) cue.rites[k] = flat.rites[k].name;
                cue.riteCount = flat.count;
                break;
            }

            b.cues[b.len] = cue;
            b.len++;
        }
    }
    return b;
}

// One cue's sentence, with nothing joining it. What separates two of them is
// the caller's, because a hook's context and a hook's stderr do not agree.
size_t cueInto(const ref Cue cue, char[] dest) {
    size_t o = 0;
    void put(const(char)[] s) {
        foreach (c; s) if (o < dest.length) dest[o++] = c;
    }

    put(cue.ritual);
    put(" performs here on ");

    // A scope naming no command is started by the event alone, and empty
    // backticks would say a command exists that nothing wrote.
    foreach (i; 0 .. cue.cmdCount) {
        if (i > 0) put(", ");
        put("`");
        put(cue.cmds[i]);
        put("`");
        put(" ");
    }

    if (cue.cmdCount > 0) put("(");
    put(cue.event);
    if (cue.cmdCount > 0) put(")");

    if (cue.riteCount > 0) {
        put(": ");
        foreach (i; 0 .. cue.riteCount) {
            if (i > 0) put(" > ");
            put(cue.rites[i]);
        }
    }
    return o;
}

// One sentence per cue that fires here, joined the way a session's context is.
size_t billInto(const(Cue)[] cues, const(char)[] cwd, char[] dest) {
    import hooks : scopeMatches;

    size_t o = 0;
    foreach (ref cue; cues) {
        if (!scopeMatches(cue, cwd)) continue;
        if (o > 0) {
            foreach (c; " | ") if (o < dest.length) dest[o++] = c;
        }
        o += cueInto(cue, dest[o .. $]);
    }
    return o;
}

// The live control set. A session is told about the rituals that are actually
// compiled in, not about a shape someone wrote down once.
import controls : allParsed;
private static immutable _bill = cuesOf(allParsed);
static immutable ritualCues = _bill.cues[0 .. _bill.len];

// One predicate for both delivery sites. Two would let the same session hear
// the same ritual twice, once per hook.
enum PLAYBILL = "GroundedPlaybill";

// The mark is named after the session and the ritual, not after the second it
// landed in. attestEvent keys its row on the timestamp and the pid, so a whole
// bill written by one process in one second collapsed to a single row.
private void markId(ref ZBuf id, const(char)[] sessionId, const(char)[] ritual) {
    id.reset();
    id.put("playbill:");
    id.put(sessionId);
    id.put(":");
    id.put(ritual);
}

private enum PLAYBILL_JSON = `["` ~ PLAYBILL ~ `"]`;

// Whether this session has already been told about this ritual. A compaction
// after the mark unsets it, which is right: the session has forgotten.
private bool saidAlready(DB)(DB db, const(char)[] sessionId, const(char)[] ritual) {
    import db : sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_bind_int64, sqlite3_step,
                sqlite3_column_int64, sqlite3_finalize, sqlite3_stmt,
                SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;

    __gshared ZBuf id;
    markId(id, sessionId, ritual);

    enum sql = "SELECT rowid FROM attestations WHERE id = ?1 LIMIT 1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return false;
    sqlite3_bind_text(stmt, 1, id.ptr(), cast(int) id.len, SQLITE_TRANSIENT);

    if (sqlite3_step(stmt) != SQLITE_ROW) {
        sqlite3_finalize(stmt);
        return false;
    }
    auto at = sqlite3_column_int64(stmt, 0);
    sqlite3_finalize(stmt);

    __gshared ZBuf ctx;
    ctx.reset();
    ctx.put("session:");
    ctx.put(sessionId);

    enum compactSql = "SELECT 1 FROM attestations WHERE json_extract(predicates, '$[0]') = 'PreCompact' AND json_extract(contexts, '$[0]') = ?1 AND rowid > ?2 LIMIT 1\0";
    sqlite3_stmt* cstmt;
    if (sqlite3_prepare_v2(db, compactSql.ptr, -1, &cstmt, null) != SQLITE_OK) return true;
    sqlite3_bind_text(cstmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
    sqlite3_bind_int64(cstmt, 2, at);
    bool compacted = sqlite3_step(cstmt) == SQLITE_ROW;
    sqlite3_finalize(cstmt);

    return !compacted;
}

// A compaction has to be able to unset the mark, so a replace would hide the
// older row the rowid comparison needs. Ignore keeps the first one.
private void markSaid(DB)(DB db, const(char)[] sessionId, const(char)[] ritual) {
    import db : sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_step, sqlite3_finalize,
                sqlite3_stmt, SQLITE_OK, SQLITE_TRANSIENT, formatTimestamp, versionString;

    __gshared ZBuf id, ctx, attrs, src;
    markId(id, sessionId, ritual);

    ctx.reset();
    ctx.put(`["session:`);
    ctx.put(sessionId);
    ctx.put(`"]`);

    attrs.reset();
    attrs.put(`{"ritual":"`);
    attrs.put(ritual);
    attrs.put(`"}`);

    src.reset();
    src.put("ground ");
    src.put(versionString());

    enum sql = "INSERT OR IGNORE INTO attestations "
        ~ "(id, subjects, predicates, contexts, actors, timestamp, source, attributes) "
        ~ "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return;

    auto ts = formatTimestamp();
    sqlite3_bind_text(stmt, 1, id.ptr(), cast(int) id.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, `["ground"]`.ptr, 10, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, PLAYBILL_JSON.ptr, cast(int) PLAYBILL_JSON.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, `["ground"]`.ptr, 10, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 6, ts.ptr, cast(int) ts.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 7, src.ptr(), cast(int) src.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 8, attrs.ptr(), cast(int) attrs.len, SQLITE_TRANSIENT);

    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

// Said once per session, by whichever hook is standing where it performs.
size_t unsaidBillInto(DB)(DB db, const(char)[] sessionId, const(char)[] cwd, char[] dest) {
    import hooks : scopeMatches;

    if (db is null || sessionId.length == 0) return 0;

    size_t o = 0;
    foreach (ref cue; ritualCues) {
        if (!scopeMatches(cue, cwd)) continue;
        if (saidAlready(db, sessionId, cue.ritual)) continue;
        markSaid(db, sessionId, cue.ritual);

        if (o > 0) {
            foreach (c; " | ") if (o < dest.length) dest[o++] = c;
        }
        o += cueInto(cue, dest[o .. $]);
    }
    return o;
}
