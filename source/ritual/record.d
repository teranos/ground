module ritual.record;

import rite : Verdict;
import ritual.position : Position;

// The record a rite leaves behind. Without it nothing outside the ritual can
// tell that anything happened at all.
struct RiteAttrs {
    char[6144] buf = 0;
    size_t len;
    const(char)[] text() const return { return buf[0 .. len]; }
}

private void put(ref RiteAttrs a, const(char)[] s) {
    foreach (c; s) { if (a.len < a.buf.length) a.buf[a.len++] = c; }
}

// Output is whatever the command printed, so it carries anything that would
// break the row it is going into.
private void putEscaped(ref RiteAttrs a, const(char)[] s) {
    foreach (c; s) {
        if (c == '"') a.put(`\"`);
        else if (c == '\\') a.put(`\\`);
        else if (c == '\n') a.put(`\n`);
        else if (c == '\r') a.put(`\r`);
        else if (c == '\t') a.put(`\t`);
        else if (a.len < a.buf.length) a.buf[a.len++] = c;
    }
}

private void putInt(ref RiteAttrs a, int v) {
    if (v < 0) { a.put("-"); v = -v; }
    char[12] d = 0;
    size_t n;
    if (v == 0) d[n++] = '0';
    while (v > 0) { d[n++] = cast(char)('0' + v % 10); v /= 10; }
    foreach (i; 0 .. n) a.put(d[n - 1 - i .. n - i]);
}

// The verdict is spelled out rather than left to be inferred from the code —
// a reader would otherwise need the rite's pass and catch values to know what
// the number meant.
private immutable string[3] VERDICT_WORD = ["advance", "hold", "halt"];

RiteAttrs riteAttributes(const(char)[] performance, const(char)[] ritual,
                         const(char)[] rite, Verdict v, int code,
                         const(char)[] output, long diffLines = -1) {
    RiteAttrs a;
    a.put(`{"performance":"`);
    a.putEscaped(performance);
    a.put(`","ritual":"`);
    a.putEscaped(ritual);
    a.put(`","rite":"`);
    a.putEscaped(rite);
    a.put(`","verdict":"`);
    a.put(VERDICT_WORD[cast(size_t) v]);
    a.put(`","code":`);
    a.putInt(code);
    a.put(`,"output":"`);
    a.putEscaped(output);
    a.put(`"`);
    if (diffLines >= 0) {
        a.put(`,"diff_lines":`);
        a.putInt(cast(int) diffLines);
    }
    a.put(`}`);
    return a;
}

// The rite's record with the walk it ran in: who held the mic, how often the
// walk went back or waited, and whose session is owed the news (QNTX #1068).
RiteAttrs riteRecord(const Position p, const(char)[] rite, Verdict v, int code,
                     const(char)[] output, long diffLines) {
    import mic : micWord;
    auto a = riteAttributes(p.id, p.ritual, rite, v, code, output, diffLines);
    if (a.len == 0) return a;
    a.len--;  // the record's closing brace, put back after the walk's fields
    a.put(`,"branch":"`);
    a.putEscaped(p.branch);
    a.put(`","gotos":`);
    a.putInt(cast(int) p.gotos);
    a.put(`,"holds":`);
    a.putInt(cast(int) p.holds);
    a.put(`,"evals":`);
    a.putInt(cast(int) p.evals);
    a.put(`,"mic":"`);
    a.put(micWord(p.mic));
    a.put(`","parent":"`);
    a.putEscaped(p.parent);
    a.put(`"}`);
    return a;
}

// One row per rite that ran. Keyed on the performance, the rite and the
// attempt, so a held rite re-run twenty times leaves twenty rows and a count
// of them is a count of attempts.
bool attestRite(DB)(DB db, const(char)[] sessionId, const Position p,
                    const(char)[] rite, Verdict v, int code,
                    const(char)[] output, long unixSeconds, long diffLines = -1) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_stmt, SQLITE_OK, SQLITE_DONE, SQLITE_TRANSIENT,
                formatTimestamp, versionString, ZBuf;
    import exec : emitError;

    enum sql = "INSERT OR REPLACE INTO attestations "
        ~ "(id, subjects, predicates, contexts, actors, timestamp, source, attributes) "
        ~ "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)\0";

    __gshared ZBuf idBuf, subjBuf, ctxBuf, srcBuf;
    idBuf.reset();
    idBuf.put("ritual:rite:");
    idBuf.put(p.id);
    idBuf.put(":");
    idBuf.put(rite);
    idBuf.put(":");
    {
        char[24] d = 0;
        size_t n;
        auto t = unixSeconds < 0 ? 0 : unixSeconds;
        if (t == 0) d[n++] = '0';
        while (t > 0 && n < 23) { d[n++] = cast(char)('0' + t % 10); t /= 10; }
        foreach_reverse (i; 0 .. n) idBuf.putChar(d[i]);
    }

    subjBuf.reset();
    subjBuf.put(`["`);
    subjBuf.put(p.ritual);
    subjBuf.put(`"]`);

    // A rite that ran with no session of its own is the parent's news.
    ctxBuf.reset();
    ctxBuf.put(`["session:`);
    ctxBuf.put(sessionId.length > 0 ? sessionId : p.parent);
    ctxBuf.put(`","performance:`);
    ctxBuf.put(p.id);
    ctxBuf.put(`"]`);

    srcBuf.reset();
    srcBuf.put("ground ");
    srcBuf.put(versionString());

    auto attrs = riteRecord(p, rite, v, code, output, diffLines);
    auto ts = formatTimestamp();

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) {
        emitError("ritual.attest.prepare", "could not prepare the rite attestation",
                  0, 0, cast(string) sessionId, cast(string) rite, "", "", "");
        return false;
    }

    sqlite3_bind_text(stmt, 1, idBuf.ptr(), cast(int) idBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, subjBuf.ptr(), cast(int) subjBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, `["ritual:rite"]`.ptr, 15, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, ctxBuf.ptr(), cast(int) ctxBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, `["ground"]`.ptr, 10, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 6, ts.ptr, cast(int) ts.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 7, srcBuf.ptr(), cast(int) srcBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 8, attrs.buf.ptr, cast(int) attrs.len, SQLITE_TRANSIENT);

    auto rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE) {
        emitError("ritual.attest.step", "could not write the rite attestation",
                  0, rc, cast(string) sessionId, cast(string) rite, "", "", "");
        return false;
    }
    return true;
}
