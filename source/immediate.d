module immediate;

// Immediate delivery — messages from external processes delivered in real time.
//
// External writers (e.g. QNTX lifecycle events) INSERT into ground's attestation db:
//
//   id:         unique per message (e.g. "AS-QNTX-IMEDIATE-...")
//   predicates: ["immediate:<name>"]        — e.g. ["immediate:lifecycle"]
//   contexts:   ["project:<path>"]          — e.g. ["project:teranos/QNTX"]
//   attributes: {"detail":"...","after":0}  — detail is the message, after is unix timestamp gate
//
// The watcher (watch.d) polls every 2s. When it finds matching attestations,
// it batches them and writes to stderr, then exits 2. Claude Code's asyncRewake
// shows stderr as a system reminder and wakes the session.
//
// Delivery is per-message, per-session:
//   ground writes ["delivered:<msgId>"] with contexts ["project:...","session:<id>"].
//   Each session independently tracks which messages it has seen.
//   Multiple messages with the same name (e.g. repeated lifecycle events) are
//   each delivered — delivery is keyed on the message's unique ID, not its name.
//
// See watch.d for the watcher lifecycle, claim files, and debounce.

import matcher : indexOf;
import db : sqlite3, sqlite3_stmt, sqlite3_prepare_v2, sqlite3_bind_text,
                sqlite3_step, sqlite3_finalize, sqlite3_column_text,
                SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT,
                ZBuf, jsonArray1, formatTimestamp, versionString, attestEvent;
import core.stdc.time : time;

struct ImmediateMsg {
    const(char)[] msgId;
    const(char)[] name;
    const(char)[] message;
    const(char)[] projectContext;
    // Push-time cwd + branch — populated by readImmediateMessage when the
    // row's attributes carry them (e.g. ci-status). Lets watch.d's
    // late-binding query the RIGHT repo regardless of where the watcher is.
    const(char)[] cwd;
    const(char)[] branch;
}

