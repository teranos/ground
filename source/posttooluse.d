module posttooluse;

import matcher : hasSegment, contains, envSubst;
import hooks : Control, scopeMatches;
import parse : extractCommand, extractFilePath, extractToolName, writeJsonString;
import core.stdc.stdio : stdout, fputs, stderr;
import db : ZBuf;

void putInt(ref ZBuf buf, long v) {
    char[20] digits = 0;
    int dLen = 0;
    if (v == 0) { digits[0] = '0'; dLen = 1; }
    else { while (v > 0) { digits[dLen++] = cast(char)('0' + v % 10); v /= 10; } }
    foreach (i; 0 .. dLen) buf.putChar(digits[dLen - 1 - i]);
}

void emitProfile(ref ZBuf buf) {
    import main : setPhases;
    setPhases(buf.slice());
    fputs(buf.ptr(), stderr);
    fputs("\n", stderr);
}

// Maps a mode character to whether the given tool name matches.
// r=Read/Glob/Grep/LSP, f=WebFetch/WebSearch, w=Edit/Write/NotebookEdit, x=Bash, m=MCP, a=Agent
bool modeMatchesToolName(char mode, const(char)[] toolName) {
    if (toolName.length == 0) return false;
    switch (mode) {
        case 'r': return toolName == "Read" || toolName == "Glob" || toolName == "Grep"
                      || toolName == "LSP";
        case 'f': return toolName == "WebFetch" || toolName == "WebSearch";
        case 'w': return toolName == "Edit" || toolName == "Write" || toolName == "NotebookEdit";
        case 'x': return toolName == "Bash";
        case 'm': return toolName.length > 4 && toolName[0 .. 4] == "mcp_";
        case 'a': return toolName == "Agent";
        default: return false;
    }
}

// Checks if any mode char in the mode string matches the tool name.
bool modeMatches(const(char)[] mode, const(char)[] toolName) {
    foreach (ch; mode) {
        if (modeMatchesToolName(cast(char) ch, toolName)) return true;
    }
    return false;
}

// Does this Bash command contain a `git push` invocation? Uses hasSegment
// instead of bare substring matching so `git -C <path> push`,
// `git -c <cfg> push`, and other flag-prefixed forms are detected.
bool isGitPushCommand(const(char)[] command) {
    return hasSegment(command, "git push");
}

// Matches a PostToolUse control against a command and/or file path.
// Returns true if the control should fire.
bool postToolUseMatch(const Control c, const(char)[] command, const(char)[] filePath,
    const(char)[] toolName = null)
{
    if (c.mode.value.length > 0 && !modeMatches(c.mode.value, toolName))
        return false;
    if (c.cmd.len == 0 && c.filepath.value.length == 0)
        return true;
    if (c.cmd.len > 0 && command.length > 0) {
        foreach (ref v; c.cmd.values)
            if (hasSegment(command, v)) return true;
    }
    if (c.filepath.value.length > 0 && filePath.length > 0 && contains(filePath, c.filepath.value))
        return true;
    return false;
}

