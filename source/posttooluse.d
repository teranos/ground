module posttooluse;

import matcher : hasSegment, contains, envSubst;
import hooks : Control, scopeMatches;
import parse : extractCommand, extractFilePath, extractToolName, writeJsonString;
import core.stdc.stdio : stdout, fputs, stderr;
import db : ZBuf;
import sessionmode : SessionMode;

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

// Everything before the dot. A mode with no dot is all tool letters.
const(char)[] toolSegment(const(char)[] mode) {
    foreach (i, c; mode) if (c == '.') return mode[0 .. i];
    return mode;
}

// Everything after the dot, empty when there is none.
const(char)[] sessionSegment(const(char)[] mode) {
    foreach (i, c; mode) if (c == '.') return mode[i + 1 .. $];
    return "";
}

// Checks if any tool char in the mode string matches the tool name. Reads the
// tool half alone: iterating the whole string let the `a` in acceptEdits match
// Agent, widening every session-qualified rule to a tool it never named.
bool modeMatches(const(char)[] mode, const(char)[] toolName) {
    foreach (ch; toolSegment(mode)) {
        if (modeMatchesToolName(cast(char) ch, toolName)) return true;
    }
    return false;
}

bool sessionLetterMatches(char letter, SessionMode mode) {
    import sessionmode : letterOf;
    if (mode == SessionMode.unknown) return false;
    return letter == letterOf(mode);
}

bool isSessionLetterSet(const(char)[] seg) {
    if (seg.length == 0) return false;
    foreach (c; seg) {
        if (c != 'm' && c != 'p' && c != 'a' && c != 'd' && c != 'b') return false;
    }
    return true;
}

