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

enum REWRITE_CONTROL = "inline-not-address";

// The first rewrite of a session leaves a message for the next Stop, and a
// marker so the second rewrite leaves nothing.
private void noteRewriteOnce(const(char)[] cwd, const(char)[] sessionId) {
    import db : attestationExists, attestControlFire;
    import deferred : writeDeferredMessage;

    auto db = openDb();
    if (db is null) return;

    if (!attestationExists(db, "GroundedMessageDisplay", REWRITE_CONTROL, sessionId)) {
        writeDeferredMessage(db, REWRITE_CONTROL, cwd, sessionId,
            "A file and line number you wrote was replaced by the lines it names, "
            ~ "before it reached the screen. The reader never sees the address, so "
            ~ "it tells them nothing — show the code instead.", 0);
        attestControlFire(db, "GroundedMessageDisplay", REWRITE_CONTROL, cwd, sessionId);
    }

    sqlite3_close(db);
}

int handleMessageDisplay(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    if (sessionId.length == 0) return 0;

    __gshared char[262144] deltaBuf = 0;
    auto delta = extractJsonString(input, `"delta"`, &deltaBuf[0], deltaBuf.length);

    // An address is replaced by the lines it names, on every chunk. The
    // immediate queue below is drained on the first one only, because it is
    // drawn once above the message rather than through it.
    import inlineref : inlineRefs, Rewrite, readTracked, g_readRoot;
    import controls : projectFiles;
    g_readRoot = cwd;
    Rewrite rw;
    if (delta !is null) rw = inlineRefs(delta, projectFiles, &readTracked);

    // Told once, the way the other reminders are. A rewrite that announced
    // itself on every chunk would be its own kind of noise.
    if (rw.changed > 0) noteRewriteOnce(cwd, sessionId);

    __gshared ZBuf lines;
    lines.reset();

    if (firstChunk(input)) {
        auto db = openDb();
        if (db !is null) {
            foreach (i; 0 .. 16) {
                auto imm = readImmediateMessage(db, cwd, sessionId, SCREEN_MARK);
                if (imm.message is null) break;
                // Bounded at 16, so a receipt that never lands draws the same
                // line sixteen times rather than forever. Still the same defect.
                if (!markImmediateDelivered(db, imm.msgId, imm.projectContext, sessionId, SCREEN_MARK))
                    break;
                marked(lines, imm.msgId, imm.message);
            }
            if (lines.len > 0) lines.put("\n");
            sqlite3_close(db);
        }
    }

    // Saying nothing leaves the chunk as it was. Emitting displayContent that
    // merely repeats the delta would be a rewrite claiming to have happened.
    if (lines.len == 0 && rw.changed == 0) return 0;

    fputs(`{"hookSpecificOutput":{"hookEventName":"MessageDisplay","displayContent":"`, stdout);
    writeJsonString(lines.slice());
    if (delta !is null) writeJsonString(rw.changed > 0 ? rw.text : delta);
    fputs(`"}}` ~ "\n", stdout);
    return 0;
}
