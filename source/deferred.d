module deferred;

import matcher : indexOf;
import sqlite : sqlite3, sqlite3_stmt, sqlite3_prepare_v2, sqlite3_bind_text,
                sqlite3_step, sqlite3_finalize, sqlite3_column_text,
                SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT,
                ZBuf, jsonArray1, getBranch, formatTimestamp, versionString, attestEvent;
import core.stdc.stdio : fread, FILE;
import core.stdc.time : time;

extern (C) {
    FILE* popen(const(char)* command, const(char)* type);
    int pclose(FILE* stream);
}

// --- Deferred message queue ---

struct DeferredMsg {
    const(char)[] name;    // e.g. "ci-check"
    const(char)[] message; // the context to deliver
}

// Builds {"event":"...","detail":"...","after":<unix>} — for deferred messages
void jsonAttributesDeferred(ref ZBuf buf, const(char)[] event, const(char)[] detail, long afterUnix) {
    buf.reset();
    buf.put(`{"event":"`);
    buf.put(event);
    buf.put(`","detail":"`);
    size_t written = 0;
    foreach (c; detail) {
        if (written >= 200) break;
        if (c == '"') buf.put(`\"`);
        else if (c == '\\') buf.put(`\\`);
        else if (c == '\n') buf.put(`\n`);
        else buf.putChar(c);
        written++;
    }
    buf.put(`","after":`);
    // Write unix timestamp as decimal
    char[20] tbuf = 0;
    int tlen = 0;
    long v = afterUnix;
    if (v == 0) { tbuf[0] = '0'; tlen = 1; }
    else {
        while (v > 0 && tlen < 19) { tbuf[tlen++] = cast(char)('0' + v % 10); v /= 10; }
        foreach (i; 0 .. tlen / 2) { auto tmp = tbuf[i]; tbuf[i] = tbuf[tlen - 1 - i]; tbuf[tlen - 1 - i] = tmp; }
    }
    buf.put(tbuf[0 .. tlen]);
    buf.put(`}`);
}