// Read a pending immediate message matching this session OR (for
// external writers like QNTX that don't know sessions) this cwd's project.
ImmediateMsg readImmediateMessage(sqlite3* db, const(char)[] cwd, const(char)[] sessionId) {
    auto now = cast(long) time(null);

    // Per-message, per-session delivery: NOT EXISTS checks for delivered:<msgId> tagged with THIS session.
    enum sql = "SELECT a.id, a.predicates, a.attributes, a.contexts FROM attestations a WHERE json_extract(a.predicates, '$[0]') >= 'immediate:' AND json_extract(a.predicates, '$[0]') < 'immediate;' AND NOT EXISTS (SELECT 1 FROM attestations d WHERE json_extract(d.predicates, '$[0]') = 'delivered:' || a.id AND d.contexts LIKE ?1) ORDER BY a.timestamp ASC\0";

    // Build session LIKE pattern: %session:<id>%
    __gshared ZBuf sessPattern;
    sessPattern.reset();
    sessPattern.put(`%session:`);
    sessPattern.put(sessionId);
    sessPattern.put(`%`);

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return ImmediateMsg(null, null, null, null, null, null);
    sqlite3_bind_text(stmt, 1, sessPattern.ptr(), cast(int) sessPattern.len, SQLITE_TRANSIENT);

    __gshared char[128] idBuf = 0;
    __gshared char[256] nameBuf = 0;
    __gshared char[512] msgBuf = 0;
    __gshared char[256] ctxBuf = 0;

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        auto idText = sqlite3_column_text(stmt, 0);
        auto predText = sqlite3_column_text(stmt, 1);
        auto attrText = sqlite3_column_text(stmt, 2);
        auto ctxText = sqlite3_column_text(stmt, 3);
        if (idText is null || predText is null || attrText is null || ctxText is null) continue;

        size_t ctxLen = 0;
        while (ctxText[ctxLen] != 0) ctxLen++;
        auto ctxs = (cast(const(char)*) ctxText)[0 .. ctxLen];

        // Session-gated rows: written from THIS session, always deliver here.
        // Search for `session:<this_sid>` literally in the contexts JSON.
        bool sessionMatch = false;
        {
            __gshared char[160] needle = 0;
            size_t nLen = 0;
            foreach (c; "session:") { if (nLen < needle.length) needle[nLen++] = c; }
            foreach (c; sessionId) { if (nLen < needle.length) needle[nLen++] = c; }
            if (nLen > 0 && ctxLen >= nLen) {
                auto sidx = indexOf(ctxs, needle[0 .. nLen]);
                sessionMatch = sidx >= 0;
            }
        }

        // Project-gated rows: external writers (e.g. QNTX). cwd must end with project path.
        ptrdiff_t projIdx = -1;
        size_t projStart = 0;
        size_t projEnd = 0;
        if (!sessionMatch) {
            projIdx = indexOf(ctxs, "project:");
            if (projIdx < 0) continue;
            projStart = cast(size_t) projIdx + 8;
            projEnd = projStart;
            while (projEnd < ctxLen && ctxs[projEnd] != '"') projEnd++;
            if (projEnd == projStart) continue;
            auto projPath = ctxs[projStart .. projEnd];
            if (cwd.length < projPath.length) continue;
            if (cwd[cwd.length - projPath.length .. $] != projPath) continue;
        }

        // Extract name from predicates: ["immediate:lifecycle"] -> lifecycle
        size_t predLen = 0;
        while (predText[predLen] != 0) predLen++;
        auto preds = (cast(const(char)*) predText)[0 .. predLen];

        auto dIdx = indexOf(preds, "immediate:");
        if (dIdx < 0) continue;
        size_t nameStart = cast(size_t) dIdx + 10; // skip "immediate:"
        size_t nameEnd = nameStart;
        while (nameEnd < predLen && preds[nameEnd] != '"') nameEnd++;
        if (nameEnd == nameStart) continue;
        auto name = preds[nameStart .. nameEnd];

        // Delivery check is handled by the NOT EXISTS in the outer query (session-scoped).

        // Check "after" timestamp
        size_t attrLen = 0;
        while (attrText[attrLen] != 0) attrLen++;
        auto attrs = (cast(const(char)*) attrText)[0 .. attrLen];

        auto afterIdx = indexOf(attrs, `"after":`);
        if (afterIdx < 0) continue;
        size_t aPos = cast(size_t) afterIdx + 8;
        long afterVal = 0;
        while (aPos < attrLen && attrs[aPos] >= '0' && attrs[aPos] <= '9') {
            afterVal = afterVal * 10 + (attrs[aPos] - '0');
            aPos++;
        }
        if (now < afterVal) continue;

        // Extract "detail" from attributes
        auto detIdx = indexOf(attrs, `"detail":"`);
        if (detIdx < 0) continue;
        size_t mPos = cast(size_t) detIdx + 10;
        size_t mLen = 0;
        while (mPos + mLen < attrLen && mLen < msgBuf.length && attrs[mPos + mLen] != '"')
            mLen++;

        // Copy into static buffers
        size_t nLen = nameEnd - nameStart;
        if (nLen > nameBuf.length) nLen = nameBuf.length;
        foreach (i; 0 .. nLen) nameBuf[i] = name[i];
        foreach (i; 0 .. mLen) msgBuf[i] = attrs[mPos + i];

        // Project context for delivery receipt — only set when project-matched.
        // Session-matched rows leave it empty; the session itself is recorded
        // in the receipt by markImmediateDelivered.
        size_t pcLen = 0;
        if (!sessionMatch && projIdx >= 0) {
            pcLen = projEnd - cast(size_t) projIdx;
            if (pcLen > ctxBuf.length) pcLen = ctxBuf.length;
            foreach (i; 0 .. pcLen) ctxBuf[i] = ctxs[cast(size_t) projIdx + i];
        }

        // Copy message ID into buffer
        size_t idLen = 0;
        while (idText[idLen] != 0) idLen++;
        if (idLen > idBuf.length) idLen = idBuf.length;
        foreach (i; 0 .. idLen) idBuf[i] = idText[i];

        // Extract optional cwd + branch from attributes (set by writeCIStatus
        // so watch.d's late-binding queries the push's repo, not the watcher's).
        __gshared char[512] cwdBuf = 0;
        __gshared char[128] branchBuf = 0;
        size_t cwdLen = 0;
        size_t branchLen = 0;
        auto cwdIdx = indexOf(attrs, `"cwd":"`);
        if (cwdIdx >= 0) {
            size_t cp = cast(size_t) cwdIdx + 7;
            while (cp < attrLen && attrs[cp] != '"' && cwdLen < cwdBuf.length) {
                cwdBuf[cwdLen++] = attrs[cp++];
            }
        }
        auto branchIdx = indexOf(attrs, `"branch":"`);
        if (branchIdx >= 0) {
            size_t bp = cast(size_t) branchIdx + 10;
            while (bp < attrLen && attrs[bp] != '"' && branchLen < branchBuf.length) {
                branchBuf[branchLen++] = attrs[bp++];
            }
        }

        sqlite3_finalize(stmt);
        return ImmediateMsg(
            idBuf[0 .. idLen],
            nameBuf[0 .. nLen],
            msgBuf[0 .. mLen],
            ctxBuf[0 .. pcLen],
            cwdBuf[0 .. cwdLen],
            branchBuf[0 .. branchLen],
        );
    }

    sqlite3_finalize(stmt);
    return ImmediateMsg(null, null, null, null, null, null);
}

