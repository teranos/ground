module stop;

import parse : extractBool, extractLastAssistantMessage,
               buildEventId, writeJsonString;
import sqlite : writeAttestationTo, openDb, loadAxExtension,
                getBranch, sqlite3, sqlite3_close;
import core.stdc.stdio : stdout, fputs;

void writeStopResponse(const(char)[] reason) {
    fputs(`{"continue":true,"systemMessage":"`, stdout);
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
            writeAttestationTo(db, axResult.control.name, cwd, sessionId,
                buildEventId(axResult.control.name), axResult.control.name);
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
            writeAttestationTo(db, "lazy-verify", cwd, sessionId,
                buildEventId("lazy-verify"), "lazy-verify");
            sqlite3_close(db);
            writeStopResponse("Do not ask the user to verify what you can verify yourself. Use your tools to verify as much as possible first. Only flag things that genuinely require human judgment or manual interaction.");
            return 0;
        }
    }

    // Check deferred messages — deliver if ready
    {
        import sqlite : readDeferredMessage, markDelivered, DeferredMsg, checkCIStatus, ZBuf;
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

    sqlite3_close(db);
    return 0;
}
