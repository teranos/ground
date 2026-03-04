module stop;

import main : extractBool, extractCommand, extractFilePath,
              extractToolUseId, buildEventId, writeJsonString;
import sqlite : writeAttestation, writeAttestationTo, openDb, loadAxExtension,
                getBranch, sqlite3, sqlite3_close;
import core.stdc.stdio : stdout, fputs;

void writeStopResponse(const(char)[] reason) {
    fputs(`{"decision":"block","reason":"`, stdout);
    writeJsonString(reason);
    fputs(`"}`, stdout);
    fputs("\n", stdout);
}

int handleStop(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    auto hookActive = extractBool(input, `"stop_hook_active"`);
    auto toolUseId = extractToolUseId(input);
    auto eventName = cast(const(char)[])"Stop";
    auto id = toolUseId !is null ? toolUseId : buildEventId(eventName);
    auto detail = extractCommand(input);
    if (detail is null) detail = extractFilePath(input);
    if (detail is null) detail = eventName;

    if (hookActive) {
        writeAttestation(eventName, cwd, sessionId, id, detail);
        return 0;
    }

    auto db = openDb();
    if (db is null) return 0;

    writeAttestationTo(db, eventName, cwd, sessionId, id, detail);

    if (loadAxExtension(db)) {
        import ax : checkAxControls;
        auto branch = getBranch(cwd);
        auto axResult = checkAxControls(branch, db);
        if (axResult.control !is null) {
            sqlite3_close(db);
            writeStopResponse(axResult.reason);
            return 0;
        }
    }

    sqlite3_close(db);
    return 0;
}