// Mark a specific immediate message as delivered for this session.
void markImmediateDelivered(sqlite3* db, const(char)[] msgId, const(char)[] projectContext, const(char)[] sessionId) {
    __gshared ZBuf predBuf;
    predBuf.reset();
    predBuf.put("delivered:");
    predBuf.put(msgId);

    auto ts = formatTimestamp();

    __gshared ZBuf subjects, predicates, contexts, actors, source, idBuf;

    jsonArray1(subjects, msgId);
    jsonArray1(predicates, predBuf.slice());

    // Include both project and session in contexts
    contexts.reset();
    contexts.put(`["`);
    contexts.put(projectContext);
    contexts.put(`","session:`);
    contexts.put(sessionId);
    contexts.put(`"]`);

    jsonArray1(actors, "ground");

    source.reset();
    source.put("ground ");
    source.put(versionString());

    // Include session in ID to avoid collisions across sessions
    import parse : buildEventId;
    __gshared ZBuf idSeed;
    idSeed.reset();
    idSeed.put(predBuf.slice());
    idSeed.put("-");
    idSeed.put(sessionId);
    auto evId = buildEventId(idSeed.slice());
    idBuf.reset();
    idBuf.put(evId);

    enum emptyAttrs = `{}` ~ "\0";
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
    sqlite3_bind_text(stmt, 8, emptyAttrs.ptr, cast(int) emptyAttrs.length - 1, SQLITE_TRANSIENT);

    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

// Write a clippy-reminder immediate message for THIS session.
// Session-keyed: any .rs edit in this session, regardless of repo, writes
// the row tagged with the session. Free movement between repos works.
// Deterministic ID per session — repeated writes overwrite (INSERT OR REPLACE).
// Also clears delivered: receipts so the user re-sees the reminder after new edits.
void writeClippyReminder(sqlite3* db, const(char)[] sessionId) {
    import db : formatTimestamp, versionString;

    if (sessionId.length == 0) return;

    // Build deterministic ID: "immediate:clippy-reminder:<sessionId>"
    __gshared ZBuf idBuf;
    idBuf.reset();
    idBuf.put("immediate:clippy-reminder:");
    idBuf.put(sessionId);

    __gshared ZBuf predBuf;
    predBuf.reset();
    predBuf.put(`["immediate:clippy-reminder"]`);

    __gshared ZBuf ctxBuf;
    ctxBuf.reset();
    ctxBuf.put(`["session:`);
    ctxBuf.put(sessionId);
    ctxBuf.put(`"]`);

    enum detail = `Rust files edited since last cargo clippy. Run cargo clippy before pushing.`;
    enum attrs = `{"detail":"` ~ detail ~ `","after":0}` ~ "\0";

    auto ts = formatTimestamp();

    __gshared ZBuf srcBuf;
    srcBuf.reset();
    srcBuf.put("ground ");
    srcBuf.put(versionString());

    enum sql = "INSERT OR REPLACE INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return;
    sqlite3_bind_text(stmt, 1, idBuf.ptr(), cast(int) idBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, `["clippy"]`.ptr, 10, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, predBuf.ptr(), cast(int) predBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, ctxBuf.ptr(), cast(int) ctxBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, `["ground"]`.ptr, 10, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 6, ts.ptr, cast(int) ts.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 7, srcBuf.ptr(), cast(int) srcBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 8, attrs.ptr, cast(int) attrs.length - 1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);

    // Clear delivered: receipts for this message so all sessions re-deliver
    __gshared ZBuf delPred;
    delPred.reset();
    delPred.put("delivered:");
    delPred.put(idBuf.slice());

    enum delSql = "DELETE FROM attestations WHERE json_extract(predicates, '$[0]') = ?1\0";
    sqlite3_stmt* delStmt;
    if (sqlite3_prepare_v2(db, delSql.ptr, -1, &delStmt, null) != SQLITE_OK)
        return;
    sqlite3_bind_text(delStmt, 1, delPred.ptr(), cast(int) delPred.len, SQLITE_TRANSIENT);
    sqlite3_step(delStmt);
    sqlite3_finalize(delStmt);
}

// Delete this session's clippy-reminder (called when cargo clippy runs).
void deleteClippyReminder(sqlite3* db, const(char)[] sessionId) {
    if (sessionId.length == 0) return;

    __gshared ZBuf idBuf;
    idBuf.reset();
    idBuf.put("immediate:clippy-reminder:");
    idBuf.put(sessionId);

    enum sql = "DELETE FROM attestations WHERE id = ?1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return;
    sqlite3_bind_text(stmt, 1, idBuf.ptr(), cast(int) idBuf.len, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

// Write a ci-status immediate message for THIS session.
// Session-keyed: any push from this session, regardless of cwd or repo,
// produces a row tagged with the session. The session's watcher delivers
// it. Free movement between repos within one session works because cwd
// is never the key.
// Deterministic ID per session — repeated pushes overwrite (INSERT OR REPLACE).
// Also clears delivered: receipts so new pushes re-deliver.
void writeCIStatus(sqlite3* db, const(char)[] cwd, const(char)[] sessionId, int delaySec) {
    import db : formatTimestamp, versionString;

    if (sessionId.length == 0) return;

    // Build deterministic ID: "immediate:ci-status:<sessionId>"
    __gshared ZBuf idBuf;
    idBuf.reset();
    idBuf.put("immediate:ci-status:");
    idBuf.put(sessionId);

    __gshared ZBuf predBuf;
    predBuf.reset();
    predBuf.put(`["immediate:ci-status"]`);

    __gshared ZBuf ctxBuf;
    ctxBuf.reset();
    ctxBuf.put(`["session:`);
    ctxBuf.put(sessionId);
    ctxBuf.put(`"]`);

    // Capture push-time branch from cwd (watcher's cwd at delivery may
    // be a different repo — session is the key now). Stored alongside cwd
    // so watch.d's late-binding can query the RIGHT repo's CI.
    import db : getBranch;
    auto branch = getBranch(cwd);
    if (branch is null) branch = "unknown";

    // Build attributes with after gate + push-time cwd + branch
    __gshared ZBuf attrBuf;
    attrBuf.reset();
    attrBuf.put(`{"detail":"Checking CI...","cwd":"`);
    foreach (c; cwd) {
        if (c == '"') attrBuf.put(`\"`);
        else if (c == '\\') attrBuf.put(`\\`);
        else attrBuf.putChar(c);
    }
    attrBuf.put(`","branch":"`);
    foreach (c; branch) {
        if (c == '"') attrBuf.put(`\"`);
        else if (c == '\\') attrBuf.put(`\\`);
        else attrBuf.putChar(c);
    }
    attrBuf.put(`","after":`);
    auto afterUnix = cast(long) time(null) + delaySec;
    char[20] tbuf = 0;
    int tlen = 0;
    long v = afterUnix;
    if (v == 0) { tbuf[0] = '0'; tlen = 1; }
    else {
        while (v > 0 && tlen < 19) { tbuf[tlen++] = cast(char)('0' + v % 10); v /= 10; }
        foreach (i; 0 .. tlen / 2) { auto tmp = tbuf[i]; tbuf[i] = tbuf[tlen - 1 - i]; tbuf[tlen - 1 - i] = tmp; }
    }
    attrBuf.put(tbuf[0 .. tlen]);
    attrBuf.put(`}`);

    auto ts = formatTimestamp();

    __gshared ZBuf srcBuf;
    srcBuf.reset();
    srcBuf.put("ground ");
    srcBuf.put(versionString());

    enum sql = "INSERT OR REPLACE INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return;
    sqlite3_bind_text(stmt, 1, idBuf.ptr(), cast(int) idBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, `["ci"]`.ptr, 6, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, predBuf.ptr(), cast(int) predBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, ctxBuf.ptr(), cast(int) ctxBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, `["ground"]`.ptr, 10, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 6, ts.ptr, cast(int) ts.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 7, srcBuf.ptr(), cast(int) srcBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 8, attrBuf.ptr(), cast(int) attrBuf.len, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);

    // Clear delivered: receipts so all sessions re-deliver
    __gshared ZBuf delPred;
    delPred.reset();
    delPred.put("delivered:");
    delPred.put(idBuf.slice());

    enum delSql = "DELETE FROM attestations WHERE json_extract(predicates, '$[0]') = ?1\0";
    sqlite3_stmt* delStmt;
    if (sqlite3_prepare_v2(db, delSql.ptr, -1, &delStmt, null) != SQLITE_OK)
        return;
    sqlite3_bind_text(delStmt, 1, delPred.ptr(), cast(int) delPred.len, SQLITE_TRANSIENT);
    sqlite3_step(delStmt);
    sqlite3_finalize(delStmt);
}

// --- Tests ---

unittest {
    // Immediate message is readable by readImmediateMessage
    import db : sqlite3_open, sqlite3_exec, SQLITE_OK, sqlite3_close;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);

    enum createSql = "CREATE TABLE attestations (id TEXT PRIMARY KEY, subjects TEXT, predicates TEXT, contexts TEXT, actors TEXT, timestamp TEXT, source TEXT, attributes TEXT)\0";
    sqlite3_exec(db, createSql.ptr, null, null, null);

    enum insertSql = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES ('test-1', '[\"qntx\"]', '[\"immediate:lifecycle\"]', '[\"project:teranos/QNTX\"]', '[\"qntx-server\"]', '2026-05-08 15:15:57', 'qntx-server', '{\"event\":\"started\",\"detail\":\"QNTX started on port 8770\",\"after\":0}')\0";
    sqlite3_exec(db, insertSql.ptr, null, null, null);

    auto result = readImmediateMessage(db, "/Users/test/SBVH/teranos/QNTX", "sess-test");
    assert(result.message !is null);
    assert(result.name == "lifecycle");

    sqlite3_close(db);
}

unittest {
    // Stale messages for another project must NOT block delivery to this project.
    // Reproduces: LIMIT 5 fills with unmatched project rows, watcher never reaches ours.
    import db : sqlite3_open, sqlite3_exec, SQLITE_OK, sqlite3_close;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);

    enum createSql = "CREATE TABLE attestations (id TEXT PRIMARY KEY, subjects TEXT, predicates TEXT, contexts TEXT, actors TEXT, timestamp TEXT, source TEXT, attributes TEXT)\0";
    sqlite3_exec(db, createSql.ptr, null, null, null);

    // 6 stale messages for a different project (older timestamps, fill any LIMIT)
    enum s1 = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES ('stale-1', '[\"x\"]', '[\"immediate:lifecycle\"]', '[\"project:QNTX/server\"]', '[\"x\"]', '2026-05-09 16:00:00', 'x', '{\"detail\":\"stale1\",\"after\":0}')\0";
    enum s2 = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES ('stale-2', '[\"x\"]', '[\"immediate:lifecycle\"]', '[\"project:QNTX/server\"]', '[\"x\"]', '2026-05-09 16:01:00', 'x', '{\"detail\":\"stale2\",\"after\":0}')\0";
    enum s3 = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES ('stale-3', '[\"x\"]', '[\"immediate:lifecycle\"]', '[\"project:QNTX/server\"]', '[\"x\"]', '2026-05-09 16:02:00', 'x', '{\"detail\":\"stale3\",\"after\":0}')\0";
    enum s4 = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES ('stale-4', '[\"x\"]', '[\"immediate:lifecycle\"]', '[\"project:QNTX/server\"]', '[\"x\"]', '2026-05-09 16:03:00', 'x', '{\"detail\":\"stale4\",\"after\":0}')\0";
    enum s5 = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES ('stale-5', '[\"x\"]', '[\"immediate:lifecycle\"]', '[\"project:QNTX/server\"]', '[\"x\"]', '2026-05-09 16:04:00', 'x', '{\"detail\":\"stale5\",\"after\":0}')\0";
    enum s6 = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES ('stale-6', '[\"x\"]', '[\"immediate:lifecycle\"]', '[\"project:QNTX/server\"]', '[\"x\"]', '2026-05-09 16:05:00', 'x', '{\"detail\":\"stale6\",\"after\":0}')\0";
    sqlite3_exec(db, s1.ptr, null, null, null);
    sqlite3_exec(db, s2.ptr, null, null, null);
    sqlite3_exec(db, s3.ptr, null, null, null);
    sqlite3_exec(db, s4.ptr, null, null, null);
    sqlite3_exec(db, s5.ptr, null, null, null);
    sqlite3_exec(db, s6.ptr, null, null, null);

    // 1 message for OUR project (newer timestamp)
    enum ours = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES ('ours-1', '[\"qntx\"]', '[\"immediate:lifecycle\"]', '[\"project:teranos/QNTX\"]', '[\"qntx-server\"]', '2026-05-09 20:00:00', 'qntx-server', '{\"detail\":\"QNTX started\",\"after\":0}')\0";
    sqlite3_exec(db, ours.ptr, null, null, null);

    // Watcher cwd ends with teranos/QNTX — must find our message despite stale rows
    auto result = readImmediateMessage(db, "/Users/test/SBVH/teranos/QNTX", "sess-test");
    assert(result.message !is null, "stale messages for other project blocked delivery");
    assert(result.message == "QNTX started");

    sqlite3_close(db);
}

unittest {
    // Non-immediate message is NOT readable by readImmediateMessage
    import db : sqlite3_open, sqlite3_exec, SQLITE_OK, sqlite3_close;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);

    enum createSql = "CREATE TABLE attestations (id TEXT PRIMARY KEY, subjects TEXT, predicates TEXT, contexts TEXT, actors TEXT, timestamp TEXT, source TEXT, attributes TEXT)\0";
    sqlite3_exec(db, createSql.ptr, null, null, null);

    enum insertSql = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES ('test-2', '[\"qntx\"]', '[\"deferred:cluster-update\"]', '[\"project:teranos/QNTX\"]', '[\"qntx-server\"]', '2026-05-08 15:15:57', 'qntx-server', '{\"event\":\"cluster\",\"detail\":\"3 new clusters\",\"after\":0}')\0";
    sqlite3_exec(db, insertSql.ptr, null, null, null);

    auto result = readImmediateMessage(db, "/Users/test/SBVH/teranos/QNTX", "sess-A");
    assert(result.message is null);

    sqlite3_close(db);
}

