module userprompt;

import parse : extractJsonString;
import matcher : contains;
import sqlite : ZBuf, openDb, attestationExists, attestEvent, sqlite3_close;
import core.stdc.stdio : stdout, fputs, fwrite;

const(char)[] extractPrompt(const(char)[] json) {
    __gshared char[8192] buf = 0;
    return extractJsonString(json, `"prompt"`, &buf[0], buf.length);
}

enum GRAUNDE = `Graunde — a hook that fires on every hook event, tracks what happened in this session. Can rewrite PreToolUse hooks on the fly, nudges Claude Code into the right direction; https://github.com/teranos/graunde/tree/main`;
enum AX = `AX — attestation query, a natural-language-like syntax (Tim is tester of QNTX by attestor)`;
enum QNTX = `QNTX — Continuous Intelligence. Domain-agnostic knowledge system built on verifiable attestations (who said what, when, in what context). Core: Attestation Type System (ATS). Query with AX. Graunde shares its node db; https://github.com/teranos/QNTX`;
enum TIMER = `You can set a timer on macOS. Run in background: sleep <seconds> && say "time" &`;

int handleUserPromptSubmit(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    auto prompt = extractPrompt(input);
    if (prompt is null) return 0;

    bool g = contains(prompt, "graunde") || contains(prompt, "Graunde");
    bool a = contains(prompt, " ax ") || contains(prompt, " AX ")
          || contains(prompt, " Ax ");
    bool q = (contains(prompt, "qntx") || contains(prompt, "QNTX")
          || contains(prompt, "Qntx")) && !contains(cwd, "/QNTX");
    bool t = contains(prompt, "timer for ") || contains(prompt, "Timer for ");

    if (!g && !a && !q && !t) return 0;

    // Check if already reminded in this session
    auto db = openDb();
    if (db !is null) {
        if (g && attestationExists(db, "GraundedUserPromptSubmit", "graunde-reminder", sessionId))
            g = false;
        if (a && attestationExists(db, "GraundedUserPromptSubmit", "ax-reminder", sessionId))
            a = false;
        if (q && attestationExists(db, "GraundedUserPromptSubmit", "qntx-reminder", sessionId))
            q = false;
        if (t && attestationExists(db, "GraundedUserPromptSubmit", "timer-reminder", sessionId))
            t = false;
    }

    if (!g && !a && !q && !t) {
        if (db !is null) sqlite3_close(db);
        return 0;
    }

    // Build and emit response
    __gshared ZBuf ctx;
    ctx.reset();
    if (g) ctx.put(GRAUNDE);
    if (g && (a || q || t)) ctx.put(" | ");
    if (a) ctx.put(AX);
    if (a && (q || t)) ctx.put(" | ");
    if (q) ctx.put(QNTX);
    if (q && t) ctx.put(" | ");
    if (t) ctx.put(TIMER);

    fputs(`{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"`, stdout);
    fwrite(&ctx.data[0], 1, ctx.len, stdout);
    fputs(`"}}`, stdout);
    fputs("\n", stdout);

    // Attest so we don't fire again this session
    if (db !is null) {
        if (g)
            attestEvent(db, "GraundedUserPromptSubmit", cwd, sessionId, `{"control":"graunde-reminder"}`);
        if (a)
            attestEvent(db, "GraundedUserPromptSubmit", cwd, sessionId, `{"control":"ax-reminder"}`);
        if (q)
            attestEvent(db, "GraundedUserPromptSubmit", cwd, sessionId, `{"control":"qntx-reminder"}`);
        if (t)
            attestEvent(db, "GraundedUserPromptSubmit", cwd, sessionId, `{"control":"timer-reminder"}`);
        sqlite3_close(db);
    }

    return 0;
}
