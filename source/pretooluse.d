module pretooluse;

import matcher : checkAllCommands, applyArg, applyOmit, indexOf, contains, hasSegment, Buf, envSubst;
import parse : extractCommand, extractToolName, extractFilePath, extractToolUseId, writeJsonString, fputs2;
import core.stdc.stdio : stdout, fputs, fwrite;

// Advisory controls inject context without overriding permission prompts.
// Only explicit "ask" or "deny" should be sent as permissionDecision.
const(char)[] advisoryDecision(const(char)[] decision) {
    if (decision == "ask" || decision == "deny") return decision;
    return "";
}

// --- JSON response writers (PreToolUse format) ---

// Context-only response for non-Bash tools (no updatedInput).
void writeContextResponse(const(char)[] context, const(char)[] decision) {
    fputs(`{"hookSpecificOutput":{"hookEventName":"PreToolUse"`, stdout);
    if (decision.length > 0) {
        fputs(`,"permissionDecision":"`, stdout);
        fputs2(decision);
        fputs(`"`, stdout);
    }
    fputs(`,"additionalContext":"`, stdout);
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

// TODO: extract `agent_id`, `agent_type` — gate subagent tool calls differently from main session
// TODO: extract `permission_mode` — adjust decisions based on current mode (plan, auto, etc.)
int handlePreToolUse(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    auto toolName = extractToolName(input);
    auto toolUseId = extractToolUseId(input);
    if (toolUseId is null) toolUseId = "unknown";

    auto command = extractCommand(input);

    if (command !is null) {
        // Make sessionId available to check handlers (e.g. commitNotRequested)
        import control_handlers : g_sessionId;
        g_sessionId = sessionId;

        // Hard deny: binary files in git add
        {
            import binary : checkGitAddForBinary;
            auto binaryFile = checkGitAddForBinary(command, cwd);
            if (binaryFile !is null) {
                import db : openDb, attestEvent, sqlite3_close, ZBuf;
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

        // Bash — check controls
        auto results = checkAllCommands(command, cwd);

        if (results.count > 0) {
            import db : openDb, attestationExists, attestEvent, sqlite3_close, ZBuf;
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
                    // Deny and ask controls always show their message — no dedup
                    bool alreadyFired = m.decision != "deny" && m.decision != "ask" && db !is null &&
                        attestationExists(db, "GroundedPreToolUse", c.name, sessionId);

                    if (!alreadyFired) {
                        if (allMessages.len > 0) allMessages.put(" | ");
                        allMessages.put(envSubst(c.msg.value, cwd));
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
                        allMessages.put(envSubst(c.msg.value, cwd));
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
                        auto permResult = evaluatePermission(permissionScopes, cwd, toolName, seg);
                        if (permResult.decision == Decision.deny) {
                            writeDenyResponse(permResult.msg);
                            return 0;
                        }
                        if (permResult.decision == Decision.allow) {
                            writeResponse(command, "", "allow");
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
    }

    // MCP tool controls — scope-level mcp_tool + control-level mcp_arg matching
    if (toolName.length > 4 && toolName[0 .. 4] == "mcp_") {
        import controls : allScopes;
        import hooks : scopeMatches;
        import parse : extractToolInputRegion;
        import db : openDb, attestationExists, attestEvent, sqlite3_close, ZBuf;

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

    // File-path controls (advisory context)
    // TODO: updatedInput for non-Bash tools (run_in_background, timeout, new_description)
    if (filePath !is null) {
        import controls : allScopes;
        import hooks : scopeMatches;
        import db : openDb, attestationExists, attestEvent, sqlite3_close, ZBuf;

        auto db = openDb();
        __gshared Buf fileMsgBuf;
        fileMsgBuf = Buf.init;
        const(char)[] fileDecision;

        foreach (ref sc; allScopes) {
            if (!scopeMatches(sc, cwd)) continue;
            foreach (ref c; sc.controls) {
                if (c.cmd.len > 0) continue; // command controls handled above
                if (c.filepath.value.length == 0 && c.sessionstart.check is null) continue;
                if (c.filepath.value.length > 0 && !contains(filePath, c.filepath.value)) continue;
                if (c.sessionstart.check !is null && !c.sessionstart.check(cwd, input)) continue;
                if (db !is null && attestationExists(db, "GroundedPreToolUse", c.name, sessionId))
                    continue;

                if (fileMsgBuf.len > 0) fileMsgBuf.put(" ");
                fileMsgBuf.put(envSubst(c.msg.value, cwd));

                if (sc.decision == "ask") fileDecision = "ask";
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
    return 0;
}