unittest {
    // Per-session delivery: session B still sees a message after session A delivered it.
    import db : sqlite3_open, sqlite3_exec, SQLITE_OK, sqlite3_close;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);

    enum createSql = "CREATE TABLE attestations (id TEXT PRIMARY KEY, subjects TEXT, predicates TEXT, contexts TEXT, actors TEXT, timestamp TEXT, source TEXT, attributes TEXT)\0";
    sqlite3_exec(db, createSql.ptr, null, null, null);

    enum insertSql = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES ('msg-1', '[\"qntx\"]', '[\"immediate:lifecycle\"]', '[\"project:teranos/QNTX\"]', '[\"qntx-server\"]', '2026-05-08 15:15:57', 'qntx-server', '{\"event\":\"started\",\"detail\":\"QNTX started\",\"after\":0}')\0";
    sqlite3_exec(db, insertSql.ptr, null, null, null);

    // Session A delivers it
    auto resultA = readImmediateMessage(db, "/Users/test/SBVH/teranos/QNTX", "sess-A");
    assert(resultA.message !is null, "session A should see the message");
    markImmediateDelivered(db, resultA.msgId, resultA.projectContext, "sess-A");

    // Session B must still see it
    auto resultB = readImmediateMessage(db, "/Users/test/SBVH/teranos/QNTX", "sess-B");
    assert(resultB.message !is null, "session B should still see the message after A delivered");
    assert(resultB.message == "QNTX started");

    // Session A must NOT see it again
    auto resultA2 = readImmediateMessage(db, "/Users/test/SBVH/teranos/QNTX", "sess-A");
    assert(resultA2.message is null, "session A should not see it again");

    sqlite3_close(db);
}