// Write a deferred message attestation with a deliver-after delay.
void writeDeferredMessage(
    sqlite3* db,
    const(char)[] name,
    const(char)[] cwd,
    const(char)[] sessionId,
    const(char)[] message,
    int delaySec
) {
    auto afterUnix = cast(long) time(null) + delaySec;

    __gshared ZBuf predBuf;
    predBuf.reset();
    predBuf.put("deferred:");
    predBuf.put(name);

    __gshared ZBuf attribs;
    jsonAttributesDeferred(attribs, predBuf.slice(), message, afterUnix);

    auto branch = getBranch(cwd);
    auto ts = formatTimestamp();

    __gshared ZBuf subjects;
    __gshared ZBuf predicates;
    __gshared ZBuf contexts;
    __gshared ZBuf actors;
    __gshared ZBuf source;
    __gshared ZBuf idBuf;

    jsonArray1(subjects, branch);
    jsonArray1(predicates, predBuf.slice());

    contexts.reset();
    contexts.put(`["session:`);
    contexts.put(sessionId);
    contexts.put(`"]`);

    jsonArray1(actors, "ground");

    source.reset();
    source.put("ground ");
    source.put(versionString());

    // Unique id for deferred message
    import parse : buildEventId;
    auto evId = buildEventId(predBuf.slice());
    idBuf.reset();
    idBuf.put(evId);

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
    sqlite3_bind_text(stmt, 8, attribs.ptr(), cast(int) attribs.len, SQLITE_TRANSIENT);

    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

// Read a pending deferred message for this session that's ready to deliver.
// Finds the newest deferred message that has no delivered attestation newer than it.
DeferredMsg readDeferredMessage(sqlite3* db, const(char)[] sessionId) {
    auto now = cast(long) time(null);

    // Find deferred attestations for this session, newest first
    enum sql = "SELECT predicates, attributes, timestamp FROM attestations WHERE json_extract(predicates, '$[0]') >= 'deferred:' AND json_extract(predicates, '$[0]') < 'deferred;' AND contexts LIKE ?1 ORDER BY timestamp DESC LIMIT 5\0";

    __gshared ZBuf ctx;
    ctx.reset();
    ctx.put("%session:");
    ctx.put(sessionId);
    ctx.put("%");

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return DeferredMsg(null, null);

    sqlite3_bind_text(stmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);

    __gshared char[256] nameBuf = 0;
    __gshared char[512] msgBuf = 0;

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        auto predText = sqlite3_column_text(stmt, 0);
        auto attrText = sqlite3_column_text(stmt, 1);
        auto tsText = sqlite3_column_text(stmt, 2);
        if (predText is null || attrText is null) continue;

        // Extract name from predicates: ["deferred:ci-check"] -> ci-check
        size_t predLen = 0;
        while (predText[predLen] != 0) predLen++;
        auto preds = (cast(const(char)*) predText)[0 .. predLen];

        // Find "deferred:" in predicates
        auto dIdx = indexOf(preds, "deferred:");
        if (dIdx < 0) continue;
        size_t nameStart = cast(size_t) dIdx + 9; // skip "deferred:"
        size_t nameEnd = nameStart;
        while (nameEnd < predLen && preds[nameEnd] != '"') nameEnd++;
        if (nameEnd == nameStart) continue;
        auto name = preds[nameStart .. nameEnd];

        // Check if a delivered attestation exists that's newer than this deferred
        // Query: any delivered:<name> with timestamp >= this deferred's timestamp
        if (tsText !is null) {
            size_t tsLen = 0;
            while (tsText[tsLen] != 0) tsLen++;

            enum delSql = "SELECT 1 FROM attestations WHERE json_extract(predicates, '$[0]') = ?1 AND contexts LIKE ?2 AND timestamp >= ?3 LIMIT 1\0";
            sqlite3_stmt* delStmt;
            if (sqlite3_prepare_v2(db, delSql.ptr, -1, &delStmt, null) == SQLITE_OK) {
                __gshared ZBuf delPred;
                delPred.reset();
                delPred.put(`delivered:`);
                delPred.put(name);
                sqlite3_bind_text(delStmt, 1, delPred.ptr(), cast(int) delPred.len, SQLITE_TRANSIENT);
                sqlite3_bind_text(delStmt, 2, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
                sqlite3_bind_text(delStmt, 3, tsText, cast(int) tsLen, SQLITE_TRANSIENT);
                bool delivered = sqlite3_step(delStmt) == SQLITE_ROW;
                sqlite3_finalize(delStmt);
                if (delivered) continue;
            }
        }

        // Extract "after" from attributes
        size_t attrLen = 0;
        while (attrText[attrLen] != 0) attrLen++;
        auto attrs = (cast(const(char)*) attrText)[0 .. attrLen];

        auto afterIdx = indexOf(attrs, `"after":`);
        if (afterIdx < 0) continue;
        size_t aPos = cast(size_t) afterIdx + 8; // skip "after":
        long afterVal = 0;
        while (aPos < attrLen && attrs[aPos] >= '0' && attrs[aPos] <= '9') {
            afterVal = afterVal * 10 + (attrs[aPos] - '0');
            aPos++;
        }
        if (now < afterVal) continue; // not ready yet

        // Extract "detail" from attributes (the message)
        auto detIdx = indexOf(attrs, `"detail":"`);
        if (detIdx < 0) continue;
        size_t mPos = cast(size_t) detIdx + 10; // skip "detail":"
        size_t mLen = 0;
        while (mPos + mLen < attrLen && mLen < msgBuf.length && attrs[mPos + mLen] != '"')
            mLen++;

        // Copy into static buffers
        size_t nLen = nameEnd - nameStart;
        if (nLen > nameBuf.length) nLen = nameBuf.length;
        foreach (i; 0 .. nLen) nameBuf[i] = name[i];
        foreach (i; 0 .. mLen) msgBuf[i] = attrs[mPos + i];

        sqlite3_finalize(stmt);
        return DeferredMsg(nameBuf[0 .. nLen], msgBuf[0 .. mLen]);
    }

    sqlite3_finalize(stmt);
    return DeferredMsg(null, null);
}

// Mark a deferred message as delivered.
void markDelivered(sqlite3* db, const(char)[] name, const(char)[] cwd, const(char)[] sessionId) {
    __gshared ZBuf predBuf;
    predBuf.reset();
    predBuf.put("delivered:");
    predBuf.put(name);

    attestEvent(db, predBuf.slice(), cwd, sessionId, "{}");
}

// --- Project-scoped deferred messages ---
// QNTX writes deferred attestations with contexts like ["project:tmp3/QNTX"].
// Ground picks them up when cwd ends with the project path.

struct ProjectDeferredMsg {
    const(char)[] name;
    const(char)[] message;
    const(char)[] projectContext; // e.g. "project:tmp3/QNTX" — needed for delivery ack
}

// Read a pending project-scoped deferred message matching this cwd.
ProjectDeferredMsg readProjectDeferredMessage(sqlite3* db, const(char)[] cwd) {
    auto now = cast(long) time(null);

    enum sql = "SELECT predicates, attributes, contexts, timestamp FROM attestations WHERE json_extract(predicates, '$[0]') >= 'deferred:' AND json_extract(predicates, '$[0]') < 'deferred;' AND contexts LIKE '%project:%' ORDER BY timestamp DESC LIMIT 5\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK)
        return ProjectDeferredMsg(null, null, null);

    __gshared char[256] nameBuf = 0;
    __gshared char[512] msgBuf = 0;
    __gshared char[256] ctxBuf = 0;

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        auto predText = sqlite3_column_text(stmt, 0);
        auto attrText = sqlite3_column_text(stmt, 1);
        auto ctxText = sqlite3_column_text(stmt, 2);
        auto tsText = sqlite3_column_text(stmt, 3);
        if (predText is null || attrText is null || ctxText is null) continue;

        // Extract project path from contexts: ["project:tmp3/QNTX"] -> tmp3/QNTX
        size_t ctxLen = 0;
        while (ctxText[ctxLen] != 0) ctxLen++;
        auto ctxs = (cast(const(char)*) ctxText)[0 .. ctxLen];

        auto projIdx = indexOf(ctxs, "project:");
        if (projIdx < 0) continue;
        size_t projStart = cast(size_t) projIdx + 8; // skip "project:"
        size_t projEnd = projStart;
        while (projEnd < ctxLen && ctxs[projEnd] != '"') projEnd++;
        if (projEnd == projStart) continue;
        auto projPath = ctxs[projStart .. projEnd];

        // Check if cwd ends with the project path
        if (cwd.length < projPath.length) continue;
        if (cwd[cwd.length - projPath.length .. $] != projPath) continue;

        // Extract name from predicates: ["deferred:cluster-update"] -> cluster-update
        size_t predLen = 0;
        while (predText[predLen] != 0) predLen++;
        auto preds = (cast(const(char)*) predText)[0 .. predLen];

        auto dIdx = indexOf(preds, "deferred:");
        if (dIdx < 0) continue;
        size_t nameStart = cast(size_t) dIdx + 9;
        size_t nameEnd = nameStart;
        while (nameEnd < predLen && preds[nameEnd] != '"') nameEnd++;
        if (nameEnd == nameStart) continue;
        auto name = preds[nameStart .. nameEnd];

        // Check if already delivered (delivered:<name> with same project context)
        if (tsText !is null) {
            size_t tsLen = 0;
            while (tsText[tsLen] != 0) tsLen++;

            enum delSql = "SELECT 1 FROM attestations WHERE json_extract(predicates, '$[0]') = ?1 AND contexts LIKE ?2 AND rowid > (SELECT rowid FROM attestations WHERE timestamp = ?3 AND json_extract(predicates, '$[0]') = ?4 LIMIT 1) LIMIT 1\0";
            sqlite3_stmt* delStmt;
            if (sqlite3_prepare_v2(db, delSql.ptr, -1, &delStmt, null) == SQLITE_OK) {
                __gshared ZBuf delPred;
                delPred.reset();
                delPred.put(`delivered:`);
                delPred.put(name);
                __gshared ZBuf projCtx;
                projCtx.reset();
                projCtx.put(`%project:`);
                projCtx.put(projPath);
                projCtx.put(`%`);
                __gshared ZBuf defPred;
                defPred.reset();
                defPred.put(`deferred:`);
                defPred.put(name);
                sqlite3_bind_text(delStmt, 1, delPred.ptr(), cast(int) delPred.len, SQLITE_TRANSIENT);
                sqlite3_bind_text(delStmt, 2, projCtx.ptr(), cast(int) projCtx.len, SQLITE_TRANSIENT);
                sqlite3_bind_text(delStmt, 3, tsText, cast(int) tsLen, SQLITE_TRANSIENT);
                sqlite3_bind_text(delStmt, 4, defPred.ptr(), cast(int) defPred.len, SQLITE_TRANSIENT);
                bool delivered = sqlite3_step(delStmt) == SQLITE_ROW;
                sqlite3_finalize(delStmt);
                if (delivered) continue;
            }
        }

        // Extract "after" from attributes
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

        // Store full project context for ack: "project:tmp3/QNTX"
        size_t pcLen = projEnd - (cast(size_t) projIdx);
        if (pcLen > ctxBuf.length) pcLen = ctxBuf.length;
        foreach (i; 0 .. pcLen) ctxBuf[i] = ctxs[cast(size_t) projIdx + i];

        sqlite3_finalize(stmt);
        return ProjectDeferredMsg(nameBuf[0 .. nLen], msgBuf[0 .. mLen], ctxBuf[0 .. pcLen]);
    }

    sqlite3_finalize(stmt);
    return ProjectDeferredMsg(null, null, null);
}

