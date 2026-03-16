module stop;

import parse : extractBool, extractLastAssistantMessage, writeJsonString;
import sqlite : openDb, attestEvent,
                getBranch, sqlite3, sqlite3_close, ZBuf;
import core.stdc.stdio : stdout, fputs;

void putInt(ref ZBuf buf, long v) {
    char[20] digits = 0;
    int dLen = 0;
    if (v == 0) { digits[0] = '0'; dLen = 1; }
    else { while (v > 0) { digits[dLen++] = cast(char)('0' + v % 10); v /= 10; } }
    foreach (i; 0 .. dLen) buf.putChar(digits[dLen - 1 - i]);
}

// Notify loom of hook output so it appears as [hook] in weaves
void notifyLoomHook(const(char)[] cwd, const(char)[] sessionId, const(char)[] message) {
    import loom : sendToLoom;
    import sqlite : jsonArray1, buildSubject;
    auto branch = getBranch(cwd);
    if (branch is null) branch = "unknown";

    __gshared ZBuf subjects, predicates, contexts, attrBuf, subjectVal;
    buildSubject(subjectVal, cwd, branch);
    jsonArray1(subjects, subjectVal.slice());
    jsonArray1(predicates, "Hook");

    contexts.reset();
    contexts.put(`["session:`);
    contexts.put(sessionId);
    contexts.put(`"]`);

    attrBuf.reset();
    attrBuf.put(`{"hook_output":"`);
    foreach (c; message) {
        if (c == '"') attrBuf.put(`\"`);
        else if (c == '\\') attrBuf.put(`\\`);
        else attrBuf.putChar(c);
    }
    attrBuf.put(`"}`);

    sendToLoom(subjects, predicates, contexts, attrBuf.slice());
}

// Claude Code renders \n in reason as literal "\n", not as a line break.
void writeStopResponse(const(char)[] reason) {
    fputs(`{"decision":"block","reason":"`, stdout);
    writeJsonString(reason);
    fputs(`"}`, stdout);
    fputs("\n", stdout);
}

// cwd/sessionId stashed by handleStop so writeStopResponse callers don't need them
__gshared const(char)[] g_cwd;
__gshared const(char)[] g_sessionId;

void writeStopResponseAndNotify(const(char)[] reason) {
    writeStopResponse(reason);
    notifyLoomHook(g_cwd, g_sessionId, reason);
}

