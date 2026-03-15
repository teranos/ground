module stop;

import parse : extractBool, extractLastAssistantMessage, writeJsonString;
import sqlite : openDb, attestEvent,
                getBranch, sqlite3, sqlite3_close, ZBuf;
import core.stdc.stdio : stdout, fputs;

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

    // Check for lazy verification deferral
    {
        import matcher : contains;
        auto lastMsg = extractLastAssistantMessage(input);
        if (lastMsg !is null && contains(lastMsg, "Ready for you to verify")) {
            attestEvent(db, "GraundedStop", cwd, sessionId, `{"control":"lazy-verify"}`);
            sqlite3_close(db);
            writeStopResponseAndNotify("Do not ask the user to verify what you can verify yourself. Use your tools to verify as much as possible first. Only flag things that genuinely require human judgment or manual interaction.");
            return 0;
        }
    }

    // QNTX-scoped Stop controls
    {
        import matcher : contains, containsWord;
        auto lastMsg = extractLastAssistantMessage(input);
        if (lastMsg !is null && cwd !is null && contains(cwd, "/QNTX")) {
            if (contains(lastMsg, "make wasm")) {
                attestEvent(db, "GraundedStop", cwd, sessionId, `{"control":"make-dev-includes-wasm"}`);
                sqlite3_close(db);
                writeStopResponseAndNotify(`Please note that "make dev" also rebuilds the wasm, see the Makefile.`);
                return 0;
            }
            if (contains(lastMsg, "binary might be stale") || contains(lastMsg, "binary may be stale")) {
                attestEvent(db, "GraundedStop", cwd, sessionId, `{"control":"no-stale-binary-speculation"}`);
                sqlite3_close(db);
                writeStopResponseAndNotify(`The developer is always running the latest version. Do not speculate about stale binaries.`);
                return 0;
            }
            if (containsWord(lastMsg, "port 877") || contains(lastMsg, "8820")) {
                attestEvent(db, "GraundedStop", cwd, sessionId, `{"control":"port-check-am-toml"}`);
                sqlite3_close(db);
                writeStopResponseAndNotify(`You mentioned a default port. Check am.toml in the project root for the actual port configuration.`);
                return 0;
            }
        }
    }

    // ego-death — catch overconfident language in responses
    {
        import matcher : contains;
        auto lastMsg = extractLastAssistantMessage(input);
        if (lastMsg !is null) {
            if (contains(lastMsg, "The most effective fix is")) {
                attestEvent(db, "GraundedStop", cwd, sessionId, `{"control":"ego-death"}`);
                sqlite3_close(db);
                writeStopResponseAndNotify(`You said "The most effective fix is" — according to whom? The user will go apeshit if you are pulling this out of your ass, be sure to ground it in verification or real facts.`);
                return 0;
            }
            if (contains(lastMsg, "feeling is probably")) {
                attestEvent(db, "GraundedStop", cwd, sessionId, `{"control":"ego-death"}`);
                sqlite3_close(db);
                writeStopResponseAndNotify(`You said "feeling is probably" — do not attribute subjective impressions to the user. They observe and report facts. Restate based on what was actually measured or said.`);
                return 0;
            }
            if (contains(lastMsg, "likely because")) {
                attestEvent(db, "GraundedStop", cwd, sessionId, `{"control":"ego-death"}`);
                sqlite3_close(db);
                writeStopResponseAndNotify(`You said "likely because" — that's a guess, not a diagnosis. Check the data before proposing a cause.`);
                return 0;
            }
            if (contains(lastMsg, "Nothing left to do")) {
                attestEvent(db, "GraundedStop", cwd, sessionId, `{"control":"ego-death"}`);
                sqlite3_close(db);
                writeStopResponseAndNotify(`You said "Nothing left to do" — you made a completeness claim. What specifically was not verified?`);
                return 0;
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

    // Timing regression check — once per compaction window
    {
        import sqlite : attestationExists, sqlite3_prepare_v2, sqlite3_step, sqlite3_column_int64,
                        sqlite3_finalize, sqlite3_stmt, SQLITE_OK, SQLITE_ROW;

        if (!attestationExists(db, "GraundedStop", "timing-regression", sessionId)) {
            enum timingSql = "SELECT AVG(duration_us) FROM (SELECT duration_us FROM timing ORDER BY id DESC LIMIT 20)\0";
            sqlite3_stmt* stmt;
            if (sqlite3_prepare_v2(db, timingSql.ptr, -1, &stmt, null) == SQLITE_OK) {
                if (sqlite3_step(stmt) == SQLITE_ROW) {
                    auto avgUs = sqlite3_column_int64(stmt, 0);
                    enum thresholdUs = 350_000; // 350ms budget
                    if (avgUs > thresholdUs) {
                        sqlite3_finalize(stmt);
                        auto avgMs = avgUs / 1000;
                        __gshared ZBuf timingMsg;
                        timingMsg.reset();
                        timingMsg.put("graunde timing regression: average event takes ");
                        // Write avgMs as decimal
                        char[10] digits = 0;
                        int dLen = 0;
                        auto v = avgMs;
                        if (v == 0) { digits[0] = '0'; dLen = 1; }
                        else { while (v > 0) { digits[dLen++] = cast(char)('0' + v % 10); v /= 10; } }
                        foreach (i; 0 .. dLen) timingMsg.putChar(digits[dLen - 1 - i]);
                        timingMsg.put("ms, budget is ");
                        enum thresholdMs = thresholdUs / 1000;
                        char[10] tDigits = 0;
                        int tLen = 0;
                        { auto tv = thresholdMs; if (tv == 0) { tDigits[0] = '0'; tLen = 1; } else { while (tv > 0) { tDigits[tLen++] = cast(char)('0' + tv % 10); tv /= 10; } } }
                        foreach (i; 0 .. tLen) timingMsg.putChar(tDigits[tLen - 1 - i]);
                        timingMsg.put("ms. Check getBranch and db queries for optimization.");
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
