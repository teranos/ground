module notification;

// Notification is the one event that reaches the person and costs nothing: no
// decision control, no context injection, and exit 2 shows stderr to the user
// only. It fires on idle_prompt, agent_needs_input and agent_completed.

struct Notice {
    // A batch is every line since the last drain, and one rite's two
    // sentences can be several hundred bytes on their own. At 512 a walk
    // arrived cut off mid-word.
    char[16384] buf = 0;
    size_t len;
    const(char)[] text() const return { return buf[0 .. len]; }
}

private void put(ref Notice n, const(char)[] s) {
    foreach (c; s) { if (n.len < n.buf.length) n.buf[n.len++] = c; }
}

private void putChar(ref Notice n, char c) {
    if (n.len < n.buf.length) n.buf[n.len++] = c;
}

private void putNum(ref Notice n, int v) {
    if (v < 0) { n.put("-"); v = -v; }
    char[12] d = 0;
    size_t i;
    if (v == 0) d[i++] = '0';
    while (v > 0) { d[i++] = cast(char)('0' + v % 10); v /= 10; }
    foreach (k; 0 .. i) n.put(d[i - 1 - k .. i - k]);
}

// "a rite was passed through"
immutable string[3] VERDICT_SAID = ["passed through", "held", "halted"];

// "shouldnt dispatch rites say what happened, which is dispatched workflow.yml"
const(char)[] verdictWord(size_t verdict, bool dispatched) {
    return dispatched && verdict == 0 ? "dispatched" : VERDICT_SAID[verdict];
}

// The agent's own words, on the rite it was standing on. No verdict: it is
// the agent talking, not the rite answering.
Notice agentLine(const(char)[] ritual, const(char)[] rite, const(char)[] said,
                 const(char)[] performance = "") {
    Notice n;
    if (said.length == 0) return n;
    n.put(ritual);
    if (performance.length > 0) {
        import ritual : shortId;
        auto h = shortId(performance);
        if (h.len > 0) { n.put("-"); n.put(h.text()); }
    }
    n.put(" ");
    n.put(rite);
    n.put(" · ");
    n.put(said);
    return n;
}

// One rite, as it happens: what it answered, then what the agent said about
// it. The verdict leads because it is the part that reads as blocking,
// passing or stopped without being parsed.
Notice riteLine(V)(const(char)[] ritual, const(char)[] rite, V verdict,
                   const(char)[] said, const(char)[] performance = "",
                   const(char)[] mic = "", const(char)[] dispatch = "") {
    Notice n;
    n.put(ritual);
    // Several performances of one ritual walk at once, and every line saying
    // only "willow" makes three of them read as one.
    if (performance.length > 0) {
        import ritual : shortId;
        auto h = shortId(performance);
        if (h.len > 0) { n.put("-"); n.put(h.text()); }
    }
    n.put(" ");
    n.put(rite);
    n.put(" ");
    n.put(verdictWord(cast(size_t) verdict, dispatch.length > 0));
    if (dispatch.length > 0 && cast(size_t) verdict == 0) {
        n.put(" ");
        n.put(dispatch);
    }
    // "the rite never speaks? even though its holding the mic?"
    if (mic.length > 0) {
        n.put(" · ");
        n.put(mic);
    }
    if (said.length > 0) {
        n.put(" · ");
        n.put(said);
    }
    return n;
}

// The row carries rite names comma-joined so it renders without the pbt.
const(char)[] nthRite(const(char)[] rites, size_t n) {
    size_t start;
    size_t seen;
    foreach (i; 0 .. rites.length) {
        if (rites[i] != ',') continue;
        if (seen == n) return rites[start .. i];
        seen++;
        start = i + 1;
    }
    if (seen == n && start < rites.length) return rites[start .. $];
    return "";
}