// TODO: extract `tool_response` — the actual result the tool returned (ground only reads tool_input today)
// TODO: extract `agent_id`, `agent_type` — distinguish subagent tool calls from main session
int handlePostToolUse(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    import main : usecNow;
    auto t0 = usecNow();

    auto command = extractCommand(input);
    auto filePath = extractFilePath(input);
    auto toolName = extractToolName(input);
    auto detail = command !is null ? command : (filePath !is null ? filePath : cast(const(char)[])"PostToolUse");

    auto tParse = usecNow();

    // Exec dispatch — two safety checks alongside the control-cmd match:
    //
    //   Scope-cmd: scope-level cmd is not propagated to Control.cmd for
    //   non-strop controls (proto.d:219-228), so postToolUseMatch alone
    //   would let a control with no cmd of its own fire on every tool
    //   call in the scope. Enforce sc.cmds explicitly here.
    //
    //   tool_use_id dedup: GroundedExec attestation with tool_use_id in
    //   attributes. Any repeated PostToolUse invocation for the same
    //   tool call finds the attestation and skips.
    import parse : extractToolUseId;
    auto toolUseId = extractToolUseId(input);
    {
        import controls : postToolUseScopes;
        import exec : dispatchExec;
        import db : openDb, execFireExists, attestExecFire, sqlite3_close;
        auto edb = openDb();
        foreach (ref sc; postToolUseScopes) {
            if (!scopeMatches(sc, cwd)) continue;
            if (sc.cmdCount > 0) {
                bool scopeCmdMatched = false;
                foreach (i; 0 .. sc.cmdCount) {
                    if (hasSegment(detail, sc.cmds[i])) { scopeCmdMatched = true; break; }
                }
                if (!scopeCmdMatched) continue;
            }
            foreach (ref c; sc.controls) {
                if (c.exec.length == 0) continue;
                if (!postToolUseMatch(c, detail, filePath, toolName)) continue;
                if (c.pushedPath.value.length > 0) {
                    import control_handlers : pushedFiles;
                    import push : hasPathStartingWith;
                    if (!hasPathStartingWith(pushedFiles(cwd), c.pushedPath.value))
                        continue;
                }
                if (edb !is null && toolUseId.length > 0
                    && execFireExists(edb, c.name, sessionId, toolUseId))
                    continue;
                if (edb !is null && toolUseId.length > 0)
                    attestExecFire(edb, c.name, cwd, sessionId, toolUseId);
                // Read timeout_sec from control's handler_params, if any.
                // Zero means "use dispatchExec's default (DEFAULT_TIMEOUT_SEC)".
                int timeoutSec = 0;
                foreach (i; 0 .. c.paramCount) {
                    if (c.paramKeys[i] == "timeout_sec") {
                        // parse int
                        int n = 0;
                        foreach (ch; c.paramValues[i]) {
                            if (ch < '0' || ch > '9') { n = 0; break; }
                            n = n * 10 + (ch - '0');
                        }
                        timeoutSec = n;
                        break;
                    }
                }
                dispatchExec(
                    c.exec,
                    c.name,
                    cast(string) toolUseId,
                    timeoutSec,
                    c.envKeys[0 .. c.envCount],
                    c.envValues[0 .. c.envCount],
                    cast(string) sessionId, cwd, input,
                );
            }
        }
        if (edb !is null) sqlite3_close(edb);
    }

    // Check PostToolUse controls (msg-only fire once per session)
    {
        import controls : postToolUseScopes;
        import db : openDb, attestationExists, sqlite3_close;
        auto db = openDb();
        auto tDb = usecNow();

        foreach (ref scope_; postToolUseScopes) {
            if (!scopeMatches(scope_, cwd)) continue;
            foreach (ref c; scope_.controls) {
                if (!postToolUseMatch(c, detail, filePath, toolName)) continue;
                if (c.msg.value.length == 0) continue;
                if (c.pushedPath.value.length > 0) {
                    import control_handlers : pushedFiles;
                    import push : hasPathStartingWith;
                    if (!hasPathStartingWith(pushedFiles(cwd), c.pushedPath.value))
                        continue;
                }

                if (db !is null && attestationExists(db, "GroundedPostToolUse", c.name, sessionId))
                    continue;

                {
                    import db : attestControlFire;
                    attestControlFire(db, "GroundedPostToolUse", c.name, cwd, sessionId);
                }
                if (db !is null) sqlite3_close(db);

                auto tFire = usecNow();
                __gshared ZBuf prof;
                prof.reset();
                prof.put("parse="); putInt(prof, tParse-t0);
                prof.put("us db="); putInt(prof, tDb-tParse);
                prof.put("us match+fire="); putInt(prof, tFire-tDb);
                prof.put("us total="); putInt(prof, tFire-t0);
                prof.put("us exit=control");
                emitProfile(prof);

                fputs(`{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"`, stdout);
                writeJsonString(envSubst(c.msg.value, cwd));
                fputs(`"}}`, stdout);
                fputs("\n", stdout);
                return 0;
            }
        }
        if (db !is null) sqlite3_close(db);

        auto tControls = usecNow();

        // Check deferred PostToolUse controls
        {
            import controls : postToolUseDeferredScopes;
            foreach (ref scope_; postToolUseDeferredScopes) {
                if (!scopeMatches(scope_, cwd)) continue;
                foreach (ref c; scope_.controls) {
                    if (c.cmd.len == 0) continue;
                    bool cmdFound = false;
                    foreach (ref v; c.cmd.values)
                        if (hasSegment(detail, v)) { cmdFound = true; break; }
                    if (!cmdFound) continue;
                    if (c.trigger.len > 0) {
                        bool triggerHit = false;
                        foreach (ref v; c.trigger.values)
                            if (contains(detail, v)) { triggerHit = true; break; }
                        if (!triggerHit) continue;
                    }

                    import db : openDb, sqlite3_close;
                    import deferred : writeDeferredMessage;
                    auto ddb = openDb();
                    if (ddb is null) continue;

                    auto delay = c.defer.delayFn !is null
                        ? c.defer.delayFn(cwd)
                        : c.defer.delaySec;
                    writeDeferredMessage(ddb, c.name, cwd, sessionId, c.defer.msg, delay);

                    {
                        import db : attestControlFire;
                        attestControlFire(ddb, "GroundedPostToolUseDeferred", c.name, cwd, sessionId);
                    }

                    sqlite3_close(ddb);
                }
            }
        }

        auto tDeferred = usecNow();

        // Clippy-reminder: .rs edit → write immediate, cargo clippy → delete
        bool clippyFired = false;
        {
            import control_handlers : isRustProject;
            if (isRustProject(cwd)) {
                bool isWrite = modeMatchesToolName('w', toolName);
                bool isBash = modeMatchesToolName('x', toolName);

                if (isWrite && filePath !is null && filePath.length >= 3
                    && filePath[filePath.length - 3 .. $] == ".rs")
                {
                    import db : openDb, sqlite3_close;
                    import immediate : writeClippyReminder;
                    auto cdb = openDb();
                    if (cdb !is null) {
                        writeClippyReminder(cdb, sessionId);
                        sqlite3_close(cdb);
                        clippyFired = true;
                    }
                }
                else if (isBash && detail !is null && contains(detail, "cargo clippy"))
                {
                    import db : openDb, sqlite3_close;
                    import immediate : deleteClippyReminder;
                    auto cdb = openDb();
                    if (cdb !is null) {
                        deleteClippyReminder(cdb, sessionId);
                        sqlite3_close(cdb);
                        clippyFired = true;
                    }
                }
            }
        }

        auto tClippy = usecNow();

        // CI status: git push → write session-keyed immediate:ci-status.
        // Repo + branch + sha come from the push's own stdout (tool_response),
        // not from cwd. Watcher uses these for late-binding gh queries.
        bool ciFired = false;
        {
            bool isBash = modeMatchesToolName('x', toolName);
            if (isBash && detail !is null && isGitPushCommand(detail))
            {
                import parse : extractStdout;
                import push : parsePushOutput, PushInfo;
                auto stdout = extractStdout(input);
                if (stdout !is null) {
                    auto info = parsePushOutput(stdout);
                    if (info.repo.length > 0 && info.branch.length > 0) {
                        import db : openDb, sqlite3_close;
                        import immediate : writeCIStatus;
                        import control_handlers : ciDelay;
                        auto cdb = openDb();
                        if (cdb !is null) {
                            writeCIStatus(cdb, sessionId, info.repo, info.branch, info.sha, ciDelay(cwd));
                            sqlite3_close(cdb);
                            ciFired = true;
                        }
                    }
                }
            }
        }

        auto tEnd = usecNow();
        __gshared ZBuf prof;
        prof.reset();
        prof.put("parse="); putInt(prof, tParse-t0);
        prof.put("us db="); putInt(prof, tDb-tParse);
        prof.put("us controls="); putInt(prof, tControls-tDb);
        prof.put("us deferred="); putInt(prof, tDeferred-tControls);
        prof.put("us clippy="); putInt(prof, tClippy-tDeferred);
        prof.put(clippyFired ? "us+" : "us-");
        prof.put(" ci="); putInt(prof, tEnd-tClippy);
        prof.put(ciFired ? "us+" : "us-");
        prof.put(" total="); putInt(prof, tEnd-t0);
        prof.put("us exit=none");
        emitProfile(prof);
    }

    return 0;
}
