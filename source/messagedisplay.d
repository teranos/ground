module messagedisplay;

// What the operator reads, as it is drawn. A rite's verdict reaches the model
// as a blocking error and the client folds that into a header; displayContent
// replaces the text on screen instead, so the line is simply there.

import db : openDb, sqlite3_close, ZBuf;
import immediate : readImmediateMessage, markImmediateDelivered;
import parse : extractJsonString, writeJsonString;
import core.stdc.stdio : stdout, fputs;

// Its own mark. The model's watcher drains with `delivered:`, and the screen
// must not race it for the same row — one line, two readers, two marks.
enum SCREEN_MARK = "screen:";

// The first chunk, not the last. A message streams in several, and `final`
// marks the closing one — prepending there pastes the lines into the middle
// of a reply instead of above it.
bool firstChunk(const(char)[] input) {
    import matcher : contains;
    return contains(input, `"index":0`);
}

// The gutter is the attribution. ANSI does not survive this channel, so a
// line ground injects would otherwise read as something the model said —
// which is the echo defect in a different coat.
enum RITE_GUTTER   = "  ░░▏";
enum RITUAL_GUTTER = "░░▒▓▏";

// Density says which level is speaking: the performance, or one of its rites.
const(char)[] gutterFor(const(char)[] msgId) {
    import matcher : contains;
    return contains(msgId, ":rite:") ? RITE_GUTTER : RITUAL_GUTTER;
}

// Every line, not only the first. A multi-line message with a bare first line
// falls out of the margin and reads as prose again halfway through.
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

    // The original text follows, unchanged. Replacing rather than prepending
    // would delete the message the operator was reading.
    __gshared char[262144] deltaBuf = 0;
    auto delta = extractJsonString(input, `"delta"`, &deltaBuf[0], deltaBuf.length);

    fputs(`{"hookSpecificOutput":{"hookEventName":"MessageDisplay","displayContent":"`, stdout);
    writeJsonString(lines.slice());
    if (delta !is null) writeJsonString(delta);
    fputs(`"}}` ~ "\n", stdout);
    return 0;
}