// Mark a project-scoped deferred message as delivered.
// Writes with the same project context so QNTX can check the ack.
void markProjectDelivered(sqlite3* db, const(char)[] name, const(char)[] projectContext) {
    __gshared ZBuf predBuf;
    predBuf.reset();
    predBuf.put("delivered:");
    predBuf.put(name);

    auto ts = formatTimestamp();

    __gshared ZBuf subjects, predicates, contexts, actors, source, idBuf;

    jsonArray1(subjects, name);
    jsonArray1(predicates, predBuf.slice());

    contexts.reset();
    contexts.put(`["`);
    contexts.put(projectContext);
    contexts.put(`"]`);

    jsonArray1(actors, "ground");

    source.reset();
    source.put("ground ");
    source.put(versionString());

    import parse : buildEventId;
    auto evId = buildEventId(predBuf.slice());
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

// --- CI helpers ---

// Average of the top 3 longest recent CI durations for a branch (seconds).
// Returns 0 if no data or gh fails.
int getCIAvgDuration(const(char)[] cwd, const(char)[] branch) {
    __gshared ZBuf ghCmd;
    ghCmd.reset();
    ghCmd.put("cd ");
    ghCmd.put(cwd);
    ghCmd.put(" && gh run list --branch ");
    ghCmd.put(branch);
    ghCmd.put(` --limit 10 --json startedAt,updatedAt --jq '[.[] | (((.updatedAt | fromdateiso8601) - (.startedAt | fromdateiso8601)))] | sort | reverse | .[0:3] | if length == 0 then 0 else (add / length | floor) end'`);

    auto pipe = popen(ghCmd.ptr(), "r");
    if (pipe is null) return 0;

    __gshared char[32] outBuf = 0;
    auto n = fread(&outBuf[0], 1, outBuf.length - 1, pipe);
    pclose(pipe);

    if (n == 0) return 0;

    // Parse integer from output
    int result = 0;
    foreach (i; 0 .. n) {
        if (outBuf[i] >= '0' && outBuf[i] <= '9')
            result = result * 10 + (outBuf[i] - '0');
        else
            break;
    }
    return result;
}

// Compute deferred delay: avg duration + proportional buffer (d/22 + d/33 + d/44), capped at 120s.
int computeDelay(int avgDuration) {
    if (avgDuration <= 0) return 60;
    int buffer = avgDuration / 22 + avgDuration / 33 + avgDuration / 44;
    if (buffer > 120) buffer = 120;
    return avgDuration + buffer;
}

// Query live CI status for a branch. Returns a human-readable summary.
// Runs gh run list at delivery time so the message reflects actual state.
const(char)[] checkCIStatus(const(char)[] cwd, const(char)[] branch) {
    __gshared ZBuf ghCmd;
    ghCmd.reset();
    ghCmd.put("cd ");
    ghCmd.put(cwd);
    ghCmd.put(" && gh run list --branch ");
    ghCmd.put(branch);
    ghCmd.put(` --limit 1 --json conclusion,name,event --jq 'if length == 0 then empty else .[0] | "\(.conclusion // "in_progress") \(.name) (\(.event))" end'`);

    auto pipe = popen(ghCmd.ptr(), "r");
    if (pipe is null) return null;

    __gshared char[512] outBuf = 0;
    auto n = fread(&outBuf[0], 1, outBuf.length - 1, pipe);
    pclose(pipe);

    if (n == 0) return null;
    // Trim trailing newline
    if (n > 0 && outBuf[n - 1] == '\n') n--;
    if (n == 0) return null;

    // Prepend "CI: " label
    __gshared char[520] resultBuf = 0;
    enum prefix = "CI: ";
    foreach (i, c; prefix) resultBuf[i] = c;
    foreach (i; 0 .. n) resultBuf[prefix.length + i] = outBuf[i];
    return resultBuf[0 .. prefix.length + n];
}

// --- Defer write/read cycle tests ---

unittest {
    // Write a deferred message with 0 delay, read it back immediately
    import sqlite : sqlite3_open, sqlite3_exec, SQLITE_OK;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);

    // Create attestations table
    enum createSql = "CREATE TABLE attestations (id TEXT PRIMARY KEY, subjects TEXT, predicates TEXT, contexts TEXT, actors TEXT, timestamp TEXT, source TEXT, attributes TEXT)\0";
    sqlite3_exec(db, createSql.ptr, null, null, null);

    writeDeferredMessage(db, "test-control", "/tmp/project", "sess-123", "hello from defer", 0);

    auto result = readDeferredMessage(db, "sess-123");
    assert(result.name == "test-control");
    assert(result.message !is null);

    import sqlite : sqlite3_close;
    sqlite3_close(db);
}

