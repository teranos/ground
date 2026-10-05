module hookcost;

// What each hook cost, as one attestation, so the node has it as well as
// sentry (QNTX #1068, Phase 3).

import db : ZBuf;

enum PREDICATE = "hook:cost";

void costInto(ref ZBuf o, const(char)[] event, long us, const(char)[] project, const(char)[] phases) {
    import immediate : putJsonString;
    o.put(`{"event":"`);
    putJsonString(o, event);
    o.put(`","duration_us":`);
    o.putUint(cast(ulong)(us < 0 ? 0 : us));
    o.put(`,"project":"`);
    putJsonString(o, project);
    o.put(`","phases":"`);
    putJsonString(o, phases);
    o.put(`"}`);
}

// Beside the timing row, in the session's context. The pid tells two hooks of
// one second apart, as it does for every event row.
void attestCost(DB)(DB db, const(char)[] cwd, const(char)[] sessionId, const(char)[] event,
                    long us, const(char)[] project, const(char)[] phases) {
    import db : attestEvent;
    __gshared ZBuf body_;
    body_.reset();
    costInto(body_, event, us, project, phases);
    attestEvent(db, PREDICATE, cwd, sessionId, body_.slice(), event);
}

unittest {
    __gshared ZBuf o;
    o.reset();
    costInto(o, "PreToolUse", 4182, "teranos/ground", "parse=12us total=4182us exit=none");
    assert(o.slice() == `{"event":"PreToolUse","duration_us":4182,"project":"teranos/ground",`
        ~ `"phases":"parse=12us total=4182us exit=none"}`, o.slice());
}
