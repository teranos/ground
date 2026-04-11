module posttooluse;

import matcher : hasSegment, contains, envSubst;
import hooks : Control, scopeMatches;
import parse : extractCommand, extractFilePath, extractToolName, writeJsonString;
import core.stdc.stdio : stdout, fputs;

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

// Matches a PostToolUse control against a command and/or file path.
// Returns true if the control should fire.
bool postToolUseMatch(const Control c, const(char)[] command, const(char)[] filePath,
    const(char)[] toolName = null)
{
    if (c.mode.value.length > 0 && !modeMatches(c.mode.value, toolName))
        return false;
    if (c.cmd.value.length > 0 && command.length > 0 && hasSegment(command, c.cmd.value))
        return true;
    if (c.filepath.value.length > 0 && filePath.length > 0 && contains(filePath, c.filepath.value))
        return true;
    return false;
}

int handlePostToolUse(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    auto command = extractCommand(input);
    auto filePath = extractFilePath(input);
    auto toolName = extractToolName(input);
    auto detail = command !is null ? command : (filePath !is null ? filePath : cast(const(char)[])"PostToolUse");

    // Check PostToolUse controls (msg-only fire once per session)
    {
        import controls : postToolUseScopes;
        import db : openDb, attestationExists, sqlite3_close;
        auto db = openDb();

        foreach (ref scope_; postToolUseScopes) {
            if (!scopeMatches(scope_, cwd)) continue;
            foreach (ref c; scope_.controls) {
                if (!postToolUseMatch(c, detail, filePath, toolName)) continue;
                if (c.msg.value.length == 0) continue;

                if (db !is null && attestationExists(db, "GroundedPostToolUse", c.name, sessionId))
                    continue;

                {
                    import db : attestControlFire;
                    attestControlFire(db, "GroundedPostToolUse", c.name, cwd, sessionId);
                }
                if (db !is null) sqlite3_close(db);

                fputs(`{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"`, stdout);
                writeJsonString(envSubst(c.msg.value, cwd));
                fputs(`"}}`, stdout);
                fputs("\n", stdout);
                return 0;
            }
        }
        if (db !is null) sqlite3_close(db);
    }

    // Check deferred PostToolUse controls
    {
        import controls : postToolUseDeferredScopes;
        foreach (ref scope_; postToolUseDeferredScopes) {
            if (!scopeMatches(scope_, cwd)) continue;
            foreach (ref c; scope_.controls) {
                if (c.cmd.value.length == 0 || !hasSegment(detail, c.cmd.value))
                    continue;
                if (c.trigger.len > 0) {
                    bool triggerHit = false;
                    foreach (ref v; c.trigger.values)
                        if (contains(detail, v)) { triggerHit = true; break; }
                    if (!triggerHit) continue;
                }

                import db : openDb, sqlite3_close;
                import deferred : writeDeferredMessage;
                auto db = openDb();
                if (db is null) continue;

                auto delay = c.defer.delayFn !is null
                    ? c.defer.delayFn(cwd)
                    : c.defer.delaySec;
                writeDeferredMessage(db, c.name, cwd, sessionId, c.defer.msg, delay);

                {
                    import db : attestControlFire;
                    attestControlFire(db, "GroundedPostToolUseDeferred", c.name, cwd, sessionId);
                }

                sqlite3_close(db);
            }
        }
    }

    return 0;
}
