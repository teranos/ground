module pretooluse;

import matcher : checkAllCommands, applyArg, applyOmit, applyOmitLine, applyClamp, applySubstituteForCmd, indexOf, contains, hasSegment, Buf, envSubst;
import strop : stropDispatch;
import controls : globalStropPool;
import parse : extractCommand, extractToolName, extractFilePath, extractToolUseId, writeJsonString, fputs2;
import core.stdc.stdio : stdout, fputs, fwrite, stderr, fprintf;
import db : ZBuf;

void emitProfile(ref ZBuf buf) {
    import main : setPhases;
    setPhases(buf.slice());
    fputs(buf.ptr(), stderr);
    fputs("\n", stderr);
}

void putInt(ref ZBuf buf, long v) {
    char[20] digits = 0;
    int dLen = 0;
    if (v == 0) { digits[0] = '0'; dLen = 1; }
    else { while (v > 0) { digits[dLen++] = cast(char)('0' + v % 10); v /= 10; } }
    foreach (i; 0 .. dLen) buf.putChar(digits[dLen - 1 - i]);
}

// Advisory controls inject context without overriding permission prompts.
// Only explicit "ask" or "deny" should be sent as permissionDecision.
const(char)[] advisoryDecision(const(char)[] decision) {
    if (decision == "ask" || decision == "deny") return decision;
    return "";
}

// --- JSON response writers (PreToolUse format) ---

// The rewritten tool_input for the call in flight, computed once before any
// control is asked, and the reason. Every answer the handler gives carries it:
// a permission rule that allowed a write used to answer before the rewrite was
// reached, and in auto mode that was every write.
__gshared const(char)[] pendingRewrite;
__gshared const(char)[] pendingWhy;

// Appends a JSON string with the same escaping writeJsonString prints.
private void putJsonString(ref char[] dest, ref size_t n, const(char)[] s) {
    void one(const(char)[] piece) { foreach (c; piece) if (n < dest.length) dest[n++] = c; }
    foreach (c; s) {
        switch (c) {
            case '"': one(`\"`); break;
            case '\\': one(`\\`); break;
            case '\n': one(`\n`); break;
            case '\r': one(`\r`); break;
            case '\t': one(`\t`); break;
            default: if (n < dest.length) dest[n++] = c; break;
        }
    }
}

// The PreToolUse answer, built into a buffer the caller owns so a test can
// read it. An updated input rides along whenever there is one, whatever the
// decision: the rewrite is the floor, and the floor is not conditional on
// which rule happened to speak first.
const(char)[] contextResponse(char[] dest, const(char)[] context, const(char)[] decision,
                              const(char)[] updatedInput) {
    size_t n;
    void put(const(char)[] s) { foreach (c; s) if (n < dest.length) dest[n++] = c; }
    put(`{"hookSpecificOutput":{"hookEventName":"PreToolUse"`);
    if (decision.length > 0) {
        put(`,"permissionDecision":"`);
        put(decision);
        put(`"`);
    }
    if (updatedInput.length > 0) {
        put(`,"updatedInput":`);
        put(updatedInput);
    }
    put(`,"additionalContext":"`);
    putJsonString(dest, n, context);
    put(`"}}`);
    return dest[0 .. n];
}

