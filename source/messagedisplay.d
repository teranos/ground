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

// "  ░▓▓▏[REPONAME] [BRANCHNAME] ci all checks passed ✓"
// "   ░░▏Nix / build-go (linux-latest, goat_binary) (pull_request) Successful in 8m"
enum CI_GUTTER    = "  ░▓▓▏";
enum CHECK_GUTTER = "   ░░▏";

const(char)[] gutterFor(const(char)[] msgId) {
    import matcher : contains;
    if (contains(msgId, ":ci:")) return CI_GUTTER;
    return contains(msgId, ":rite:") ? RITE_GUTTER : RITUAL_GUTTER;
}

// "░▏Could not do shit bro."
// "░▏Just didnt have the perission."
void gutter(B)(ref B out_, const(char)[] mark, const(char)[] body_) {
    gutter(out_, mark, mark, body_);
}

// The head names the run; what hangs under it are the checks that made it up.
void gutter(B)(ref B out_, const(char)[] first, const(char)[] rest,
               const(char)[] body_) {
    // A rite's stdout ends in a newline, and marking the nothing after it drew
    // a bare gutter under every ci block.
    auto b = body_;
    while (b.length > 0 && b[$ - 1] == '\n') b = b[0 .. $ - 1];

    out_.put(first);
    foreach (c; b) {
        out_.put((&c)[0 .. 1]);
        if (c == '\n') out_.put(rest);
    }
    out_.put("\n");
}

// The key decides both marks together, so no caller can pick one and forget
// the other.
void marked(B)(ref B out_, const(char)[] msgId, const(char)[] body_) {
    auto first = gutterFor(msgId);
    auto rest = first == CI_GUTTER ? CHECK_GUTTER : first;
    gutter(out_, first, rest, body_);
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
        // Bounded at 16, so a receipt that never lands draws the same line
        // sixteen times rather than forever. Still the same defect.
        if (!markImmediateDelivered(db, imm.msgId, imm.projectContext, sessionId, SCREEN_MARK))
            break;
        marked(lines, imm.msgId, imm.message);
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