unittest {
    // Multiple messages with the same name must ALL be delivered.
    import db : sqlite3_open, sqlite3_exec, SQLITE_OK, sqlite3_close;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);

    enum createSql = "CREATE TABLE attestations (id TEXT PRIMARY KEY, subjects TEXT, predicates TEXT, contexts TEXT, actors TEXT, timestamp TEXT, source TEXT, attributes TEXT)\0";
    sqlite3_exec(db, createSql.ptr, null, null, null);

    enum m1 = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES ('lc-1', '[\"qntx\"]', '[\"immediate:lifecycle\"]', '[\"project:teranos/QNTX\"]', '[\"qntx\"]', '2026-05-11 20:00:00', 'qntx', '{\"detail\":\"QNTX started\",\"after\":0}')\0";
    enum m2 = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES ('pl-1', '[\"qntx\"]', '[\"immediate:lifecycle\"]', '[\"project:teranos/QNTX\"]', '[\"qntx\"]', '2026-05-11 20:00:01', 'qntx', '{\"detail\":\"spindle started\",\"after\":0}')\0";
    enum m3 = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES ('pl-2', '[\"qntx\"]', '[\"immediate:lifecycle\"]', '[\"project:teranos/QNTX\"]', '[\"qntx\"]', '2026-05-11 20:00:02', 'qntx', '{\"detail\":\"raven started\",\"after\":0}')\0";
    sqlite3_exec(db, m1.ptr, null, null, null);
    sqlite3_exec(db, m2.ptr, null, null, null);
    sqlite3_exec(db, m3.ptr, null, null, null);

    // Deliver first, mark it
    auto r1 = readImmediateMessage(db, "/Users/test/SBVH/teranos/QNTX", "sess-X");
    assert(r1.message !is null);
    assert(r1.message == "QNTX started");
    markImmediateDelivered(db, r1.msgId, r1.projectContext, "sess-X");

    // Second message must still be visible (same name, different ID)
    auto r2 = readImmediateMessage(db, "/Users/test/SBVH/teranos/QNTX", "sess-X");
    assert(r2.message !is null, "second message with same name was dropped");
    assert(r2.message == "spindle started");
    markImmediateDelivered(db, r2.msgId, r2.projectContext, "sess-X");

    // Third
    auto r3 = readImmediateMessage(db, "/Users/test/SBVH/teranos/QNTX", "sess-X");
    assert(r3.message !is null, "third message with same name was dropped");
    assert(r3.message == "raven started");
    markImmediateDelivered(db, r3.msgId, r3.projectContext, "sess-X");

    // No more
    auto r4 = readImmediateMessage(db, "/Users/test/SBVH/teranos/QNTX", "sess-X");
    assert(r4.message is null, "should be empty after all delivered");

    sqlite3_close(db);
}