// Context response for non-Bash tools. Carries the pending rewrite, and says
// why beside whatever else there was to say.
void writeContextResponse(const(char)[] context, const(char)[] decision) {
    __gshared char[262144] out_ = 0;
    __gshared char[4096] said = 0;
    size_t sn;
    void say(const(char)[] s) { foreach (c; s) if (sn < said.length) said[sn++] = c; }
    say(context);
    if (pendingWhy.length > 0) {
        if (sn > 0) say(" ");
        say(pendingWhy);
    }
    // A write the floor changed is allowed as changed; a decision that was
    // only advisory does not turn into a prompt for it.
    auto verdict = decision;
    if (pendingRewrite.length > 0 && verdict.length == 0) verdict = "allow";
    auto r = contextResponse(out_[], said[0 .. sn], verdict, pendingRewrite);
    fwrite(r.ptr, 1, r.length, stdout);
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
        char[16] tbuf = 0;
        int tlen = 0;
        int t = timeout;
        if (t == 0) { tbuf[0] = '0'; tlen = 1; }
        else {
            while (t > 0 && tlen < 15) { tbuf[tlen++] = cast(char)('0' + t % 10); t /= 10; }
            foreach (i; 0 .. tlen / 2) { auto tmp = tbuf[i]; tbuf[i] = tbuf[tlen - 1 - i]; tbuf[tlen - 1 - i] = tmp; }
        }
        fwrite(&tbuf[0], 1, tlen, stdout);
    }
    fputs(`},"additionalContext":"`, stdout);
    writeJsonString(context);
    fputs(`"}}`, stdout);
    fputs("\n", stdout);
}

// updatedInput replaces the whole tool_input object, so it may only be sent to
// a tool whose entire input is the command. Monitor also carries a `command`,
// beside description/timeout_ms/persistent, and the Bash answer dropped those.
bool takesUpdatedInput(const(char)[] toolName) {
    return toolName == "Bash";
}

// The commands a gate stands in front of. Every other Bash call would pay for
// a corpus nothing is about to read.
private static immutable string[6] GATED = [
    "git commit", "git merge", "git checkout -b", "git switch -c", "gh pr", "kill",
];

// Whether this call is one whose decision depends on what the user said.
bool needsCorpus(const(char)[] toolName, const(char)[] command) {
    if (toolName == "Write" || toolName == "Edit") return true;
    if (command is null) return false;

    foreach (g; GATED)
        if (contains(command, g)) return true;

    return false;
}

// The two fields whose text lands in a file. file_path is deliberately absent,
// and so is old_string: that one selects text already on disk rather than
// authoring any, so rewriting it can only stop the edit from matching.
private static immutable string[2] WRITTEN_FIELDS = ["content", "new_string"];

struct StandingPair {
    const(char)[] pair;
    const(char)[] msg;
    bool done;
}

// A rewrite is a control, and a control fires where its scope stands. Walked by
// index so nothing has to be sized to hold the answer.
StandingPair standingRewrite(P)(const ref P parsed, const(char)[] cwd,
                               const(char)[] root, size_t want) {
    import hooks : scopeMatchesIn;

    size_t seen = 0;
    foreach (si; 0 .. parsed.scopeCount) {
        auto sc = parsed.scopes[si];
        if (!scopeMatchesIn(sc, cwd, root)) continue;
        foreach (ci; sc.controlStart .. sc.controlEnd) {
            auto c = parsed.ctrlPool[ci];
            foreach (pi; 0 .. c.rewriteCount) {
                if (seen == want) return StandingPair(c.rewrites[pi], c.msg, false);
                seen++;
            }
        }
    }
    return StandingPair(null, null, true);
}

