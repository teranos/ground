module ritual.subagent;

import ritual.position : RitualState;
import ritual.resolve : flatten;
import ritual.run : briefing;
import ritual.store : liveHere, writePosition;

// An agent started with a ritual. SubagentStart is the only place the owning
// session and the agent are both known, so it is where a performance stops
// being nobody's and becomes this session's.
int handleSubagentStart(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    import core.stdc.stdio : stdout, fputs;
    import parse : extractJsonString, writeJsonString;
    import controls : allParsed;
    import db : openDb, sqlite3_close;

    auto db = openDb();
    if (db is null) return 0;

    auto found = liveHere(db, cwd);
    if (!found.valid || found.p.state != RitualState.Live) {
        sqlite3_close(db);
        return 0;
    }

    char[128] agentBuf = 0;
    auto agentId = extractJsonString(input, `"agent_id"`, &agentBuf[0], agentBuf.length);
    if (agentId is null) agentId = "";

    auto p = found.p;
    p.session = sessionId;
    p.agent = agentId;
    writePosition(db, p);
    sqlite3_close(db);

    static immutable parsed = allParsed;
    foreach (i; 0 .. parsed.ritualCount) {
        if (parsed.rituals[i].name != p.ritual) continue;
        auto brief = briefing(p, flatten(parsed, i));
        if (brief.len == 0) break;

        fputs(`{"hookSpecificOutput":{"hookEventName":"SubagentStart","additionalContext":"`, stdout);
        writeJsonString(brief.text());
        fputs(`"}}` ~ "\n", stdout);
        return 0;
    }
    return 0;
}

// An agent stopping with rites unmet. Exit 2 refuses it, which is the only
// place a subagent can be refused — its Stop is not the session's Stop.
int handleSubagentStop(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    import core.stdc.stdio : stderr, fputs, fwrite;
    import parse : extractJsonString;
    import controls : allParsed;
    import db : openDb, sqlite3_close, ZBuf;
    import immediate : writeNote;
    import ritual.store : readPositionAt;

    auto db = openDb();
    if (db is null) return 0;

    auto found = liveHere(db, cwd);
    if (!found.valid) { sqlite3_close(db); return 0; }

    char[128] agentBuf = 0;
    auto agentId = extractJsonString(input, `"agent_id"`, &agentBuf[0], agentBuf.length);
    if (agentId is null) agentId = "";

    // Somebody else's agent stopping says nothing about this performance.
    if (found.p.agent.length > 0 && agentId != found.p.agent) {
        sqlite3_close(db);
        return 0;
    }

    // What the agent said last, kept with the performance so it can be read
    // after the agent is gone.
    __gshared char[4096] msgBuf = 0;
    auto last = extractJsonString(input, `"last_assistant_message"`,
                                  &msgBuf[0], msgBuf.length);
    if (last !is null && last.length > 0 && found.p.session.length > 0) {
        __gshared ZBuf note;
        note.reset();
        note.put("ritual ");
        note.put(found.p.ritual);
        note.put(" — the agent said: ");
        note.put(last);
        writeNote(db, found.p.session, "ritual-agent-last", note.slice());
    }

    auto state = found.p.state;
    auto ritualName = found.p.ritual;
    sqlite3_close(db);

    if (state != RitualState.Live) return 0;

    // The rites are not met and the agent is leaving. Say which one.
    static immutable parsed = allParsed;
    foreach (i; 0 .. parsed.ritualCount) {
        if (parsed.rituals[i].name != ritualName) continue;
        auto brief = briefing(found.p, flatten(parsed, i));
        if (brief.len == 0) break;
        fwrite(brief.buf.ptr, 1, brief.len, stderr);
        fputs("\n", stderr);
        return 2;
    }
    return 0;
}