unittest {
    // writeClippyReminder + readImmediateMessage roundtrip
    import db : sqlite3_open, sqlite3_exec, SQLITE_OK, sqlite3_close;
    sqlite3* testDb;
    assert(sqlite3_open(":memory:", &testDb) == SQLITE_OK);

    enum createSql = "CREATE TABLE attestations (id TEXT PRIMARY KEY, subjects TEXT, predicates TEXT, contexts TEXT, actors TEXT, timestamp TEXT, source TEXT, attributes TEXT)\0";
    sqlite3_exec(testDb, createSql.ptr, null, null, null);

    writeClippyReminder(testDb, "sess-clippy");
    auto result = readImmediateMessage(testDb, "/Users/test/SBVH/teranos/QNTX", "sess-clippy");
    assert(result.message !is null, "clippy reminder not readable after write");
    assert(result.name == "clippy-reminder");

    sqlite3_close(testDb);
}

unittest {
    // Dedup: two writes produce one row (INSERT OR REPLACE)
    import db : sqlite3_open, sqlite3_exec, SQLITE_OK, sqlite3_close,
                sqlite3_prepare_v2, sqlite3_step, sqlite3_column_int64,
                sqlite3_finalize, sqlite3_stmt, SQLITE_ROW;
    sqlite3* testDb;
    assert(sqlite3_open(":memory:", &testDb) == SQLITE_OK);

    enum createSql = "CREATE TABLE attestations (id TEXT PRIMARY KEY, subjects TEXT, predicates TEXT, contexts TEXT, actors TEXT, timestamp TEXT, source TEXT, attributes TEXT)\0";
    sqlite3_exec(testDb, createSql.ptr, null, null, null);

    writeClippyReminder(testDb, "sess-dedup");
    writeClippyReminder(testDb, "sess-dedup");

    enum countSql = "SELECT COUNT(*) FROM attestations WHERE id LIKE 'immediate:clippy-reminder:%'\0";
    sqlite3_stmt* stmt;
    assert(sqlite3_prepare_v2(testDb, countSql.ptr, -1, &stmt, null) == SQLITE_OK);
    assert(sqlite3_step(stmt) == SQLITE_ROW);
    assert(sqlite3_column_int64(stmt, 0) == 1, "expected exactly 1 row after two writes");
    sqlite3_finalize(stmt);

    sqlite3_close(testDb);
}

