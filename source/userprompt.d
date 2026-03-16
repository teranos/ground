module userprompt;

// TODO: decision:block support — reject prompts that match certain patterns
// TODO: use permission_mode to adjust behavior (e.g. stricter in plan mode)

import parse : extractJsonString;
import matcher : containsCI;
import controls : userPromptScopes;
import sqlite : ZBuf, openDb, attestationExists, attestEvent, sqlite3_close;
import core.stdc.stdio : stdout, fputs, fwrite;

const(char)[] extractPrompt(const(char)[] json) {
    __gshared char[8192] buf = 0;
    return extractJsonString(json, `"prompt"`, &buf[0], buf.length);
}

int handleUserPromptSubmit(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    auto prompt = extractPrompt(input);
    if (prompt is null) return 0;

    auto db = openDb();

    __gshared ZBuf ctx;
    ctx.reset();
    bool any = false;

    foreach (ref sc; userPromptScopes) {
        if (sc.path.length > 0 && !containsCI(cwd, sc.path))
            continue;
        foreach (ref c; sc.controls) {
            if (c.userprompt.value.length == 0) continue;
            if (!containsCI(prompt, c.userprompt.value)) continue;

            // Once per session
            if (db !is null && attestationExists(db, "GraundedUserPromptSubmit", c.name, sessionId))
                continue;

            if (any) ctx.put(" | ");
            ctx.put(c.msg.value);
            any = true;

            if (db !is null) {
                __gshared ZBuf attrs;
                attrs.reset();
                attrs.put(`{"control":"`);
                attrs.put(c.name);
                attrs.put(`"}`);
                attestEvent(db, "GraundedUserPromptSubmit", cwd, sessionId, attrs.slice());
            }
        }
    }

    if (db !is null) sqlite3_close(db);

    if (!any) return 0;

    fputs(`{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"`, stdout);
    fwrite(&ctx.data[0], 1, ctx.len, stdout);
    fputs(`"}}`, stdout);
    fputs("\n", stdout);

    return 0;
}
