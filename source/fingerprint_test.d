module fingerprint_test;

// "So, let's say I am not wavering on wanting the rename's be detected by some measure"

version (Posix):

import fingerprint;
import zbuf : ZBuf;
import matcher : indexOf;

// The hashes are the ones anyone can check: FNV-1a's own test values, and
// splitmix64's first output from zero. QNTX-Quotes holds the same four
// (crates/quotes-wasm/src/same.rs).
unittest {
    assert(fnv1a64("") == 0xcbf2_9ce4_8422_2325);
    assert(fnv1a64("a") == 0xaf63_dc4c_8601_ec8c);
    assert(fnv1a64("foobar") == 0x8594_4171_f739_67e8);
    assert(splitmix64(0) == 0xE220_A839_7B1D_CDAF);
}

// A line is what is left of it after trimming, a blank one is no line, and a
// line said twice is one line.
unittest {
    __gshared Fingerprint a, b;
    assert(fingerprintOf("one\n\n  two  \none\n\t\n", a));
    assert(a.lines == 2);
    assert(fingerprintOf("two\r\none", b));
    assert(b.lines == 2);
    assert(a.sketch == b.sketch);
    assert(!fingerprintOf("\n  \n", a));
    assert(!fingerprintOf("", a));
}

// Trimmed as QNTX-Quotes trims: of every space Unicode names one, not of
// ASCII's alone. A no-break space and an ideographic one are no part of a line.
unittest {
    __gshared Fingerprint plain, spaced;
    assert(fingerprintOf("x", plain));
    assert(fingerprintOf("  x　 ", spaced));
    assert(spaced.lines == 1);
    assert(plain.sketch == spaced.sketch);
}

// The value both sides agree on: the file is the one line "ground".
unittest {
    __gshared Fingerprint one;
    assert(fingerprintOf("ground\n", one));
    assert(one.lines == 1);
    auto hash = fnv1a64("ground");
    enum ulong GOLDEN = 0x9E37_79B9_7F4A_7C15;
    assert(one.sketch[0] == splitmix64(hash));
    assert(one.sketch[1] == splitmix64(hash ^ GOLDEN));
    assert(one.sketch[127] == splitmix64(hash ^ (127UL * GOLDEN)));
}

// A sketch as it stands on a row: 128 values, eight bytes each, the low byte
// first, in base64 with padding. The letters are from a third making of it,
// in Python, that shares no code with this or with QNTX-Quotes.
unittest {
    __gshared Fingerprint one;
    __gshared ZBuf said;
    assert(fingerprintOf("ground\n", one));
    said.reset();
    putSketch(said, one);
    auto s = said.slice();
    assert(s.length == 1368);
    assert(s[0 .. 24] == "eFdkkWX76SWFNr2vUbeYGpRS", s[0 .. 24]);
    assert(s[$ - 24 .. $] == "icHCmbJqNqnEbjzeUs5/aw==", s[$ - 24 .. $]);

    assert(fingerprintOf("one\n\n  two  \none\n\t\n", one));
    said.reset();
    putSketch(said, one);
    s = said.slice();
    assert(s[0 .. 24] == "6OOcoHBUiNOzeW9PdAjEqIvf", s[0 .. 24]);
    assert(s[$ - 24 .. $] == "4U+G/67yb2FyBV5MrdiFNQ==", s[$ - 24 .. $]);
}

// A file that is there, holding text, and gone when the test is.
private const(char)[] aFile(const(char)[] text, ref ZBuf path) {
    import core.stdc.stdio : fopen, fwrite, fclose;
    import core.sys.posix.unistd : getpid;
    path.reset();
    path.put("/tmp/ground-fingerprint-test-");
    path.putUint(getpid());
    auto f = fopen(path.ptr(), "w");
    assert(f !is null);
    assert(fwrite(text.ptr, 1, text.length, f) == text.length);
    fclose(f);
    return path.slice();
}

private void gone(ref ZBuf path) {
    import core.stdc.stdio : remove;
    remove(path.ptr());
}

// What Claude Code sends after a tool ran on one file.
private void after(ref ZBuf payload, string tool, const(char)[] file, string response) {
    payload.reset();
    payload.put(`{"hook_event_name":"PostToolUse","tool_name":"`);
    payload.put(tool);
    payload.put(`","tool_input":{"file_path":"`);
    payload.put(file);
    payload.put(`"},"tool_response":`);
    payload.put(response);
    payload.put(`}`);
}

// A write leaves the file's fingerprint on the row, as two attributes beside
// what the row already held.
unittest {
    __gshared ZBuf path, payload, row;
    auto file = aFile("one\n\n  two  \none\n", path);
    scope (exit) gone(path);
    after(payload, "Write", file, `{"type":"create"}`);
    auto said = withFingerprint("PostToolUse", payload.slice(), row);
    assert(indexOf(said, `"tool_name":"Write"`) >= 0, said);
    assert(indexOf(said, `,"lines":2,"sketch":"6OOcoHBUiNOzeW9PdAjEqIvf`) >= 0, said);
    assert(said[$ - 26 .. $] == `4U+G/67yb2FyBV5MrdiFNQ=="}`, said[$ - 26 .. $]);
}