unittest {
    // deleteClippyReminder removes the row
    import db : sqlite3_open, sqlite3_exec, SQLITE_OK, sqlite3_close;
    sqlite3* testDb;
    assert(sqlite3_open(":memory:", &testDb) == SQLITE_OK);

    enum createSql = "CREATE TABLE attestations (id TEXT PRIMARY KEY, subjects TEXT, predicates TEXT, contexts TEXT, actors TEXT, timestamp TEXT, source TEXT, attributes TEXT)\0";
    sqlite3_exec(testDb, createSql.ptr, null, null, null);

    writeClippyReminder(testDb, "sess-del");
    auto r1 = readImmediateMessage(testDb, "/Users/test/SBVH/teranos/QNTX", "sess-del");
    assert(r1.message !is null, "should exist before delete");

    deleteClippyReminder(testDb, "sess-del");
    auto r2 = readImmediateMessage(testDb, "/Users/test/SBVH/teranos/QNTX", "sess-del");
    assert(r2.message is null, "should be gone after delete");

    sqlite3_close(testDb);
}

unittest {
    // Write after delete is still readable (delivery receipts cleared)
    import db : sqlite3_open, sqlite3_exec, SQLITE_OK, sqlite3_close;
    sqlite3* testDb;
    assert(sqlite3_open(":memory:", &testDb) == SQLITE_OK);

    enum createSql = "CREATE TABLE attestations (id TEXT PRIMARY KEY, subjects TEXT, predicates TEXT, contexts TEXT, actors TEXT, timestamp TEXT, source TEXT, attributes TEXT)\0";
    sqlite3_exec(testDb, createSql.ptr, null, null, null);

    // Write, deliver, delete, re-write
    writeClippyReminder(testDb, "sess-rw");
    auto r1 = readImmediateMessage(testDb, "/Users/test/SBVH/teranos/QNTX", "sess-rw");
    assert(r1.message !is null);
    markImmediateDelivered(testDb, r1.msgId, r1.projectContext, "sess-rw");

    // After delivery, same session should NOT see it
    auto r2 = readImmediateMessage(testDb, "/Users/test/SBVH/teranos/QNTX", "sess-rw");
    assert(r2.message is null, "should not see after delivery");

    // Delete and re-write — clears delivery receipts
    deleteClippyReminder(testDb, "sess-rw");
    writeClippyReminder(testDb, "sess-rw");

    // Same session should see it again (receipts cleared by writeClippyReminder)
    auto r3 = readImmediateMessage(testDb, "/Users/test/SBVH/teranos/QNTX", "sess-rw");
    assert(r3.message !is null, "should be readable again after delete+write");

    sqlite3_close(testDb);
}