unittest {
    // Deferred message with future delay is not yet readable
    import sqlite : sqlite3_open, sqlite3_exec, SQLITE_OK, sqlite3_close;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);

    enum createSql = "CREATE TABLE attestations (id TEXT PRIMARY KEY, subjects TEXT, predicates TEXT, contexts TEXT, actors TEXT, timestamp TEXT, source TEXT, attributes TEXT)\0";
    sqlite3_exec(db, createSql.ptr, null, null, null);

    writeDeferredMessage(db, "future-control", "/tmp/project", "sess-456", "not yet", 9999);

    auto result = readDeferredMessage(db, "sess-456");
    assert(result.message is null); // not ready yet

    sqlite3_close(db);
}

unittest {
    // markDelivered prevents re-delivery
    import sqlite : sqlite3_open, sqlite3_exec, SQLITE_OK, sqlite3_close;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);

    enum createSql = "CREATE TABLE attestations (id TEXT PRIMARY KEY, subjects TEXT, predicates TEXT, contexts TEXT, actors TEXT, timestamp TEXT, source TEXT, attributes TEXT)\0";
    sqlite3_exec(db, createSql.ptr, null, null, null);

    writeDeferredMessage(db, "once-control", "/tmp/project", "sess-789", "deliver once", 0);

    auto first = readDeferredMessage(db, "sess-789");
    assert(first.message !is null);

    markDelivered(db, first.name, "/tmp/project", "sess-789");

    auto second = readDeferredMessage(db, "sess-789");
    assert(second.message is null); // already delivered

    sqlite3_close(db);
}
