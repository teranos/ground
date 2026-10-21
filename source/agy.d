module agy;

import core.stdc.stdio : stdin, stdout, stderr, fread, fputs, fwrite;
import db : openDb, sqlite3_close, attestEvent;
import parse : extractJsonString;
import matcher : indexOf;

// BOOK_COMMAND = q"EOS
// # run by Google Antigravity (AGY) on every lifecycle hook:
// ground hook agy <Event>
// EOS";

size_t strLen(const(char)* ptr) {
    size_t len = 0;
    while (ptr[len] != 0) len++;
    return len;
}

int handleAgyHook(int argc, const(char)** argv) {
    if (argc < 4) {
        fputs("ground hook agy: missing event argument (usage: ground hook agy <Event>)\n", stderr);
        return 1;
    }
    const(char)[] event = argv[3][0 .. strLen(argv[3])];

    // Read full stdin payload
    __gshared char[262144] buf = 0;
    size_t total = 0;
    while (total < buf.length) {
        auto n = fread(&buf[total], 1, buf.length - total, stdin);
        if (n == 0) break;
        total += n;
    }
    if (total == 0) {
        fputs("ground hook agy: empty stdin\n", stderr);
        return 1;
    }
    auto input = buf[0 .. total];

    // Extract AGY conversationId
    __gshared char[128] convBuf = 0;
    auto conversationId = extractJsonString(input, `"conversationId"`, &convBuf[0], convBuf.length);
    if (conversationId is null) conversationId = "unknown";

    // Extract first workspace path from "workspacePaths": ["/path/to/ws", ...]
    __gshared char[4096] wsBuf = 0;
    const(char)[] workspacePath = null;
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
                while (pos < input.length && input[pos] != '"' && wlen < wsBuf.length) {
                    wsBuf[wlen++] = input[pos++];
                }
                if (wlen > 0) workspacePath = wsBuf[0 .. wlen];
            }
        }
    }
    if (workspacePath is null) workspacePath = "";

    // Attest event directly into Ground's SQLite store
    auto db = openDb();
    if (db !is null) {
        attestEvent(db, event, workspacePath, conversationId, input);
        sqlite3_close(db);
    }

    // Output AGY-compliant JSON on stdout
    if (event == "PreToolUse") {
        fputs("{\"decision\": \"allow\"}\n", stdout);
    } else if (event == "SessionStart" || event == "PreInvocation" || event == "PostInvocation") {
        fputs("{\"injectSteps\": []}\n", stdout);
    } else if (event == "Stop") {
        fputs("{\"decision\": \"\"}\n", stdout);
    } else {
        fputs("{}\n", stdout);
    }

    return 0;
}
