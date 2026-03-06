module stop;

import parse : extractBool, extractLastAssistantMessage, writeJsonString;
import sqlite : openDb, loadAxExtension, attestEvent,
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

    if (loadAxExtension(db)) {
        import ax : checkAxControls;
        auto branch = getBranch(cwd);
        auto axResult = checkAxControls(branch, db);
        if (axResult.control !is null) {
            __gshared ZBuf graundedAttrs;
            graundedAttrs.reset();
            graundedAttrs.put(`{"control":"`);
            graundedAttrs.put(axResult.control.name);
            graundedAttrs.put(`"}`);
            attestEvent(db, "GraundedStop", cwd, sessionId, graundedAttrs.slice());
            sqlite3_close(db);
            writeStopResponse(axResult.reason);
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

    // Check session-scoped deferred messages — deliver if ready
    {
        import deferred : readDeferredMessage, markDelivered, DeferredMsg, checkCIStatus;
        import matcher : contains;
        auto deferred = readDeferredMessage(db, sessionId);
        if (deferred.message !is null) {
            markDelivered(db, deferred.name, cwd, sessionId);

            // ci-check: query live status instead of emitting static message
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

    sqlite3_close(db);
    return 0;
}