unittest {
    // writeCIStatus roundtrip: write with delaySec=0, readable by readImmediateMessage
    import db : sqlite3_open, sqlite3_exec, SQLITE_OK, sqlite3_close;
    sqlite3* testDb;
    assert(sqlite3_open(":memory:", &testDb) == SQLITE_OK);

    enum createSql = "CREATE TABLE attestations (id TEXT PRIMARY KEY, subjects TEXT, predicates TEXT, contexts TEXT, actors TEXT, timestamp TEXT, source TEXT, attributes TEXT)\0";
    sqlite3_exec(testDb, createSql.ptr, null, null, null);

    writeCIStatus(testDb, "/Users/test/SBVH/teranos/ground", "sess-ci", 0);
    auto result = readImmediateMessage(testDb, "/Users/test/SBVH/teranos/ground", "sess-ci");
    assert(result.message !is null, "ci-status not readable after write");
    assert(result.name == "ci-status");

    sqlite3_close(testDb);
}

unittest {
    // writeCIStatus dedup: two writes produce one row
    import db : sqlite3_open, sqlite3_exec, SQLITE_OK, sqlite3_close,
                sqlite3_prepare_v2, sqlite3_step, sqlite3_column_int64,
                sqlite3_finalize, sqlite3_stmt, SQLITE_ROW;
    sqlite3* testDb;
    assert(sqlite3_open(":memory:", &testDb) == SQLITE_OK);

    enum createSql = "CREATE TABLE attestations (id TEXT PRIMARY KEY, subjects TEXT, predicates TEXT, contexts TEXT, actors TEXT, timestamp TEXT, source TEXT, attributes TEXT)\0";
    sqlite3_exec(testDb, createSql.ptr, null, null, null);

    writeCIStatus(testDb, "/Users/test/SBVH/teranos/ground", "sess-ci-dedup", 0);
    writeCIStatus(testDb, "/Users/test/SBVH/teranos/ground", "sess-ci-dedup", 0);

    enum countSql = "SELECT COUNT(*) FROM attestations WHERE id LIKE 'immediate:ci-status:%'\0";
    sqlite3_stmt* stmt;
    assert(sqlite3_prepare_v2(testDb, countSql.ptr, -1, &stmt, null) == SQLITE_OK);
    assert(sqlite3_step(stmt) == SQLITE_ROW);
    assert(sqlite3_column_int64(stmt, 0) == 1, "expected exactly 1 row after two writes");
    sqlite3_finalize(stmt);

    sqlite3_close(testDb);
}

unittest {
    // writeCIStatus after gate: write with delaySec=9999, NOT readable (gate not open)
    import db : sqlite3_open, sqlite3_exec, SQLITE_OK, sqlite3_close;
    sqlite3* testDb;
    assert(sqlite3_open(":memory:", &testDb) == SQLITE_OK);

    enum createSql = "CREATE TABLE attestations (id TEXT PRIMARY KEY, subjects TEXT, predicates TEXT, contexts TEXT, actors TEXT, timestamp TEXT, source TEXT, attributes TEXT)\0";
    sqlite3_exec(testDb, createSql.ptr, null, null, null);

    writeCIStatus(testDb, "/Users/test/SBVH/teranos/ground", "sess-ci-gate", 9999);
    auto result = readImmediateMessage(testDb, "/Users/test/SBVH/teranos/ground", "sess-ci-gate");
    assert(result.message is null, "ci-status should not be readable before gate opens");

    sqlite3_close(testDb);
}
