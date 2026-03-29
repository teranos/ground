module main;

// Hook output reference — graunde responds via exit code and optional JSON on stdout.
//
// Exit codes:
//   0     — action proceeds, stdout parsed for JSON
//   2     — action blocked, stderr fed to Claude as error
//   other — non-blocking error, action proceeds
//
// Top-level response fields:
//   continue           — (Stop) true makes Claude continue instead of stopping
//   suppressOutput     — suppress hook output from display
//   decision           — "approve" or "block"
//   reason             — explanation for the decision
//   systemMessage      — injected as system message to Claude
//   permissionDecision — "allow", "deny", or "ask"
//
// hookSpecificOutput (PreToolUse, UserPromptSubmit, PostToolUse):
//   hookEventName            — must match the event
//   permissionDecision       — (PreToolUse) "allow", "deny", or "ask"
//   permissionDecisionReason — (PreToolUse) shown to user (allow/ask) or Claude (deny)
//   updatedInput             — (PreToolUse) replaces tool input before execution
//   additionalContext        — (UserPromptSubmit required, PostToolUse optional) injected into context

import matcher : checkCommand, checkAllCommands, MatchSet, applyArg, applyOmit, indexOf, contains, hasSegment, Buf;
import parse : extractCommand, extractCwd, extractSessionId, extractToolUseId, extractHookEventName, extractToolName, extractFilePath, extractSource, writeJsonString, fputs2;
import controls : HookEvent;
import core.stdc.stdio : stdin, stdout, stderr, fread, fputs, fprintf, fwrite, FILE;
import sqlite : popen, pclose;
import core.stdc.stdlib : exit;
import core.sys.posix.unistd : isatty;

extern (C) {
    struct timeval { long tv_sec; long tv_usec; }
    int gettimeofday(timeval* tv, void* tz);
}

long usecNow() {
    timeval tv;
    gettimeofday(&tv, null);
    return tv.tv_sec * 1_000_000 + tv.tv_usec;
}

// Parse hook_event_name string to HookEvent. CTFE-unrolled.
bool parseHookEvent(const(char)[] name, ref HookEvent event) {
    static foreach (member; __traits(allMembers, HookEvent)) {
        if (name == member) {
            event = __traits(getMember, HookEvent, member);
            return true;
        }
    }
    return false;
}

// Reads all of stdin into a static buffer.
// Returns the filled slice, or null on failure/empty.
const(char)[] readStdin() {
    __gshared char[262144] buf = 0; // 256KB — Edit payloads can exceed 64KB
    size_t total = 0;

    while (total < buf.length) {
        auto n = fread(&buf[total], 1, buf.length - total, stdin);
        if (n == 0) break;
        total += n;
    }

    if (total == 0) return null;
    return buf[0 .. total];
}

// Context-only response for non-Bash tools (no updatedInput).
void writeContextResponse(const(char)[] context, const(char)[] decision) {
    fputs(`{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"`, stdout);
    fputs2(decision);
    fputs(`","additionalContext":"`, stdout);
    writeJsonString(context);
    fputs(`"}}`, stdout);
    fputs("\n", stdout);
}

void writeDenyResponse(const(char)[] reason) {
    fputs(`{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"`, stdout);
    writeJsonString(reason);
    fputs(`"}}`, stdout);
    fputs("\n", stdout);
}

void writeResponse(const(char)[] command, const(char)[] context, const(char)[] decision,
    bool background = false, int timeout = 0)
{
    fputs(`{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"`, stdout);
    fputs2(decision);
    fputs(`","updatedInput":{"command":"`, stdout);
    writeJsonString(command);
    fputs(`"`, stdout);
    if (background)
        fputs(`,"run_in_background":true`, stdout);
    if (timeout > 0) {
        fputs(`,"timeout":`, stdout);
        // Write int as decimal
        char[16] tbuf = 0;
        int tlen = 0;
        int t = timeout;
        if (t == 0) { tbuf[0] = '0'; tlen = 1; }
        else {
            while (t > 0 && tlen < 15) { tbuf[tlen++] = cast(char)('0' + t % 10); t /= 10; }
            // Reverse
            foreach (i; 0 .. tlen / 2) { auto tmp = tbuf[i]; tbuf[i] = tbuf[tlen - 1 - i]; tbuf[tlen - 1 - i] = tmp; }
        }
        fwrite(&tbuf[0], 1, tlen, stdout);
    }
    fputs(`},"additionalContext":"`, stdout);
    writeJsonString(context);
    fputs(`"}}`, stdout);
    fputs("\n", stdout);
}

