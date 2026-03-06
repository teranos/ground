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

import matcher : checkCommand, applyArg, applyOmit, checkFilePath, FileMatch, indexOf, contains, hasSegment, Buf;
import parse : extractCommand, extractCwd, extractSessionId, extractToolUseId, extractHookEventName, extractToolName, extractFilePath, extractSource, writeJsonString, fputs2;
import controls : HookEvent;
import core.stdc.stdio : stdin, stdout, stderr, fread, fputs, fprintf, fwrite;
import core.stdc.stdlib : exit;
import core.sys.posix.unistd : isatty;

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
    __gshared char[65536] buf = 0;
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

void printVersion() {
    fputs("graunde ", stderr);
    // Print version without trailing newline from git describe
    foreach (c; VERSION)
        if (c != '\n' && c != '\r') {
            char[1] buf = c;
            fwrite(&buf[0], 1, 1, stderr);
        }
}

extern (C) int main() {
    if (isatty(0)) {
        printVersion();
        fputs(" — Ground Control for Claude Code\n", stderr);
        return 0;
    }

    auto input = readStdin();
    if (input is null) {
        fputs("graunde: empty stdin\n", stderr);
        return 1;
    }

    // Common fields
    auto cwd = extractCwd(input);
    if (cwd is null) cwd = "";
    auto sessionId = extractSessionId(input);
    if (sessionId is null) sessionId = "";

    auto eventName = extractHookEventName(input);
    if (eventName is null) return 0;

    HookEvent event;
    if (!parseHookEvent(eventName, event)) return 0;

    // Attest every event — full payload, no extraction
    {
        import sqlite : openDb, attestEvent, sqlite3_close;
        auto db = openDb();
        if (db !is null) {
            attestEvent(db, eventName, cwd, sessionId, input);
            sqlite3_close(db);
        }
    }

    if (event == HookEvent.PreToolUse) {
        auto toolName = extractToolName(input);
        auto toolUseId = extractToolUseId(input);
        if (toolUseId is null) toolUseId = "unknown";

        auto command = extractCommand(input);

        if (command !is null) {
            // Bash — check controls
            auto result = checkCommand(command, cwd);

            if (result.control !is null) {
                // Msg-only control — no amendment, just decision + context
                // TODO(#3): query branch story and append to context
                if (result.control.arg.value.length == 0 && result.control.omit.value.length == 0) {
                    // Once per session: skip if already fired
                    import sqlite : openDb, attestationExists, attestEvent, sqlite3_close, ZBuf;
                    auto db = openDb();
                    if (db !is null) {
                        if (attestationExists(db, "GraundedPreToolUse", result.control.name, sessionId)) {
                            sqlite3_close(db);
                            // Still emit decision (e.g. "allow") — just skip the message
                            writeResponse(command, "", result.decision,
                                result.control.bg.value, result.control.tmo.value);
                            return 0;
                        }
                        __gshared ZBuf graundedAttrs;
                        graundedAttrs.reset();
                        graundedAttrs.put(`{"control":"`);
                        graundedAttrs.put(result.control.name);
                        graundedAttrs.put(`","decision":"`);
                        graundedAttrs.put(result.decision);
                        graundedAttrs.put(`"}`);
                        attestEvent(db, "GraundedPreToolUse", cwd, sessionId, graundedAttrs.slice());
                        sqlite3_close(db);
                    }
                    writeResponse(command, result.control.msg.value, result.decision,
                        result.control.bg.value, result.control.tmo.value);
                    return 0;
                }

                Buf amended;
                if (result.control.omit.value.length > 0)
                    amended = applyOmit(result.control, result.segment);
                else
                    amended = applyArg(result.control, result.segment);

                if (amended.slice() != result.segment) {
                    auto segIdx = indexOf(command, result.segment);
                    if (segIdx >= 0) {
                        Buf full;
                        full.put(command[0 .. cast(size_t) segIdx]);
                        full.put(amended.slice());
                        full.put(command[cast(size_t) segIdx + result.segment.length .. $]);
                        writeResponse(full.slice(), result.control.msg.value, result.decision,
                            result.control.bg.value, result.control.tmo.value);
                        return 0;
                    }
                }
                return 0;
            }

            return 0;
        }

        // Non-Bash tool (Edit/Write/Read/etc.) — check file-path controls
        // TODO(#32): updatedInput for non-Bash tools (run_in_background, timeout, new_description)
        auto filePath = extractFilePath(input);
        if (filePath !is null) {
            auto fileResult = checkFilePath(filePath, cwd);
            if (fileResult.matched) {
                writeContextResponse(fileResult.msg, fileResult.decision);
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

    // Stop — attest and check ax controls
    if (event == HookEvent.Stop) {
        import stop : handleStop;
        return handleStop(input, cwd, sessionId);
    }

    // SessionStart — emit arch context on startup/clear
    if (event == HookEvent.SessionStart) {
        auto source = extractSource(input);
        import sessionstart : handleSessionStart;
        return handleSessionStart(source, cwd);
    }

    // PostToolUse — check for CI deferral
    if (event == HookEvent.PostToolUse) {
        auto detail = extractCommand(input);
        if (detail is null) detail = extractFilePath(input);
        if (detail is null) detail = eventName;

        // After git push — defer CI check
        if (detail !is null && hasSegment(detail, "git push")) {
            import sqlite : openDb, getBranch, sqlite3_close, ZBuf;
            import deferred : writeDeferredMessage, getCIAvgDuration, computeDelay;
            auto db = openDb();
            if (db !is null) {
                auto branch = getBranch(cwd);
                if (branch !is null) {
                    auto delay = computeDelay(getCIAvgDuration(cwd, branch));
                    __gshared ZBuf msgBuf;
                    msgBuf.reset();
                    msgBuf.put("Check CI: gh run list --branch ");
                    msgBuf.put(branch);
                    msgBuf.put(" --limit 1");
                    writeDeferredMessage(db, "ci-check", cwd, sessionId, msgBuf.slice(), delay);
                }
                sqlite3_close(db);
            }
        }

        return 0;
    }

    // Unknown/unhandled events — exit 0, no output
    return 0;
}
