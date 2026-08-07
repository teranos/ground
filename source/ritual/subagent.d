module ritual.subagent;

import ritual.position : RitualState;
import ritual.resolve : flatten;
import ritual.run : briefing;
import ritual.store : liveByParent, writePosition;

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

    auto found = liveByParent(db, sessionId);
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

// Refusing a subagent's stop is the whole mechanism, and the only thing that
// decides it is whether the performance is still going.
enum SubagentOutcome { Refuse, Release }

SubagentOutcome subagentOutcome(RitualState state) {
    return state == RitualState.Live ? SubagentOutcome.Refuse : SubagentOutcome.Release;
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

    auto found = liveByParent(db, sessionId);
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

    if (found.p.state != RitualState.Live) { sqlite3_close(db); return 0; }

    // The agent believes it is finished, so this is the moment to ask the
    // rite. Until now this handler re-read the briefing and never ran one.
    static immutable parsed = allParsed;
    foreach (i; 0 .. parsed.ritualCount) {
        if (parsed.rituals[i].name != found.p.ritual) continue;

        import core.stdc.time : time;
        import ritual.position : threw;
        import ritual.run : advance;
        import ritual.store : writePosition;
        import rite : Verdict;

        auto flat = flatten(parsed, i);
        auto res = advance(db, sessionId, found.p, flat, cast(long) time(null));
        if (!res.ran) break;

        auto back = res.after;
        if (res.verdict == Verdict.Hold) {
            back = threw(back);
            back.thrownAt = cast(long) time(null);
        } else {
            back.thrownAt = 0;
        }
        writePosition(db, back);

        // The two sentences, to the session watching. session_id on this hook
        // is the parent's, so there is nobody else to tell.
        if (sessionId.length > 0) {
            import notification : riteLine;
            import sentences : firstTwoSentences;

            auto line = riteLine(found.p.ritual, flat.rites[found.p.current].name,
                                 res.verdict,
                                 last is null ? "" : firstTwoSentences(last),
                                 found.p.id);
            __gshared ZBuf key;
            key.reset();
            key.put("rite:");
            key.put(found.p.id);
            key.put(":");
            key.put(flat.rites[found.p.current].name);
            writeNote(db, sessionId, key.slice(), line.text());
        }

        auto brief = briefing(back, flat);
        sqlite3_close(db);

        final switch (subagentOutcome(back.state)) {
        case SubagentOutcome.Release:
            return 0;
        case SubagentOutcome.Refuse:
            if (brief.len == 0) return 0;
            fwrite(brief.buf.ptr, 1, brief.len, stderr);
            fputs("\n", stderr);
            return 2;
        }
    }

    sqlite3_close(db);
    return 0;
}