// A read of the whole file leaves it too: it began at the first line and
// showed as many lines as the file has.
unittest {
    __gshared ZBuf path, payload, row;
    auto file = aFile("ground\n", path);
    scope (exit) gone(path);
    after(payload, "Read", file, `{"type":"text","file":{"filePath":"x","content":"ground\n","numLines":1,"startLine":1,"totalLines":1}}`);
    auto said = withFingerprint("PostToolUse", payload.slice(), row);
    assert(indexOf(said, `,"lines":1,"sketch":"eFdkkWX76SWFNr2vUbeYGpRS`) >= 0, said);
}

// A part of a file is not the file: a read that began further down, or showed
// fewer lines than there are, leaves the row as it was. So does an edit, which
// shows only what it changed, and a tool that has not run yet.
unittest {
    __gshared ZBuf path, payload, row;
    auto file = aFile("one\ntwo\nthree\n", path);
    scope (exit) gone(path);

    after(payload, "Read", file, `{"type":"text","file":{"filePath":"x","content":"two\n","numLines":1,"startLine":2,"totalLines":3}}`);
    assert(withFingerprint("PostToolUse", payload.slice(), row) == payload.slice());

    after(payload, "Read", file, `{"type":"text","file":{"filePath":"x","content":"one\ntwo\n","numLines":2,"startLine":1,"totalLines":3}}`);
    assert(withFingerprint("PostToolUse", payload.slice(), row) == payload.slice());

    // What a file's text says of itself is not what the tool said of the read.
    after(payload, "Read", file, `{"type":"text","file":{"filePath":"x","content":"\"numLines\":3,\"startLine\":1,\"totalLines\":3","numLines":1,"startLine":2,"totalLines":3}}`);
    assert(withFingerprint("PostToolUse", payload.slice(), row) == payload.slice());

    after(payload, "Edit", file, `{"filePath":"x"}`);
    assert(withFingerprint("PostToolUse", payload.slice(), row) == payload.slice());

    after(payload, "Write", file, `{"type":"create"}`);
    assert(withFingerprint("PreToolUse", payload.slice(), row) == payload.slice());
}

// A file with no lines, and one that is not there, get neither attribute.
unittest {
    __gshared ZBuf path, payload, row;
    auto file = aFile("\n  \n", path);
    after(payload, "Write", file, `{"type":"create"}`);
    assert(withFingerprint("PostToolUse", payload.slice(), row) == payload.slice());
    gone(path);
    assert(withFingerprint("PostToolUse", payload.slice(), row) == payload.slice());
}

// What reaches the node carries the two, and so does the row the store keeps
// after seven days: the node holds a read's path and no text, and the
// fingerprint is what it tells a renamed file by.
unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, sqlite3_exec, sqlite3_prepare_v2, sqlite3_step,
        sqlite3_finalize, sqlite3_column_text, sqlite3_stmt, applySchema, SQLITE_OK, SQLITE_ROW;
    import stream : SKELETON_SQL;
    import decay : decayDb;

    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    scope (exit) sqlite3_close(db);
    assert(applySchema(db));
    enum row = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes, created_at) VALUES "
        ~ "('r', '[\"s\"]', '[\"PostToolUse\"]', '[\"session:x\"]', '[\"ground\"]', '2026-01-01T00:00:00Z', 'ground', "
        ~ "'{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/a.md\"},\"tool_response\":{\"file\":{\"content\":\"much text\"}},\"lines\":2,\"sketch\":\"6OOc\"}', "
        ~ "datetime('now', '-30 days'))\0";
    assert(sqlite3_exec(db, row.ptr, null, null, null) == SQLITE_OK);

    const(char)[] attributes(string sql) {
        __gshared char[4096] buf;
        sqlite3_stmt* stmt;
        assert(sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK);
        scope (exit) sqlite3_finalize(stmt);
        assert(sqlite3_step(stmt) == SQLITE_ROW);
        auto text = sqlite3_column_text(stmt, 0);
        size_t n = 0;
        while (text[n] != 0) { buf[n] = text[n]; n++; }
        return buf[0 .. n];
    }

    auto posted = attributes("SELECT " ~ SKELETON_SQL ~ " FROM attestations WHERE id = 'r'\0");
    assert(indexOf(posted, `"lines":2`) >= 0 && indexOf(posted, `"sketch":"6OOc"`) >= 0, posted);
    assert(indexOf(posted, "much text") < 0, posted);

    assert(decayDb(db) == 0);
    auto kept = attributes("SELECT attributes FROM attestations WHERE id = 'r'\0");
    assert(indexOf(kept, `"decayed":1`) >= 0, kept);
    assert(indexOf(kept, `"lines":2`) >= 0 && indexOf(kept, `"sketch":"6OOc"`) >= 0, kept);
}