enum VERSION = import(".version");
enum BUILDDATE = import(".builddate");

void printVersion() {
    fputs("graunde ", stderr);
    foreach (c; VERSION)
        if (c != '\n' && c != '\r') {
            char[1] buf = c;
            fwrite(&buf[0], 1, 1, stderr);
        }
    fputs(" built ", stderr);
    foreach (c; BUILDDATE)
        if (c != '\n' && c != '\r') {
            char[1] buf = c;
            fwrite(&buf[0], 1, 1, stderr);
        }
}

void printDuration(long t0) {
    auto elapsed = usecNow() - t0;
    auto ms = elapsed / 1000;
    auto us = elapsed % 1000;
    // Write "graunde: XXms" to stderr
    char[32] buf = 0;
    int pos = 0;
    // ms part
    if (ms == 0) { buf[pos++] = '0'; }
    else {
        char[10] digits = 0;
        int dLen = 0;
        auto v = ms;
        while (v > 0) { digits[dLen++] = cast(char)('0' + v % 10); v /= 10; }
        foreach (i; 0 .. dLen) buf[pos++] = digits[dLen - 1 - i];
    }
    buf[pos++] = '.';
    // us part — zero-padded to 3 digits
    buf[pos++] = cast(char)('0' + us / 100);
    buf[pos++] = cast(char)('0' + (us / 10) % 10);
    buf[pos++] = cast(char)('0' + us % 10);
    buf[pos++] = 'm';
    buf[pos++] = 's';
    fputs("graunde: ", stderr);
    fwrite(&buf[0], 1, pos, stderr);
    fputs("\n", stderr);
}

void recordTiming(long elapsedUs, const(char)[] hookEvent, const(char)[] project) {
    import sqlite : openDb, sqlite3_exec, sqlite3_prepare_v2, sqlite3_bind_int64,
                    sqlite3_bind_text, sqlite3_step, sqlite3_finalize, sqlite3_close,
                    sqlite3_stmt, SQLITE_OK, SQLITE_TRANSIENT;

    auto db = openDb();
    if (db is null) return;

    enum createSql = "CREATE TABLE IF NOT EXISTS timing (id INTEGER PRIMARY KEY, duration_us INTEGER NOT NULL, hook_event TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)\0";
    sqlite3_exec(db, createSql.ptr, null, null, null);

    // Migrate: add hook_event column if missing
    enum migrateSql = "ALTER TABLE timing ADD COLUMN hook_event TEXT\0";
    sqlite3_exec(db, migrateSql.ptr, null, null, null);

    // Migrate: add project column for per-project timing
    enum migrateProject = "ALTER TABLE timing ADD COLUMN project TEXT\0";
    sqlite3_exec(db, migrateProject.ptr, null, null, null);

    enum idxTiming = "CREATE INDEX IF NOT EXISTS idx_timing_event_project ON timing(hook_event, project, id)\0";
    sqlite3_exec(db, idxTiming.ptr, null, null, null);

    enum sql = "INSERT INTO timing (duration_us, hook_event, project) VALUES (?1, ?2, ?3)\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK) {
        sqlite3_bind_int64(stmt, 1, elapsedUs);
        if (hookEvent.length > 0)
            sqlite3_bind_text(stmt, 2, hookEvent.ptr, cast(int) hookEvent.length, SQLITE_TRANSIENT);
        if (project.length > 0)
            sqlite3_bind_text(stmt, 3, project.ptr, cast(int) project.length, SQLITE_TRANSIENT);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
}

extern (C) int main() {
    if (isatty(0)) {
        printVersion();
        fputs(" — Ground Control for Claude Code\n", stderr);
        return 0;
    }

    auto t0 = usecNow();
    const(char)[] eventName;
    const(char)[] project;
    bool skipTiming;
    auto rc = run(eventName, project, skipTiming);
    auto elapsed = usecNow() - t0;
    printDuration(t0);
    if (!skipTiming)
        recordTiming(elapsed, eventName, project);
    return rc;
}

