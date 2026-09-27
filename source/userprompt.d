module userprompt;

// TODO: decision:block support — reject prompts that match certain patterns
// TODO: use permission_mode to adjust behavior (e.g. stricter in plan mode)

import parse : extractJsonString;
import matcher : contains, envSubst;
import controls : userPromptScopes;
import hooks : scopeMatches;
import db : ZBuf, openDb, attestationExists, attestEvent, sqlite3_close;
import core.stdc.stdio : stdout, fputs, fwrite;

// A path can hold a quote, and the context is a JSON string.
private void putJsonText(ref ZBuf b, const(char)[] s) {
    foreach (c; s) {
        if (c == '"') b.put(`\"`);
        else if (c == '\\') b.put(`\\`);
        else if (c >= 0x20) b.putChar(c);
    }
}

const(char)[] extractPrompt(const(char)[] json) {
    __gshared char[8192] buf = 0;
    return extractJsonString(json, `"prompt"`, &buf[0], buf.length);
}

int handleUserPromptSubmit(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    auto prompt = extractPrompt(input);
    if (prompt is null) return 0;

    auto db = openDb();

    // A message typed mid-turn fires no hook, so the transcript is the only
    // record of it. Without this the corpus holds what was submitted rather
    // than what was said.
    {
        import parse : extractTranscriptPath;
        import queued : ingestTranscript;
        auto tp = extractTranscriptPath(input);
        if (tp !is null) ingestTranscript(db, tp, sessionId, cwd);
    }

    __gshared ZBuf ctx;
    ctx.reset();
    bool any = false;

    // "it should be easy for me to switch, simply by saying the words"
    __gshared char[512] sw = 0;
    size_t swLen = 0;
    {
        import ritual : saidOf, Said, switched;
        import controls : allParsed;
        import git : repoRoot, originOf;
        import core.stdc.time : time;
        static immutable parsed = allParsed;
        auto said = saidOf(prompt);
        if (said != Said.Nothing) {
            swLen = switched(db, parsed, said, cwd, repoRoot(cwd), originOf(cwd),
                             sessionId, cast(long) time(null), sw[]);
            putJsonText(ctx, sw[0 .. swLen]);
            any = true;
            if (db !is null) {
                import fired : noteFired;
                noteFired(db, sessionId, "UserPromptSubmit", "control",
                          said == Said.On ? "rituals-on" : "rituals-off", "context", cwd);
            }
        }
    }

    foreach (ref sc; userPromptScopes) {
        if (!scopeMatches(sc, cwd))
            continue;
        foreach (ref c; sc.controls) {
            if (c.userprompt.len == 0) continue;
            bool matched = false;
            import matcher : wildcardContains;
            foreach (ref v; c.userprompt.values)
                if (wildcardContains(prompt, v)) { matched = true; break; }
            if (!matched) continue;

            // Once per session
            if (db !is null && attestationExists(db, "GroundedUserPromptSubmit", c.name, sessionId))
                continue;

            if (any) ctx.put(" | ");
            ctx.put(envSubst(c.msg.value, cwd));
            any = true;

            if (db !is null) {
                import db : attestControlFire;
                attestControlFire(db, "GroundedUserPromptSubmit", c.name, cwd, sessionId);
                import fired : noteFired;
                noteFired(db, sessionId, "UserPromptSubmit", "control", c.name, "context", cwd);
            }
        }
    }

    // Standing where a ritual performs is enough, whether the session started
    // here or walked in. Said once, so a turn spent here costs nothing after.
    {
        import playbill : unsaidBillInto;
        __gshared char[4096] bill = void;
        auto n = unsaidBillInto(db, sessionId, cwd, bill[]);
        if (n > 0) {
            if (any) ctx.put(" | ");
            ctx.put(bill[0 .. n]);
            any = true;
        }
    }

    if (db !is null) sqlite3_close(db);

    if (!any) return 0;

    fputs(`{`, stdout);
    // The switch is said to the person who said the words, not only to the model.
    if (swLen > 0) {
        import parse : writeJsonString;
        fputs(`"systemMessage":"`, stdout);
        writeJsonString(sw[0 .. swLen]);
        fputs(`",`, stdout);
    }
    fputs(`"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"`, stdout);
    fwrite(&ctx.data[0], 1, ctx.len, stdout);
    fputs(`"}}`, stdout);
    fputs("\n", stdout);

    return 0;
}
