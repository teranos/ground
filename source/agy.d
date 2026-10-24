module agy;

// agy runs `ground hook agy <Event>` from a hooks.json entry: the event's JSON
// on stdin, the answer read back from stdout. What each event sends and reads,
// per pinned version, is the binary's own hooks.proto: `ground parity <Event>`.

import core.stdc.stdio : stdin, stdout, stderr, fread, fwrite, fputs;

enum BOOK_COMMAND = q"EOS
# what a hooks.json entry has agy run, the event's JSON on stdin:
ground hook agy PreToolUse
EOS";

// What ground answers an event. An empty decision is not agy's own: agy 1.4.4
// reads it as the deprecated allowTool, false unless set, and denies the tool.
// "ask" leaves it to agy's permissions and their Always Allow cache.
const(char)[] answerOf(const(char)[] event) {
    if (event == "PreToolUse") return `{"decision":"ask"}`;
    return "{}";
}

// agy's events share Claude Code's names, so they are attested under their own.
const(char)[] predicateOf(const(char)[] event, char[] buf) {
    size_t n = 0;
    foreach (c; "Agy") if (n < buf.length) buf[n++] = c;
    foreach (c; event) if (n < buf.length) buf[n++] = c;
    return buf[0 .. n];
}

private size_t cLen(const(char)* p) {
    size_t n = 0;
    while (p[n] != 0) n++;
    return n;
}

int handleAgyHook(int argc, const(char)** argv) {
    import db : openDb, sqlite3_close, attestEvent;
    import exec : emitError;
    import matcher : indexOf;
    import parse : extractJsonString;

    if (argc < 4 || argv[2][0 .. cLen(argv[2])] != "agy") {
        fputs("ground hook: usage: ground hook agy <Event>\n", stderr);
        return 1;
    }
    auto event = argv[3][0 .. cLen(argv[3])];

    __gshared char[262144] buf = "";
    size_t total = 0;
    while (total < buf.length) {
        auto n = fread(&buf[total], 1, buf.length - total, stdin);
        if (n == 0) break;
        total += n;
    }
    auto input = buf[0 .. total];

    __gshared char[128] convBuf = 0;
    auto conversation = extractJsonString(input, `"conversationId"`, &convBuf[0], convBuf.length);

    // The first of workspacePaths is where the conversation runs.
    __gshared char[4096] wsBuf = 0;
    const(char)[] workspace = null;
    auto wsIdx = indexOf(input, `"workspacePaths"`);
    if (wsIdx >= 0) {
        size_t pos = cast(size_t) wsIdx + `"workspacePaths"`.length;
        while (pos < input.length && (input[pos] == ' ' || input[pos] == ':')) pos++;
        if (pos < input.length && input[pos] == '[') {
            pos++;
            while (pos < input.length && (input[pos] == ' ' || input[pos] == '\n' || input[pos] == '\r')) pos++;
            if (pos < input.length && input[pos] == '"') {
                pos++;
                size_t wlen = 0;
                while (pos < input.length && input[pos] != '"' && wlen < wsBuf.length) wsBuf[wlen++] = input[pos++];
                if (wlen > 0) workspace = wsBuf[0 .. wlen];
            }
        }
    }

    char[64] pb;
    auto predicate = predicateOf(event, pb[]);
    auto db = openDb();
    if (db is null) {
        emitError("agy.db", "the store would not open, so this agy event is not recorded",
                  0, 0, cast(string) conversation, cast(string) predicate, "", "", "");
    } else {
        attestEvent(db, predicate, workspace, conversation, input);
        sqlite3_close(db);
    }

    auto answer = answerOf(event);
    fwrite(answer.ptr, 1, answer.length, stdout);
    fputs("\n", stdout);
    return 0;
}