int handleStop(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    g_cwd = cwd;
    g_sessionId = sessionId;

    auto hookActive = extractBool(input, `"stop_hook_active"`);

    if (hookActive)
        return 0;

    auto db = openDb();
    if (db is null) return 0;

    {
        import trail : checkTrailControls;
        auto branch = getBranch(cwd);
        auto trailResult = checkTrailControls(branch, db);
        if (trailResult.control !is null) {
            __gshared ZBuf graundedAttrs;
            graundedAttrs.reset();
            graundedAttrs.put(`{"control":"`);
            graundedAttrs.put(trailResult.control.name);
            graundedAttrs.put(`"}`);
            attestEvent(db, "GraundedStop", cwd, sessionId, graundedAttrs.slice());
            sqlite3_close(db);
            writeStopResponseAndNotify(trailResult.reason);
            return 0;
        }
    }

    // Stop controls — pattern matching on last assistant message
    {
        import matcher : contains;
        import controls : stopScopes;
        import hooks : scopeMatches;
        auto lastMsg = extractLastAssistantMessage(input);
        if (lastMsg !is null) {
            foreach (ref sc; stopScopes) {
                if (!scopeMatches(sc.path, cwd))
                    continue;
                foreach (ref c; sc.controls) {
                    if (c.trigger.value.length == 0) continue;
                    if (!contains(lastMsg, c.trigger.value)) continue;

                    __gshared ZBuf stopAttrs;
                    stopAttrs.reset();
                    stopAttrs.put(`{"control":"`);
                    stopAttrs.put(c.name);
                    stopAttrs.put(`"}`);
                    attestEvent(db, "GraundedStop", cwd, sessionId, stopAttrs.slice());
                    sqlite3_close(db);
                    writeStopResponseAndNotify(c.msg.value);
                    return 0;
                }
            }
        }
    }

    // Check session-scoped deferred messages — deliver if ready
    {
        import deferred : readDeferredMessage, markDelivered, DeferredMsg, checkCIStatus;
        import matcher : contains;
        auto deferred = readDeferredMessage(db, sessionId);
        if (deferred.message !is null) {
            markDelivered(db, deferred.name, cwd, sessionId);

            // ci-check: query live status, say nothing if no runs exist
            if (contains(deferred.name, "ci-check")) {
                auto branch = getBranch(cwd);
                auto status = branch !is null ? checkCIStatus(cwd, branch) : null;
                if (status !is null) {
                    __gshared ZBuf ciBuf;
                    ciBuf.reset();
                    ciBuf.put("CI: ");
                    ciBuf.put(status);
                    sqlite3_close(db);
                    writeStopResponseAndNotify(ciBuf.slice());

                    return 0;
                }
                // No CI runs — nothing to report
                sqlite3_close(db);
                return 0;
            }

            sqlite3_close(db);
            writeStopResponseAndNotify(deferred.message);

            return 0;
        }
    }

    // Check project-scoped deferred messages (from QNTX) — only on main
    {
        auto branch = getBranch(cwd);
        if (branch == "main" || branch == "master") {
            import deferred : readProjectDeferredMessage, markProjectDelivered;
            auto projDeferred = readProjectDeferredMessage(db, cwd);
            if (projDeferred.message !is null) {
                markProjectDelivered(db, projDeferred.name, projDeferred.projectContext);
                sqlite3_close(db);
                writeStopResponseAndNotify(projDeferred.message);

                return 0;
            }
        }
    }

    // Per-event-type timing budgets — once per compaction window
    {
        import sqlite : attestationExists, sqlite3_prepare_v2, sqlite3_step, sqlite3_column_int64,
                        sqlite3_bind_text, sqlite3_finalize, sqlite3_stmt, SQLITE_OK, SQLITE_ROW,
                        SQLITE_TRANSIENT;

        if (!attestationExists(db, "GraundedStop", "timing-regression", sessionId)) {
            struct Budget { string event; long thresholdUs; }
            static immutable budgets = [
                Budget("PreToolUse",       50_000),
                Budget("PostToolUse",     100_000),
                Budget("UserPromptSubmit", 50_000),
                Budget("Stop",            500_000),
                Budget("SessionStart",  2_000_000),
            ];

            enum timingSql = "SELECT AVG(duration_us), COUNT(*) FROM (SELECT duration_us FROM timing WHERE hook_event = ?1 ORDER BY id DESC LIMIT 20)\0";

            foreach (ref b; budgets) {
                sqlite3_stmt* stmt;
                if (sqlite3_prepare_v2(db, timingSql.ptr, -1, &stmt, null) != SQLITE_OK)
                    continue;
                sqlite3_bind_text(stmt, 1, b.event.ptr, cast(int) b.event.length, SQLITE_TRANSIENT);
                if (sqlite3_step(stmt) == SQLITE_ROW) {
                    auto avgUs = sqlite3_column_int64(stmt, 0);
                    auto sampleCount = sqlite3_column_int64(stmt, 1);
                    if (sampleCount >= 10 && avgUs > b.thresholdUs) {
                        sqlite3_finalize(stmt);
                        auto avgMs = avgUs / 1000;
                        auto budgetMs = b.thresholdUs / 1000;
                        __gshared ZBuf timingMsg;
                        timingMsg.reset();
                        timingMsg.put("graunde timing regression: ");
                        timingMsg.put(b.event);
                        timingMsg.put(" averages ");
                        putInt(timingMsg, avgMs);
                        timingMsg.put("ms (budget ");
                        putInt(timingMsg, budgetMs);
                        enum VERSION = import(".version");
                        timingMsg.put("ms, graunde ");
                        foreach (vc; VERSION)
                            if (vc != '\n' && vc != '\r') timingMsg.putChar(vc);
                        timingMsg.put(")");
                        attestEvent(db, "GraundedStop", cwd, sessionId, `{"control":"timing-regression"}`);
                        sqlite3_close(db);
                        writeStopResponseAndNotify(timingMsg.slice());
                        return 0;
                    }
                }
                sqlite3_finalize(stmt);
            }
        }
    }

    sqlite3_close(db);
    return 0;
}