// A halted performance in this directory, said once per session. Exit 2 is
// the whole point: it is the only reply this event accepts, and it puts the
// line in front of whoever is sitting there.
// A rite line for the operator, on its own record. The immediate queue is
// drained by the watcher every two seconds, which delivers to the model — a
// line put there never survives to reach a person.
bool writeSaid(DB)(DB db, const(char)[] sessionId, const(char)[] performance,
                   const(char)[] rite, const(char)[] line, bool yieldToExisting = false) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_stmt, SQLITE_OK, SQLITE_DONE, SQLITE_TRANSIENT,
                formatTimestamp, versionString, ZBuf;

    if (sessionId.length == 0) return false;

    __gshared ZBuf idBuf, ctxBuf, attrBuf, srcBuf;
    idBuf.reset();
    idBuf.put("ritual:said:");
    idBuf.put(sessionId);
    idBuf.put(":");
    idBuf.put(performance);
    idBuf.put(":");
    idBuf.put(rite);

    ctxBuf.reset();
    ctxBuf.put(`["session:`);
    ctxBuf.put(sessionId);
    ctxBuf.put(`"]`);

    attrBuf.reset();
    attrBuf.put(`{"line":"`);
    foreach (c; line) {
        if (c == '"' || c == '\\') continue;
        attrBuf.putChar(c);
    }
    attrBuf.put(`"}`);

    srcBuf.reset();
    srcBuf.put("ground ");
    srcBuf.put(versionString());

    // The driver has no last_assistant_message and writes the same key with
    // no sentences. It yields; an agent's line replaces whatever is there.
    enum keep = "INSERT OR IGNORE INTO attestations "
        ~ "(id, subjects, predicates, contexts, actors, timestamp, source, attributes) "
        ~ "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)\0";
    enum win = "INSERT OR REPLACE INTO attestations "
        ~ "(id, subjects, predicates, contexts, actors, timestamp, source, attributes) "
        ~ "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)\0";

    sqlite3_stmt* stmt;
    auto sql = yieldToExisting ? keep : win;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return false;

    auto ts = formatTimestamp();
    sqlite3_bind_text(stmt, 1, idBuf.ptr(), cast(int) idBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, `["ground"]`.ptr, 10, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, `["ritual:said"]`.ptr, 15, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, ctxBuf.ptr(), cast(int) ctxBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, `["ground"]`.ptr, 10, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 6, ts.ptr, cast(int) ts.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 7, srcBuf.ptr(), cast(int) srcBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 8, attrBuf.ptr(), cast(int) attrBuf.len, SQLITE_TRANSIENT);

    auto rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return rc == SQLITE_DONE;
}

// One row per line shown, named after the line. Marked rather than deleted:
// the trace on screen is a copy of the record, not the record itself.
private bool markShown(DB)(DB db, const(char)[] lineId) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_stmt, SQLITE_OK, SQLITE_DONE, SQLITE_TRANSIENT,
                formatTimestamp, ZBuf;

    __gshared ZBuf id;
    id.reset();
    id.put("shown:");
    id.put(lineId);

    enum sql = "INSERT OR IGNORE INTO attestations "
        ~ "(id, subjects, predicates, contexts, actors, timestamp, source, attributes) "
        ~ "VALUES (?1, '[\"ground\"]', '[\"ritual:shown\"]', '[]', '[\"ground\"]', ?2, 'ground', '{}')\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return false;
    auto ts = formatTimestamp();
    sqlite3_bind_text(stmt, 1, id.ptr(), cast(int) id.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, ts.ptr, cast(int) ts.length, SQLITE_TRANSIENT);
    auto rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return rc == SQLITE_DONE;
}

// Every line written for this session since the last drain, oldest first, in
// one write.
enum NOTICE_MARK = "notice:";

Notice drainSaid(DB)(DB db, const(char)[] sessionId) {
    import immediate : readImmediateMessage, markImmediateDelivered;

    Notice out_;
    if (sessionId.length == 0) return out_;

    // The queue the watcher already polls. One record, one delivery mark —
    // ordering, dedupe and per-session addressing all come with it.
    foreach (i; 0 .. 32) {
        auto imm = readImmediateMessage(db, "", sessionId, NOTICE_MARK);
        if (imm.message is null) break;
        markImmediateDelivered(db, imm.msgId, imm.projectContext, sessionId, NOTICE_MARK);
        if (out_.len > 0) out_.put("\n");
        out_.put(imm.message);
    }
    return out_;
}

