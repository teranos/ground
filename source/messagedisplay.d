module messagedisplay;

// "i need to see it in the transcript without me having to press ctrl-o"
// "i want MessageDisplay and displayContent"
// https://code.claude.com/docs/en/hooks — MessageDisplay, displayContent

import db : openDb, sqlite3_close, ZBuf;
import immediate : readImmediateMessage, markImmediateDelivered;
import parse : extractJsonString, writeJsonString;
import core.stdc.stdio : stdout, fputs;

enum SCREEN_MARK = "screen:";

bool firstChunk(const(char)[] input) {
    import matcher : contains;
    return contains(input, `"index":0`);
}

// "it looks the same as your text, its as if you said it, but its coming from
// a rite of a ritual no?"
// "  ░░▒▓▏ritual" / "    ░░▏rite"
enum RITE_GUTTER   = "  ░░▏";
enum RITUAL_GUTTER = "░░▒▓▏";

const(char)[] gutterFor(const(char)[] msgId) {
    import matcher : contains;
    return contains(msgId, ":rite:") ? RITE_GUTTER : RITUAL_GUTTER;
}

// "░▏Could not do shit bro."
// "░▏Just didnt have the perission."
void gutter(B)(ref B out_, const(char)[] mark, const(char)[] body_) {
    out_.put(mark);
    foreach (c; body_) {
        out_.put((&c)[0 .. 1]);
        if (c == '\n') out_.put(mark);
    }
    out_.put("\n");
}

int handleMessageDisplay(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    if (sessionId.length == 0) return 0;
    if (!firstChunk(input)) return 0;

    auto db = openDb();
    if (db is null) return 0;

    __gshared ZBuf lines;
    lines.reset();

    foreach (i; 0 .. 16) {
        auto imm = readImmediateMessage(db, cwd, sessionId, SCREEN_MARK);
        if (imm.message is null) break;
        markImmediateDelivered(db, imm.msgId, imm.projectContext, sessionId, SCREEN_MARK);
        gutter(lines, gutterFor(imm.msgId), imm.message);
    }
    if (lines.len > 0) lines.put("\n");
    sqlite3_close(db);

    if (lines.len == 0) return 0;

    __gshared char[262144] deltaBuf = 0;
    auto delta = extractJsonString(input, `"delta"`, &deltaBuf[0], deltaBuf.length);

    fputs(`{"hookSpecificOutput":{"hookEventName":"MessageDisplay","displayContent":"`, stdout);
    writeJsonString(lines.slice());
    if (delta !is null) writeJsonString(delta);
    fputs(`"}}` ~ "\n", stdout);
    return 0;
}