// Computes the rewritten tool_input for a Write or Edit and leaves it in
// pendingRewrite, with the reason in pendingWhy. True when something changed.
// Nothing is written here: whichever answer the handler gives carries it.
bool computeRewrite(const(char)[] input, const(char)[] toolName, const(char)[] cwd) {
    import homedir : rewriteField, isScratch, HOME_TOKEN;
    import hooks : rewriteFrom, rewriteTo;
    import controls : allParsed;
    import parse : extractToolInputRegion;
    import db : getenv;

    if (toolName != "Write" && toolName != "Edit") return false;

    // Scratch is where a fixture carrying a real path belongs, and rewriting
    // one there breaks the fixture without protecting anything.
    auto target = extractFilePath(input);
    if (isScratch(target)) return false;

    auto region = extractToolInputRegion(input);
    if (region is null) return false;

    auto h = getenv("HOME\0".ptr);
    size_t hl = 0;
    if (h !is null) while (h[hl] != 0) hl++;
    auto home = hl > 0 ? h[0 .. hl] : "";

    // Two buffers, swapped between passes, so a pass that does not fit leaves
    // the previous one intact.
    __gshared char[131072] bufA = 0;
    __gshared char[131072] bufB = 0;

    const(char)[] current = region;
    size_t found = 0;
    bool inA = true;
    const(char)[] why;

    static immutable parsed = allParsed;

    // The scope is asked about the file being changed, not about where the
    // session stands. A session in a public repo writing into a private one
    // was scrubbing the private file for being in the wrong company.
    import git : repoRoot;
    auto where = target.length > 0 ? target : cwd;
    auto root = repoRoot(where);

    for (size_t i = 0;; i++) {
        auto sp = standingRewrite(parsed, where, root, i);
        if (sp.done) break;

        auto from = rewriteFrom(sp.pair);
        auto to = rewriteTo(sp.pair);
        if (from == HOME_TOKEN) from = home;
        if (from.length == 0 || to.length == 0) continue;

        foreach (key; WRITTEN_FIELDS) {
            auto dest = inA ? bufA[] : bufB[];
            auto r = rewriteField(current, key, from, to, dest);
            // Not fitting is not a rewrite. The call goes through as
            // it arrived rather than through a value cut short.
            if (!r.fit) return false;
            if (r.found == 0) continue;
            found += r.found;
            current = dest[0 .. r.len];
            inA = !inA;
            if (why.length == 0) why = sp.msg;
        }
    }

    if (found == 0) return false;

    // current is a slice of one of the two __gshared buffers, which outlive
    // this call, so the handler reads it whenever it answers.
    pendingRewrite = current;
    pendingWhy = why;
    return true;
}

// Called only where ground would otherwise leave the decision to a human, so
// the common allow and deny paths pay nothing for it.
private bool inLivePerformance(const(char)[] cwd) {
    import ritual : performanceAnswers, readPositionAt;
    import db : openDb, sqlite3_close;
    auto pdb = openDb();
    if (pdb is null) return false;
    auto perf = readPositionAt(pdb, cwd);
    sqlite3_close(pdb);
    return performanceAnswers(perf.valid, perf.p.state);
}

// --- PreToolUse handler ---

