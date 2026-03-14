module stop;

import parse : extractBool, extractLastAssistantMessage, writeJsonString;
import sqlite : openDb, attestEvent,
                getBranch, sqlite3, sqlite3_close, ZBuf;
import core.stdc.stdio : stdout, fputs;

void writeStopResponse(const(char)[] reason) {
    fputs(`{"decision":"block","reason":"`, stdout);
    writeJsonString(reason);
    fputs(`"}`, stdout);
    fputs("\n", stdout);
}

int handleStop(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
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
            writeStopResponse(trailResult.reason);
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
            writeStopResponse("Do not ask the user to verify what you can verify yourself. Use your tools to verify as much as possible first. Only flag things that genuinely require human judgment or manual interaction.");
            return 0;
        }
    }

    // QNTX-scoped Stop controls
    {
        import matcher : contains;
        auto lastMsg = extractLastAssistantMessage(input);
        if (lastMsg !is null && cwd !is null && contains(cwd, "/QNTX")) {
            if (contains(lastMsg, "make wasm")) {
                attestEvent(db, "GraundedStop", cwd, sessionId, `{"control":"make-dev-includes-wasm"}`);
                sqlite3_close(db);
                writeStopResponse(`Please note that "make dev" also rebuilds the wasm, see the Makefile.`);
                return 0;
            }
            if (contains(lastMsg, "binary might be stale") || contains(lastMsg, "binary may be stale")) {
                attestEvent(db, "GraundedStop", cwd, sessionId, `{"control":"no-stale-binary-speculation"}`);
                sqlite3_close(db);
                writeStopResponse(`The developer is always running the latest version. Do not speculate about stale binaries.`);
                return 0;
            }
            if (contains(lastMsg, "port 877")) {
                attestEvent(db, "GraundedStop", cwd, sessionId, `{"control":"port-877-check-am-toml"}`);
                sqlite3_close(db);
                writeStopResponse(`You mentioned port 877. Check am.toml in the project root for the actual port configuration.`);
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
                writeStopResponse(`You said "The most effective fix is" — according to whom? The user will go apeshit if you are pulling this out of your ass, be sure to ground it in verification or real facts.`);
                return 0;
            }
            if (contains(lastMsg, "feeling is probably")) {
                attestEvent(db, "GraundedStop", cwd, sessionId, `{"control":"ego-death"}`);
                sqlite3_close(db);
                writeStopResponse(`You said "feeling is probably" — do not attribute subjective impressions to the user. They observe and report facts. Restate based on what was actually measured or said.`);
                return 0;
            }
            if (contains(lastMsg, "likely because")) {
                attestEvent(db, "GraundedStop", cwd, sessionId, `{"control":"ego-death"}`);
                sqlite3_close(db);
                writeStopResponse(`You said "likely because" — that's a guess, not a diagnosis. Check the data before proposing a cause.`);
                return 0;
            }
            if (contains(lastMsg, "Nothing left to do")) {
                attestEvent(db, "GraundedStop", cwd, sessionId, `{"control":"ego-death"}`);
                sqlite3_close(db);
                writeStopResponse(`You said "Nothing left to do" — you made a completeness claim. What specifically was not verified?`);
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
                    writeStopResponse(ciBuf.slice());
                    return 0;
                }
                // No CI runs — nothing to report
                sqlite3_close(db);
                return 0;
            }

            sqlite3_close(db);
            writeStopResponse(deferred.message);
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
                writeStopResponse(projDeferred.message);
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
                    enum thresholdUs = 300_000; // 300ms budget
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
                        timingMsg.put("ms, budget is 300ms. Check getBranch and db queries for optimization.");
                        attestEvent(db, "GraundedStop", cwd, sessionId, `{"control":"timing-regression"}`);
                        sqlite3_close(db);
                        writeStopResponse(timingMsg.slice());
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