int run(ref const(char)[] outEventName, ref const(char)[] outProject, ref bool outSkipTiming) {

    auto r0 = usecNow();
    auto input = readStdin();
    if (input is null) {
        fputs("graunde: empty stdin\n", stderr);
        return 1;
    }
    auto r1 = usecNow();

    // Common fields
    auto cwd = extractCwd(input);
    if (cwd is null) cwd = "";
    auto sessionId = extractSessionId(input);
    if (sessionId is null) sessionId = "";

    import sqlite : cwdTail;
    outProject = cwdTail(cwd);

    auto eventName = extractHookEventName(input);
    if (eventName is null) return 0;
    outEventName = eventName;

    auto r2 = usecNow();

    // Attest every event — even ones we don't handle yet
    {
        import sqlite : openDb, attestEvent, sqlite3_close;
        auto db = openDb();
        if (db !is null) {
            attestEvent(db, eventName, cwd, sessionId, input);
            sqlite3_close(db);
        }
    }

    auto r3 = usecNow();

    HookEvent event;
    if (!parseHookEvent(eventName, event)) return 0;

    if (event == HookEvent.PreToolUse) {
        auto toolName = extractToolName(input);
        auto toolUseId = extractToolUseId(input);
        if (toolUseId is null) toolUseId = "unknown";

        auto command = extractCommand(input);

        if (command !is null) {
            // Bash — check controls
            auto results = checkAllCommands(command, cwd);

            if (results.count > 0) {
                import sqlite : openDb, attestationExists, attestEvent, sqlite3_close, ZBuf;
                auto db = openDb();

                const(char)[] finalDecision;
                __gshared ZBuf allMessages;
                allMessages.reset();
                __gshared Buf finalCommand;
                finalCommand = Buf.init;
                finalCommand.put(command);
                bool hasBg = false;
                int maxTmo = 0;
                bool hasDeny = false;

                foreach (idx; 0 .. results.count) {
                    auto m = results.matches[idx];
                    auto c = m.control;

                    // Decision: deny > ask > allow
                    if (m.decision == "deny") { finalDecision = "deny"; hasDeny = true; }
                    else if (m.decision == "ask" && finalDecision != "deny") finalDecision = "ask";
                    else if (finalDecision.length == 0) finalDecision = m.decision;

                    if (c.bg.value) hasBg = true;
                    if (c.tmo.value > maxTmo) maxTmo = c.tmo.value;

                    bool isMsgOnly = c.arg.value.length == 0 && c.omit.value.length == 0;

                    if (isMsgOnly) {
                        bool alreadyFired = db !is null &&
                            attestationExists(db, "GraundedPreToolUse", c.name, sessionId);

                        if (!alreadyFired) {
                            if (allMessages.len > 0) allMessages.put(" | ");
                            allMessages.put(c.msg.value);
                            if (db !is null) {
                                __gshared ZBuf graundedAttrs;
                                graundedAttrs.reset();
                                graundedAttrs.put(`{"control":"`);
                                graundedAttrs.put(c.name);
                                graundedAttrs.put(`","decision":"`);
                                graundedAttrs.put(m.decision);
                                graundedAttrs.put(`"}`);
                                attestEvent(db, "GraundedPreToolUse", cwd, sessionId, graundedAttrs.slice());
                            }
                        }
                    } else {
                        Buf amended;
                        if (c.omit.value.length > 0)
                            amended = applyOmit(c, m.segment);
                        else
                            amended = applyArg(c, m.segment);

                        if (amended.slice() != m.segment) {
                            auto current = finalCommand.slice();
                            auto segIdx = indexOf(current, m.segment);
                            if (segIdx >= 0) {
                                Buf updated;
                                updated.put(current[0 .. cast(size_t) segIdx]);
                                updated.put(amended.slice());
                                updated.put(current[cast(size_t) segIdx + m.segment.length .. $]);
                                finalCommand = updated;
                            }
                        }

                        if (c.msg.value.length > 0) {
                            if (allMessages.len > 0) allMessages.put(" | ");
                            allMessages.put(c.msg.value);
                        }
                    }
                }

                if (db !is null) sqlite3_close(db);

                if (hasDeny) {
                    writeDenyResponse(allMessages.slice());
                    return 0;
                }

                writeResponse(finalCommand.slice(), allMessages.slice(), finalDecision,
                    hasBg, maxTmo);
                return 0;
            }

            return 0;
        }

        // Non-Bash tool (Edit/Write/Read/etc.) — check file-path controls
        // TODO: updatedInput for non-Bash tools (run_in_background, timeout, new_description)
        auto filePath = extractFilePath(input);
        if (filePath !is null) {
            import controls : fileScopes;
            import hooks : scopeMatches;
            import sqlite : openDb, attestationExists, attestEvent, sqlite3_close, ZBuf;

            auto db = openDb();
            __gshared Buf fileMsgBuf;
            fileMsgBuf = Buf.init;
            const(char)[] fileDecision;

            foreach (ref sc; fileScopes) {
                if (!scopeMatches(sc.path, cwd)) continue;
                foreach (ref c; sc.controls) {
                    if (c.filepath.value.length == 0) continue;
                    if (!contains(filePath, c.filepath.value)) continue;
                    if (db !is null && attestationExists(db, "GraundedPreToolUse", c.name, sessionId))
                        continue;

                    if (fileMsgBuf.len > 0) fileMsgBuf.put(" ");
                    fileMsgBuf.put(c.msg.value);

                    if (sc.decision == "ask") fileDecision = "ask";
                    else if (fileDecision.length == 0) fileDecision = sc.decision;

                    if (db !is null) {
                        import sqlite : attestControlFire;
                        attestControlFire(db, "GraundedPreToolUse", c.name, cwd, sessionId);
                    }
                }
            }

            if (db !is null) sqlite3_close(db);

            if (fileMsgBuf.len > 0) {
                writeContextResponse(fileMsgBuf.slice(), fileDecision);
                return 0;
            }
        }
        return 0;
    }

    // UserPromptSubmit — keyword controls
    if (event == HookEvent.UserPromptSubmit) {
        import userprompt : handleUserPromptSubmit;
        return handleUserPromptSubmit(input, cwd, sessionId);
    }

    // Stop — trail controls, deferred messages, lazy-verify
    if (event == HookEvent.Stop) {
        import stop : handleStop;
        auto stopRc = handleStop(input, cwd, sessionId);
        auto r4 = usecNow();
        fprintf(stderr, "MAIN-PROFILE stdin=%ldus parse=%ldus attest=%ldus stop=%ldus\n".ptr,
            r1-r0, r2-r1, r3-r2, r4-r3);
        if (stopRc == 2) { outSkipTiming = true; return 0; }
        return stopRc;
    }

    // SessionStart — emit arch context on startup/clear
    if (event == HookEvent.SessionStart) {
        auto source = extractSource(input);
        import sessionstart : handleSessionStart;
        return handleSessionStart(source, cwd, sessionId);
    }

    // PreCompact — re-inject context that would be lost to compaction
    if (event == HookEvent.PreCompact) {
        import matcher : contains;
        import controls : preCompactScopes;
        bool first = true;

        fputs(`{"systemMessage":"`, stdout);

        foreach (ref scope_; preCompactScopes) {
            if (scope_.path.length > 0 && (cwd is null || !contains(cwd, scope_.path)))
                continue;
            foreach (ref c; scope_.controls) {
                if (!first) fputs(" | ", stdout);
                first = false;

                if (c.msg.value.length > 0)
                    fputs2(c.msg.value);

                if (c.cmd.value.length > 0) {
                    // Run cmd, append stdout (stripped of trailing newline)
                    __gshared char[4096] cmdBuf = 0;
                    __gshared char[1024] outBuf = 0;
                    if (c.cmd.value.length < cmdBuf.length) {
                        foreach (i, ch; c.cmd.value) cmdBuf[i] = ch;
                        cmdBuf[c.cmd.value.length] = 0;
                        auto pipe = popen(&cmdBuf[0], "r");
                        if (pipe !is null) {
                            auto n = fread(&outBuf[0], 1, outBuf.length, pipe);
                            pclose(pipe);
                            // Strip trailing newlines
                            while (n > 0 && (outBuf[n-1] == '\n' || outBuf[n-1] == '\r')) n--;
                            if (n > 0) fwrite(&outBuf[0], 1, n, stdout);
                        }
                    }
                }

                // Attest the fire
                {
                    import sqlite : attestControlFire;
                    attestControlFire(null, "GraundedPreCompact", c.name, cwd, sessionId);
                }
            }
        }

        fputs(`"}`, stdout);
        fputs("\n", stdout);

        // Checkpoint WAL so the next Stop doesn't pay for our writes
        {
            import sqlite : openDb, walCheckpoint, sqlite3_close;
            auto cpDb = openDb();
            if (cpDb !is null) {
                walCheckpoint(cpDb);
                sqlite3_close(cpDb);
            }
        }

        return 0;
    }

    // PostToolUse — controls + CI deferral
    if (event == HookEvent.PostToolUse) {
        auto detail = extractCommand(input);
        if (detail is null) detail = extractFilePath(input);
        if (detail is null) detail = eventName;

        // Check PostToolUse controls
        if (detail !is null) {
            import controls : postToolUseScopes;
            foreach (ref scope_; postToolUseScopes) {
                if (scope_.path.length > 0 && (cwd is null || !contains(cwd, scope_.path)))
                    continue;
                foreach (ref c; scope_.controls) {
                    if (c.cmd.value.length > 0 && hasSegment(detail, c.cmd.value) && c.msg.value.length > 0) {
                        // Attest the fire
                        {
                            import sqlite : attestControlFire;
                            attestControlFire(null, "GraundedPostToolUse", c.name, cwd, sessionId);
                        }
                        fputs(`{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"`, stdout);
                        import parse : writeJsonString;
                        writeJsonString(c.msg.value);
                        fputs(`"}}`, stdout);
                        fputs("\n", stdout);
                        return 0;
                    }
                }
            }
        }

        // Check deferred PostToolUse controls
        if (detail !is null) {
            import controls : postToolUseDeferredScopes;
            import hooks : scopeMatches;
            foreach (ref scope_; postToolUseDeferredScopes) {
                if (!scopeMatches(scope_.path, cwd))
                    continue;
                foreach (ref c; scope_.controls) {
                    if (c.cmd.value.length == 0 || !hasSegment(detail, c.cmd.value))
                        continue;
                    // Secondary trigger pattern (if set, must also match)
                    if (c.trigger.len > 0) {
                        bool triggerHit = false;
                        foreach (ref v; c.trigger.values)
                            if (contains(detail, v)) { triggerHit = true; break; }
                        if (!triggerHit) continue;
                    }

                    import sqlite : openDb, attestEvent, sqlite3_close, ZBuf;
                    import deferred : writeDeferredMessage;
                    auto db = openDb();
                    if (db is null) continue;

                    auto delay = c.defer.delayFn !is null
                        ? c.defer.delayFn(cwd)
                        : c.defer.delaySec;
                    writeDeferredMessage(db, c.name, cwd, sessionId, c.defer.msg, delay);

                    // Attest the fire
                    {
                        import sqlite : attestControlFire;
                        attestControlFire(db, "GraundedPostToolUseDeferred", c.name, cwd, sessionId);
                    }

                    sqlite3_close(db);
                }
            }
        }

        return 0;
    }

    // PostToolUseFailure — control-driven hints on failure
    if (event == HookEvent.PostToolUseFailure) {
        import parse : extractError;
        import controls : postToolUseFailureScopes;
        import hooks : scopeMatches;
        auto error = extractError(input);
        if (error !is null) {
            foreach (ref scope_; postToolUseFailureScopes) {
                if (!scopeMatches(scope_.path, cwd))
                    continue;
                foreach (ref c; scope_.controls) {
                    if (c.trigger.len == 0) continue;
                    bool matched = false;
                    foreach (ref v; c.trigger.values)
                        if (contains(error, v)) { matched = true; break; }
                    if (!matched) continue;

                    // Attest the fire
                    {
                        import sqlite : attestControlFire;
                        attestControlFire(null, "GraundedPostToolUseFailure", c.name, cwd, sessionId);
                    }
                    fputs(`{"systemMessage":"`, stdout);
                    fputs2(c.msg.value);
                    fputs(`"}`, stdout);
                    fputs("\n", stdout);
                    return 0;
                }
            }
        }
        return 0;
    }

    // Unknown/unhandled events — exit 0, no output
    return 0;
}