int handlePreToolUse(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    import main : usecNow;
    import parse : extractPermissionMode;
    auto t0 = usecNow();
    long tParse, tBinary, tMatch, tDb, tPerm;

    auto toolName = extractToolName(input);
    import sessionmode : parseSessionMode;
    auto sessionMode = parseSessionMode(extractPermissionMode(input));
    auto toolUseId = extractToolUseId(input);
    if (toolUseId is null) toolUseId = "unknown";

    // The floor comes first. What the file will hold is decided before any
    // rule is asked, so no rule's answer can leave the original in place.
    pendingRewrite = null;
    pendingWhy = null;
    computeRewrite(input, toolName, cwd);

    auto command = extractCommand(input);

    tParse = usecNow();

    // Every check handler gets the session, not only the ones reached through a
    // Bash command. A file-path control asking which session it is in was told
    // "none", and a handler that cannot bound its query denies what it cannot check.
    {
        import control_handlers : g_sessionId, g_input;
        g_sessionId = sessionId;
        g_input = input;
    }

    // A gate reads the corpus, and a message typed mid-turn is not in it until
    // the transcript is walked.
    if (needsCorpus(toolName, command)) {
        import parse : extractTranscriptPath;
        import queued : ingestTranscript;
        import db : openDb, sqlite3_close;

        auto tp = extractTranscriptPath(input);
        if (tp !is null) {
            auto qdb = openDb();
            if (qdb !is null) {
                ingestTranscript(qdb, tp, sessionId, cwd);
                sqlite3_close(qdb);
            }
        }
    }

    if (command !is null) {

        // Who is owed the news, before there is a row to write it on. Bound
        // at PostToolUse this raced the performance: a ritual that finished
        // inside the Bash call was already Done and never got an address.
        {
            import ritual : ritualStarted;
            import ritual.intent : writeIntent;
            auto starting = ritualStarted(command);
            if (starting.length > 0) writeIntent(starting, sessionId);
        }

        // Hard deny: binary files in git add
        {
            import binary : checkGitAddForBinary;
            import controls : allScopes;
            auto binaryFile = checkGitAddForBinary(allScopes, command, cwd);
            if (binaryFile !is null) {
                import db : openDb, attestEvent, sqlite3_close;
                auto db = openDb();
                if (db !is null) {
                    __gshared ZBuf attrs;
                    attrs.reset();
                    attrs.put(`{"control":"no-binary-files","file":"`);
                    attrs.put(binaryFile);
                    attrs.put(`"}`);
                    attestEvent(db, "GroundedPreToolUse", cwd, sessionId, attrs.slice());
                    sqlite3_close(db);
                }
                __gshared ZBuf denyMsg;
                denyMsg.reset();
                denyMsg.put("Binary file detected: ");
                denyMsg.put(binaryFile);
                denyMsg.put(". Binary files must not be committed.");
                writeDenyResponse(denyMsg.slice());
                return 0;
            }
        }

        // A command that was reaching for a file gets the file. A deny takes
        // the method away and leaves the goal unmet, and an agent handed that
        // stops reading rather than reading properly.
        {
            import substitute : readTargets, handOver;
            import controls : allScopes;
            import matcher : effectiveCwd, shellHome;

            foreach (ref sc; allScopes) {
                foreach (ref ctrl; sc.controls) {
                    auto utils = ctrl.substituteForRead.values();
                    if (utils.length == 0) continue;

                    auto eff = effectiveCwd(command, cwd, shellHome());
                    auto targets = readTargets(command, utils);
                    if (targets.count == 0) continue;

                    __gshared ZBuf handed;
                    handed.reset();
                    handed.put("ground read the file for you instead of running that. ");
                    handed.put("You were reaching for a file; here it is.\n\n");

                    bool any = false;
                    foreach (i; 0 .. targets.count)
                        if (handOver(handed, targets.paths[i], eff)) any = true;
                    if (!any) continue;

                    writeDenyResponse(handed.slice());
                    return 0;
                }
            }
        }

        tBinary = usecNow();

        // Bash — check controls. checkAllCommands tracks effective
        // cwd across `cd X &&` chains (see matcher.d::extractLeadingCd).
        auto results = checkAllCommands(command, cwd);
        tMatch = usecNow();

        if (results.count > 0) {
            import db : openDb, attestationExists, attestEvent, sqlite3_close;
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

                // Strop controls: extract flag, apply matchStrop, deny on mismatch.
                // Strop supersedes all other control fields (arg/omit/msg).
                if (c.stropIdx > 0) {
                    // Copy command to a plain string for stropDispatch (takes string, not const(char)[]).
                    __gshared char[4096] cmdBuf;
                    size_t cmdLen = command.length > cmdBuf.length ? cmdBuf.length : command.length;
                    foreach (i; 0 .. cmdLen) cmdBuf[i] = command[i];
                    string cmdStr = cast(string) cmdBuf[0 .. cmdLen];
                    auto sd = stropDispatch(globalStropPool[c.stropIdx - 1], cmdStr);
                    if (sd.deny) {
                        finalDecision = "deny";
                        hasDeny = true;
                        if (allMessages.len > 0) allMessages.put(" | ");
                        allMessages.put(sd.msg);
                    }
                    continue;
                }

                // Decision: deny > ask > allow
                if (m.decision == "deny") { finalDecision = "deny"; hasDeny = true; }
                else if (m.decision == "ask" && finalDecision != "deny") finalDecision = "ask";
                else if (finalDecision.length == 0) finalDecision = m.decision;

                if (c.bg.value) hasBg = true;
                if (c.tmo.value > maxTmo) maxTmo = c.tmo.value;

                bool isMsgOnly = c.arg.value.length == 0 && c.omit.value.length == 0 && c.omitLine.value.length == 0 && c.clamp.value.length == 0 && c.substituteForCmd.value.length == 0;

                if (isMsgOnly) {
                    // Deny and ask controls always show their message — no dedup
                    bool alreadyFired = m.decision != "deny" && m.decision != "ask" && db !is null &&
                        attestationExists(db, "GroundedPreToolUse", c.name, sessionId);

                    if (!alreadyFired) {
                        if (allMessages.len > 0) allMessages.put(" | ");
                        // m.observed is set when the control's check could not
                        // evaluate its condition — deliver what it measured
                        // rather than the authored msg's asserted cause.
                        allMessages.put(m.observed !is null ? m.observed : envSubst(c.msg.value, cwd));
                        if (db !is null) {
                            __gshared ZBuf groundedAttrs;
                            groundedAttrs.reset();
                            groundedAttrs.put(`{"control":"`);
                            groundedAttrs.put(c.name);
                            groundedAttrs.put(`","decision":"`);
                            groundedAttrs.put(m.decision);
                            groundedAttrs.put(`"}`);
                            attestEvent(db, "GroundedPreToolUse", cwd, sessionId, groundedAttrs.slice());
                        }
                    }
                } else {
                    Buf amended;
                    // First, because it replaces the segment whole — anything
                    // the others would edit is gone either way.
                    if (c.substituteForCmd.value.length > 0)
                        amended = applySubstituteForCmd(c, m.segment);
                    else if (c.omitLine.value.length > 0)
                        amended = applyOmitLine(m.segment, c.omitLine.value);
                    else if (c.omit.value.length > 0)
                        amended = applyOmit(c, m.segment);
                    else if (c.clamp.value.length > 0)
                        amended = applyClamp(c.clamp.value, m.segment);
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
                        allMessages.put(envSubst(c.msg.value, cwd));
                    }
                }
            }

            if (db !is null) sqlite3_close(db);
            tDb = usecNow();

            __gshared ZBuf prof;
            prof.reset();
            prof.put("parse="); putInt(prof, tParse-t0);
            prof.put("us binary="); putInt(prof, tBinary-tParse);
            prof.put("us match="); putInt(prof, tMatch-tBinary);
            prof.put("us db="); putInt(prof, tDb-tMatch);
            prof.put("us total="); putInt(prof, tDb-t0);
            if (hasDeny) prof.put("us exit=deny");
            else prof.put("us exit=control");
            emitProfile(prof);

            if (hasDeny) {
                writeDenyResponse(allMessages.slice());
                return 0;
            }

            // "a control can't invalidate a permission"
            {
                import controls : permissionScopes;
                import permission : evaluatePermission, Decision;
                import decide : combine;
                auto pr = evaluatePermission(permissionScopes, cwd, toolName, command, sessionMode);
                if (pr.decision == Decision.deny) {
                    writeDenyResponse(pr.msg);
                    return 0;
                }
                finalDecision = combine(finalDecision, pr.decision);
            }

            // A deny is ground answering; an ask is ground handing the question
            // to someone who has walked away. The rewrites above still applied.
            if (finalDecision == "ask" && inLivePerformance(cwd)) finalDecision = "allow";

            if (takesUpdatedInput(toolName)) {
                writeResponse(finalCommand.slice(), allMessages.slice(), finalDecision,
                    hasBg, maxTmo);
                return 0;
            }

            // The rewrite cannot be delivered here, so it is said rather than
            // dropped: a silently unamended command is the failure this hook
            // exists to prevent.
            if (finalCommand.slice() != command) {
                if (allMessages.len > 0) allMessages.put(" | ");
                allMessages.put("ground would have amended this command, and ");
                allMessages.put(toolName);
                allMessages.put(" cannot take an amendment. Run it as: ");
                allMessages.put(finalCommand.slice());
            }
            writeContextResponse(allMessages.slice(), advisoryDecision(finalDecision));
            return 0;
        }

        // Bash — check permission allow/deny rules per segment
        {
            import controls : permissionScopes;
            import permission : evaluatePermission, Decision;
            import matcher : strip;

            size_t pstart = 0;
            size_t pi = 0;
            while (pi <= command.length) {
                bool pSep = (pi == command.length)
                    || command[pi] == '|' || command[pi] == ';'
                    || (pi + 1 < command.length && command[pi] == '&' && command[pi + 1] == '&');
                if (pSep) {
                    auto seg = strip(command[pstart .. pi]);
                    if (seg.length > 0) {
                        auto permResult = evaluatePermission(permissionScopes, cwd, toolName, seg, sessionMode);
                        if (permResult.decision == Decision.deny) {
                            tPerm = usecNow();
                            __gshared ZBuf prof;
                            prof.reset();
                            prof.put("parse="); putInt(prof, tParse-t0);
                            prof.put("us binary="); putInt(prof, tBinary-tParse);
                            prof.put("us match="); putInt(prof, tMatch-tBinary);
                            prof.put("us perm="); putInt(prof, tPerm-tMatch);
                            prof.put("us total="); putInt(prof, tPerm-t0);
                            prof.put("us exit=perm-deny");
                            emitProfile(prof);
                            writeDenyResponse(permResult.msg);
                            return 0;
                        }
                        if (permResult.decision == Decision.allow) {
                            tPerm = usecNow();
                            __gshared ZBuf prof;
                            prof.reset();
                            prof.put("parse="); putInt(prof, tParse-t0);
                            prof.put("us binary="); putInt(prof, tBinary-tParse);
                            prof.put("us match="); putInt(prof, tMatch-tBinary);
                            prof.put("us perm="); putInt(prof, tPerm-tMatch);
                            prof.put("us total="); putInt(prof, tPerm-t0);
                            prof.put("us exit=perm-allow");
                            emitProfile(prof);
                            if (takesUpdatedInput(toolName)) writeResponse(command, "", "allow");
                            else writeContextResponse("", "allow");
                            return 0;
                        }
                    }
                    if (pi == command.length) break;
                    if (command[pi] == '&') pi += 2;
                    else pi++;
                    pstart = pi;
                    continue;
                }
                pi++;
            }
        }

        tPerm = usecNow();
        {
            __gshared ZBuf prof;
            prof.reset();
            prof.put("parse="); putInt(prof, tParse-t0);
            prof.put("us binary="); putInt(prof, tBinary-tParse);
            prof.put("us match="); putInt(prof, tMatch-tBinary);
            prof.put("us perm="); putInt(prof, tPerm-tMatch);
            prof.put("us total="); putInt(prof, tPerm-t0);
            prof.put("us exit=bash-none");
            emitProfile(prof);
        }

        // Saying nothing is what let Claude Code ask. Inside a performance
        // there is nobody to ask, so ground answers instead.
        if (inLivePerformance(cwd)) {
            if (takesUpdatedInput(toolName)) writeResponse(command, "", "allow");
            else writeContextResponse("", "allow");
        }
        return 0;
    }

    // Non-Bash tool — check permission deny rules (Read .env, secrets, etc.)
    auto filePath = extractFilePath(input);
    if (filePath !is null) {
        import controls : permissionScopes;
        import permission : evaluatePermission, Decision;
        auto permResult = evaluatePermission(permissionScopes, cwd, toolName, filePath, sessionMode);
        if (permResult.decision == Decision.deny) {
            if (permResult.name.length > 0) {
                import db : openDb, sqlite3_close;
                auto pdb = openDb();
                if (pdb !is null) {
                    import db : attestControlFire;
                    attestControlFire(pdb, "GroundedPermissionDeny", permResult.name, cwd, sessionId);
                    sqlite3_close(pdb);
                }
            }
            writeDenyResponse(permResult.msg);
            return 0;
        }

        // An allow was computed here and thrown away, so a write rule could
        // deny and never permit. Which meant where a session launched decided
        // whether an edit asked, and no rule could say otherwise.
        if (permResult.decision == Decision.allow) {
            writeContextResponse("", "allow");
            return 0;
        }
    }

    // MCP tool controls — scope-level mcp_tool + control-level mcp_arg matching
    if (toolName.length > 4 && toolName[0 .. 4] == "mcp_") {
        import controls : allScopes;
        import hooks : scopeMatches;
        import parse : extractToolInputRegion;
        import db : openDb, attestationExists, attestEvent, sqlite3_close;

        auto db = openDb();
        __gshared Buf mcpMsgBuf;
        mcpMsgBuf = Buf.init;

        foreach (ref sc; allScopes) {
            if (sc.mcpTool.length == 0) continue;
            if (!scopeMatches(sc, cwd)) continue;
            // Check tool name ends with __<mcpTool>
            if (toolName.length < sc.mcpTool.length + 2) continue;
            auto suffix = toolName[toolName.length - sc.mcpTool.length .. $];
            if (suffix != sc.mcpTool) continue;
            if (toolName[toolName.length - sc.mcpTool.length - 2 .. toolName.length - sc.mcpTool.length] != "__") continue;

            const(char)[] toolInput;
            foreach (ref c; sc.controls) {
                if (c.mcpArg.value.length > 0) {
                    if (toolInput is null) toolInput = extractToolInputRegion(input);
                    if (toolInput is null) continue;
                    if (!contains(toolInput, c.mcpArg.value)) continue;
                }
                if (c.msg.value.length == 0) continue;
                if (db !is null && attestationExists(db, "GroundedPreToolUse", c.name, sessionId))
                    continue;

                if (mcpMsgBuf.len > 0) mcpMsgBuf.put(" | ");
                mcpMsgBuf.put(envSubst(c.msg.value, cwd));

                if (db !is null) {
                    import db : attestControlFire;
                    attestControlFire(db, "GroundedPreToolUse", c.name, cwd, sessionId);
                }
            }
        }

        if (db !is null) sqlite3_close(db);

        if (mcpMsgBuf.len > 0) {
            writeContextResponse(mcpMsgBuf.slice(), "");
            return 0;
        }
    }

    // File-path and content controls (advisory context)
    {
        import controls : allScopes;
        import hooks : scopeMatches;
        import db : openDb, attestationExists, attestEvent, sqlite3_close;
        import parse : extractToolInputRegion;

        auto db = openDb();
        __gshared Buf fileMsgBuf;
        fileMsgBuf = Buf.init;
        const(char)[] fileDecision;

        // Lazy-extract tool_input region for content matching
        const(char)[] toolInput;
        bool toolInputExtracted = false;

        foreach (ref sc; allScopes) {
            if (!scopeMatches(sc, cwd)) continue;
            if (sc.cmdCount > 0) continue; // scope-level cmd scopes only apply to Bash commands
            foreach (ref c; sc.controls) {
                if (c.cmd.len > 0) continue; // command controls handled above

                // Set when a check could not evaluate its condition; replaces the
                // authored msg so the user reads what was measured, not a guess.
                const(char)[] checkObserved = null;

                // Comment-run match — same tool_input region as content, but
                // counting consecutive comment lines rather than looking for
                // a substring. Reports the count it measured, so the message
                // states the observation instead of asserting a cause.
                if (c.commentRun > 0) {
                    // The field value, not the tool_input region — in the raw
                    // region the first comment line is glued to `"content":"`
                    // and never reads as one, so a run of four counts as three.
                    import parse : extractWrittenText;
                    import matcher : maxCommentRun;
                    auto written = extractWrittenText(input);
                    if (written is null) continue;
                    auto run = maxCommentRun(written);
                    if (run < c.commentRun) continue;

                    char[8] digits = 0;
                    int dLen = 0;
                    int v = run;
                    while (v > 0 && dLen < 8) { digits[dLen++] = cast(char)('0' + v % 10); v /= 10; }

                    __gshared Buf runBuf;
                    runBuf = Buf.init;
                    runBuf.put(envSubst(c.msg.value, cwd));
                    runBuf.put(" — measured ");
                    foreach_reverse (d; 0 .. dLen) runBuf.put(digits[d .. d + 1]);
                    runBuf.put(" consecutive comment lines.");
                    checkObserved = runBuf.slice();
                }
                // Content match — check tool_input region (covers Edit new_string, Write content)
                else if (c.content.len > 0) {
                    if (!toolInputExtracted) {
                        toolInput = extractToolInputRegion(input);
                        toolInputExtracted = true;
                    }
                    if (toolInput is null) continue;
                    bool anyMatch = false;
                    foreach (v; c.content.values) {
                        if (contains(toolInput, v)) { anyMatch = true; break; }
                    }
                    if (!anyMatch) continue;
                } else {
                    // File-path / check_handler controls
                    if (c.filepath.value.length == 0 && c.sessionstart.check is null) continue;
                    if (c.filepath.value.length > 0 && (filePath is null || !contains(filePath, c.filepath.value))) continue;
                    if (c.sessionstart.check !is null) {
                        import control_handlers : g_paramKeys, g_paramValues, g_paramCount;
                        g_paramKeys = c.paramKeys;
                        g_paramValues = c.paramValues;
                        g_paramCount = c.paramCount;
                        auto verdict = c.sessionstart.check(cwd, input);
                        if (!verdict.fired) continue;
                        // Truthfulness clause: the handler could not evaluate its
                        // condition, so the authored msg would assert a cause it
                        // never measured. Deliver the observation instead.
                        checkObserved = verdict.observed;
                    }
                }

                // Fire once per session, so advice does not nag. A denial is
                // not advice: dedup here means the second attempt succeeds,
                // and a gate that opens after one refusal is not a gate.
                if (sc.decision != "deny"
                    && db !is null
                    && attestationExists(db, "GroundedPreToolUse", c.name, sessionId))
                    continue;

                if (fileMsgBuf.len > 0) fileMsgBuf.put(" ");
                fileMsgBuf.put(checkObserved !is null ? checkObserved : envSubst(c.msg.value, cwd));

                if (sc.decision == "ask") fileDecision = "ask";
                else if (sc.decision == "deny") fileDecision = "deny";
                else if (fileDecision.length == 0) fileDecision = sc.decision;

                if (db !is null) {
                    import db : attestControlFire;
                    attestControlFire(db, "GroundedPreToolUse", c.name, cwd, sessionId);
                }
            }
        }

        if (db !is null) sqlite3_close(db);

        if (fileMsgBuf.len > 0) {
            writeContextResponse(fileMsgBuf.slice(), advisoryDecision(fileDecision));
            return 0;
        }
    }

    // Nothing else spoke. A pending rewrite is the whole answer; file_path is
    // left alone, since rewriting that sends the write to a path that does
    // not exist.
    if (pendingRewrite.length > 0) {
        writeContextResponse("", "allow");
        return 0;
    }

    // Every non-Bash tool lands here — a Write among them, which is what a
    // performance with nobody at its session gets stopped on.
    if (inLivePerformance(cwd)) {
        writeContextResponse("allowed by the live performance", "allow");
        return 0;
    }

    auto tEnd = usecNow();
    {
        __gshared ZBuf prof;
        prof.reset();
        prof.put("parse="); putInt(prof, tParse-t0);
        prof.put("us total="); putInt(prof, tEnd-t0);
        prof.put("us exit=none");
        emitProfile(prof);
    }
    return 0;
}