private Notice drainSaidOld(DB)(DB db, const(char)[] sessionId) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_column_text, sqlite3_stmt, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT,
                attestationExists, attestControlFire, ZBuf;

    Notice out_;
    if (sessionId.length == 0) return out_;

    // A line already on screen is on screen forever, so the shown-marker is
    // its own row named after the line. Ties break on insertion order —
    // breaking them on the id sorts rite names alphabetically.
    enum sql = "SELECT s.id, json_extract(s.attributes, '$.line') FROM attestations s "
        ~ "WHERE json_extract(s.predicates, '$[0]') = 'ritual:said' "
        ~ "AND json_extract(s.contexts, '$[0]') = ?1 "
        ~ "AND NOT EXISTS (SELECT 1 FROM attestations d WHERE d.id = 'shown:' || s.id) "
        ~ "ORDER BY s.timestamp, s.rowid\0";

    __gshared ZBuf ctx;
    ctx.reset();
    ctx.put("session:");
    ctx.put(sessionId);

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return out_;
    sqlite3_bind_text(stmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);

    // The id is "ritual:said:" plus a uuid, a performance and a rite name.
    // At 64 it truncated inside the performance id, so every rite of one
    // performance shared a key and only the first was ever delivered.
    __gshared char[256][32] ids;
    __gshared size_t[32] idLens;
    size_t taken;

    while (sqlite3_step(stmt) == SQLITE_ROW && taken < ids.length) {
        auto idPtr = sqlite3_column_text(stmt, 0);
        auto linePtr = sqlite3_column_text(stmt, 1);
        if (idPtr is null || linePtr is null) continue;

        size_t n;
        while (idPtr[n] != 0 && n < ids[taken].length) { ids[taken][n] = idPtr[n]; n++; }
        idLens[taken] = n;

        if (out_.len > 0) out_.put("\n");
        size_t k;
        while (linePtr[k] != 0) { out_.putChar(linePtr[k]); k++; }
        taken++;
    }
    sqlite3_finalize(stmt);

    // attestControlFire keys its row on the second and the pid, so a batch
    // written in one second by one process collapsed to a single marker and
    // retired exactly one line per delivery.
    foreach (i; 0 .. taken)
        markShown(db, ids[i][0 .. idLens[i]]);

    return out_;
}

Notice noticeFor(DB)(DB db, const(char)[] cwd, const(char)[] sessionId) {
    import db : attestationExists, attestControlFire, ZBuf;
    import immediate : readImmediateMessage, markImmediateDelivered;
    import ritual : haltedHere;

    Notice none;

    // The trace comes first, and comes whole. One line per firing falls
    // behind on the first performance and never catches up.
    {
        auto batch = drainSaid(db, sessionId);
        if (batch.len > 0) return batch;
    }

    auto found = haltedHere(db, cwd);
    if (!found.valid) return none;

    __gshared ZBuf key;
    key.reset();
    key.put("ritual-halt:");
    key.put(found.p.id);

    if (attestationExists(db, "GroundedNotification", key.slice(), sessionId))
        return none;
    attestControlFire(db, "GroundedNotification", key.slice(), cwd, sessionId);

    // The exit code lives on the rite attestation, not on this row, so the
    // notice names what it has and does not invent a number.
    return haltNotice(found.p.ritual, nthRite(found.p.rites, found.p.current));
}

int handleNotification(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    import core.stdc.stdio : stdout, fputs;
    import db : openDb, sqlite3_close;
    import parse : writeJsonString;

    auto db = openDb();
    if (db is null) return 0;
    auto n = noticeFor(db, cwd, sessionId);
    sqlite3_close(db);

    if (n.len == 0) return 0;

    // Both doors at once. systemMessage is the documented field for text
    // shown to the user; exit 2 on this event shows stderr to the user only.
    fputs(`{"systemMessage":"`, stdout);
    writeJsonString(n.text());
    fputs(`"}` ~ "\n", stdout);

    import core.stdc.stdio : stderr, fwrite;
    fwrite(n.buf.ptr, 1, n.len, stderr);
    fputs("\n", stderr);
    return 2;
}

// Which ritual, which rite, and the number. The number is the part that says
// whether the condition answered or never ran.
Notice haltNotice(const(char)[] ritual, const(char)[] rite, int code) {
    auto n = haltNotice(ritual, rite);
    n.put(" with exit ");
    n.putNum(code);
    return n;
}

Notice haltNotice(const(char)[] ritual, const(char)[] rite) {
    Notice n;
    n.put("ground: ritual ");
    n.put(ritual);
    n.put(" halted on ");
    n.put(rite);
    return n;
}