bool sessionMatches(const(char)[] seg, SessionMode mode) {
    import sessionmode : nameOf, grants;
    if (seg.length == 0) return grants(mode);
    if (isSessionLetterSet(seg)) {
        foreach (c; seg) if (sessionLetterMatches(c, mode)) return true;
        return false;
    }
    return seg == nameOf(mode);
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
int handlePostToolUse(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    import main : usecNow;
    auto t0 = usecNow();

    // ERROR AXIOM: catch wrapper processes that died before delivering.
    // Scans this session's inflight markers; any older than
    // startTs+timeoutSec+GRACE_SEC emits exec.wrapper.vanished via
    // deliverError and unlinks the marker.
    {
        import errors : scanVanishedWrappers, writeImmediateBacklogStderr;
        scanVanishedWrappers(cast(string) sessionId);
        // Delivery-pipeline health: watch daemon dead + rows pending →
        // stderr + breadcrumb. Point-of-interaction surfacing happens at
        // Stop (see handleStop's exit) since that's where writeStopResponse
        // can prepend the warning to a Stop reason.
        writeImmediateBacklogStderr(cast(string) sessionId);
    }

    auto command = extractCommand(input);
    auto filePath = extractFilePath(input);
    auto toolName = extractToolName(input);

    // Blue is "the agent is doing something", so it is stamped where the agent
    // does something. Collet read this off the attestation table before, which
    // was accurate and cost 2s a frame against a 1s repaint.
    if (sessionId.length > 0) {
        import core.stdc.time : time;
        import db : openDb, sqlite3_close;
        import ritual : stampActed;

        auto adb = openDb();
        if (adb !is null) {
            stampActed(adb, sessionId, cast(long) time(null));
            sqlite3_close(adb);
        }
    }

    // The fallback address. PreToolUse claims the session before the row is
    // created; this catches a performance whose claim was missed and is still
    // Live, which is every case except a ritual that finished inside the call.
    if (command !is null && sessionId.length > 0) {
        import ritual : ritualStarted, readPosition, writePosition, RitualState;
        import controls : allParsed;
        import db : openDb, sqlite3_close;

        auto started = ritualStarted(command);
        if (started.length > 0) {
            static immutable parsed = allParsed;
            foreach (i; 0 .. parsed.ritualCount) {
                if (parsed.rituals[i].name != started) continue;
                auto db = openDb();
                if (db is null) break;
                auto found = readPosition(db, parsed.rituals[i].projectPath);
                if (found.valid && found.p.state == RitualState.Live
                    && found.p.parent.length == 0) {
                    found.p.parent = sessionId;
                    writePosition(db, found.p);
                }
                sqlite3_close(db);
                break;
            }
        }
    }
    auto detail = command !is null ? command : (filePath !is null ? filePath : cast(const(char)[])"PostToolUse");

    auto tParse = usecNow();

    // Exec dispatch — two safety checks alongside the control-cmd match:
    //
    //   Scope-cmd: scope-level cmd is not propagated to Control.cmd for
    //   non-strop controls (`buildScopes`), so postToolUseMatch alone
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
        // Where the command ran, not where the session sits. `cd X && git push`
        // is work done in X, and a scope naming X was skipped before this.
        import matcher : effectiveCwd;
        auto where = effectiveCwd(detail, cwd);
        foreach (ref sc; postToolUseScopes) {
            if (!scopeMatches(sc, where)) continue;
            if (sc.cmdCount > 0) {
                bool scopeCmdMatched = false;
                foreach (i; 0 .. sc.cmdCount) {
                    if (hasSegment(detail, sc.cmds[i])) { scopeCmdMatched = true; break; }
                }
                if (!scopeCmdMatched) continue;
            }
            foreach (ref c; sc.controls) {
                // A control belonging to a repo fires for every checkout of it
                // and nowhere else. Where on disk the work happened says
                // nothing; which repo it was in says everything.
                if (c.origin.length > 0) {
                    import git : originOf;
                    auto here = originOf(where);
                    if (here != c.origin) {
                        import core.stdc.stdio : fputs, stderr, fwrite;
                        fputs("ground: control ", stderr);
                        fwrite(c.name.ptr, 1, c.name.length, stderr);
                        fputs(" wants ", stderr);
                        fwrite(c.origin.ptr, 1, c.origin.length, stderr);
                        fputs(", this place is ", stderr);
                        if (here.length > 0) fwrite(here.ptr, 1, here.length, stderr);
                        else fputs("no repo", stderr);
                        fputs(" — ", stderr);
                        fwrite(where.ptr, 1, where.length, stderr);
                        fputs("\n", stderr);
                        continue;
                    }
                }
                // A control that performs a ritual. Same gate as exec, and the
                // same once-per-tool-call guard: a push is one push.
                if (c.ritual.length > 0) {
                    if (!postToolUseMatch(c, detail, filePath, toolName)) continue;
                    // A rejected push is still a PostToolUse. Performing for it
                    // deploys a commit the remote never received.
                    if (isGitPushCommand(detail)) {
                        import git : pushLanded, getBranch;
                        auto pushedBranch = getBranch(where);
                        if (!pushLanded(where, pushedBranch)) {
                            import core.stdc.stdio : fputs, stderr, fwrite;
                            fputs("ground: ", stderr);
                            fwrite(c.name.ptr, 1, c.name.length, stderr);
                            fputs(" did not perform — origin does not have ", stderr);
                            if (pushedBranch.length > 0)
                                fwrite(pushedBranch.ptr, 1, pushedBranch.length, stderr);
                            else fputs("this branch", stderr);
                            fputs(" as this tree has it: ", stderr);
                            fwrite(where.ptr, 1, where.length, stderr);
                            fputs("\n", stderr);
                            continue;
                        }
                    }
                    if (edb !is null && toolUseId.length > 0
                        && execFireExists(edb, c.name, sessionId, toolUseId))
                        continue;
                    if (edb !is null && toolUseId.length > 0)
                        attestExecFire(edb, c.name, where, sessionId, toolUseId);
                    import ritual : performFromControl;
                    cast(void) performFromControl(c.ritual, sessionId, where);
                    continue;
                }
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
                            // ciFired said the push would be reported on, so a
                            // row that never landed read as CI being watched.
                            ciFired = writeCIStatus(cdb, sessionId, info.repo,
                                                    info.branch, info.sha, ciDelay(cwd));
                            sqlite3_close(cdb);
                            if (!ciFired) {
                                import exec : emitError;
                                emitError("push.ci",
                                          "the push landed and nothing recorded that its CI is owed a result",
                                          0, 1, cast(string) sessionId, "push", "",
                                          "", cast(string) info.repo);
                            }
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
