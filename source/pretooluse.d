module pretooluse;

import matcher : checkAllCommands, applyArg, applyOmit, indexOf, contains, hasSegment, Buf;
import parse : extractCommand, extractToolName, extractFilePath, extractToolUseId, writeJsonString, fputs2;
import core.stdc.stdio : stdout, fputs, fwrite;

// --- JSON response writers (PreToolUse format) ---

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

// --- PreToolUse handler ---

int handlePreToolUse(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
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
                        attestationExists(db, "GroundedPreToolUse", c.name, sessionId);

                    if (!alreadyFired) {
                        if (allMessages.len > 0) allMessages.put(" | ");
                        allMessages.put(c.msg.value);
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

    // Non-Bash tool — check permission deny rules (Read .env, secrets, etc.)
    auto filePath = extractFilePath(input);
    if (filePath !is null) {
        import controls : permissionScopes;
        import permission : evaluatePermission, Decision;
        auto permResult = evaluatePermission(permissionScopes, cwd, toolName, filePath);
        if (permResult.decision == Decision.deny) {
            if (permResult.name.length > 0) {
                import sqlite : openDb, sqlite3_close;
                auto pdb = openDb();
                if (pdb !is null) {
                    import sqlite : attestControlFire;
                    attestControlFire(pdb, "GroundedPermissionDeny", permResult.name, cwd, sessionId);
                    sqlite3_close(pdb);
                }
            }
            writeDenyResponse(permResult.msg);
            return 0;
        }
    }

    // File-path controls (advisory context)
    // TODO: updatedInput for non-Bash tools (run_in_background, timeout, new_description)
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
                if (db !is null && attestationExists(db, "GroundedPreToolUse", c.name, sessionId))
                    continue;

                if (fileMsgBuf.len > 0) fileMsgBuf.put(" ");
                fileMsgBuf.put(c.msg.value);

                if (sc.decision == "ask") fileDecision = "ask";
                else if (fileDecision.length == 0) fileDecision = sc.decision;

                if (db !is null) {
                    import sqlite : attestControlFire;
                    attestControlFire(db, "GroundedPreToolUse", c.name, cwd, sessionId);
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
