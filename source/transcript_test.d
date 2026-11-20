module transcript_test;

// "where the principle is we get all of it."

// The transcript is the session's whole record. Every line of it is kept as
// written, whatever its type, so nothing waits on a matcher being written for it.

import transcript : keepLines, keptUpTo, keepTranscript;
import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK,
            sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_stmt,
            sqlite3_column_int64, SQLITE_ROW;

private sqlite3* memDb() {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    return db;
}

private long counted(sqlite3* db, const(char)* q) {
    sqlite3_stmt* s;
    if (sqlite3_prepare_v2(db, q, -1, &s, null) != SQLITE_OK) return -1;
    long n = -1;
    if (sqlite3_step(s) == SQLITE_ROW) n = sqlite3_column_int64(s, 0);
    sqlite3_finalize(s);
    return n;
}

enum slash = `{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>\n<command-args>opus</command-args>"},"uuid":"u1"}`;
enum mode = `{"type":"permission-mode","permissionMode":"plan"}`;
enum unseen = `{"type":"a-type-nobody-has-written-yet","x":1}`;
enum lines = slash ~ "\n" ~ mode ~ "\n" ~ unseen ~ "\n";

unittest {
    auto db = memDb();
    auto kept = keepLines(db, "/t/a.jsonl", "sess-a", lines, 0);
    assert(kept.ok);
    assert(kept.lines == 3, "every line, whatever its type");
    assert(kept.end == lines.length);

    enum cmd = "SELECT count(*) FROM transcript_line WHERE session = 'sess-a' "
        ~ "AND json_extract(line, '$.message.content') LIKE '<command-name>/model</command-name>%'\0";
    assert(counted(db, cmd.ptr) == 1, "a slash command is in the store");

    enum other = "SELECT count(*) FROM transcript_line "
        ~ "WHERE json_extract(line, '$.type') = 'a-type-nobody-has-written-yet'\0";
    assert(counted(db, other.ptr) == 1, "a line type ground has never heard of is kept too");

    enum asWritten = "SELECT count(*) FROM transcript_line WHERE line = '" ~ mode ~ "'\0";
    assert(counted(db, asWritten.ptr) == 1, "the line is kept as written");

    sqlite3_close(db);
}

unittest {
    // A line is kept at its byte offset in the file, and the walk resumes where
    // the last kept line ended.
    auto db = memDb();
    assert(keptUpTo(db, "/t/b.jsonl") == 0);
    auto kept = keepLines(db, "/t/b.jsonl", "sess-b", lines, 0);
    assert(keptUpTo(db, "/t/b.jsonl") == lines.length);

    enum second = "SELECT offset FROM transcript_line WHERE line = '" ~ mode ~ "'\0";
    assert(counted(db, second.ptr) == slash.length + 1);
    sqlite3_close(db);
}

unittest {
    // A line still being written has no newline yet. Keeping it would keep half
    // of it; it waits for the next walk.
    auto db = memDb();
    enum partial = slash ~ "\n" ~ `{"type":"assis`;
    auto first = keepLines(db, "/t/c.jsonl", "sess-c", partial, 0);
    assert(first.lines == 1);
    assert(keptUpTo(db, "/t/c.jsonl") == slash.length + 1);

    enum rest = `{"type":"assistant"}` ~ "\n";
    auto second = keepLines(db, "/t/c.jsonl", "sess-c", rest, slash.length + 1);
    assert(second.lines == 1);
    assert(keptUpTo(db, "/t/c.jsonl") == slash.length + 1 + rest.length);
    sqlite3_close(db);
}

unittest {
    // Two hooks walking the same bytes keep each line once.
    auto db = memDb();
    assert(keepLines(db, "/t/d.jsonl", "sess-d", lines, 0).lines == 3);
    assert(keepLines(db, "/t/d.jsonl", "sess-d", lines, 0).lines == 0);
    enum n = "SELECT count(*) FROM transcript_line WHERE path = '/t/d.jsonl'\0";
    assert(counted(db, n.ptr) == 3);
    sqlite3_close(db);
}

// The file itself: read from where the store left off to its end.

private const(char)* tmpPath(const(char)[] name, ref char[512] buf) {
    import core.stdc.stdlib : getenv;
    import core.sys.posix.unistd : getpid;
    auto t = getenv("TMPDIR\0".ptr);
    size_t n = 0;
    void put(const(char)[] s) { foreach (c; s) buf[n++] = c; }
    if (t !is null) { size_t l = 0; while (t[l]) l++; put(t[0 .. l]); } else put("/tmp/");
    if (buf[n - 1] != '/') put("/");
    put("transcript-test-");
    char[16] d; size_t dl = 0; uint p = cast(uint) getpid();
    do { d[dl++] = cast(char)('0' + p % 10); p /= 10; } while (p);
    foreach_reverse (i; 0 .. dl) buf[n++] = d[i];
    put(name);
    buf[n] = 0;
    return &buf[0];
}

private void writeFile(const(char)* path, const(char)[] s, const(char)* how) {
    import core.stdc.stdio : fopen, fwrite, fclose;
    auto f = fopen(path, how);
    assert(f !is null);
    fwrite(s.ptr, 1, s.length, f);
    fclose(f);
}

unittest {
    import core.stdc.stdio : remove;
    char[512] pb;
    auto p = tmpPath("-e.jsonl", pb);
    size_t pl = 0; while (p[pl]) pl++;

    auto db = memDb();
    writeFile(p, lines, "wb");
    auto first = keepTranscript(db, p[0 .. pl], "sess-e");
    assert(first.ok);
    assert(first.lines == 3);

    enum more = `{"type":"system","subtype":"compact_boundary"}` ~ "\n";
    writeFile(p, more, "ab");
    auto second = keepTranscript(db, p[0 .. pl], "sess-e");
    assert(second.ok);
    assert(second.lines == 1, "only what was written since");
    assert(keptUpTo(db, p[0 .. pl]) == lines.length + more.length);

    remove(p);
    sqlite3_close(db);
}

unittest {
    // A live session's transcript runs to hundreds of megabytes, and the first
    // walk would read it whole inside one hook, under the write lock. A walk
    // reads at most `cap` bytes; the walks after it catch up.
    import core.stdc.stdio : remove;
    char[512] pb;
    auto p = tmpPath("-g.jsonl", pb);
    size_t pl = 0; while (p[pl]) pl++;

    auto db = memDb();
    writeFile(p, lines, "wb");
    auto first = keepTranscript(db, p[0 .. pl], "sess-g", slash.length + 1 + 4);
    assert(first.ok);
    assert(first.lines == 1, "one line fits under the cap");
    auto second = keepTranscript(db, p[0 .. pl], "sess-g", slash.length + 1 + 4);
    assert(second.lines == 2);
    assert(keptUpTo(db, p[0 .. pl]) == lines.length);

    remove(p);
    sqlite3_close(db);
}

unittest {
    // A line longer than the cap is still kept: the walk reads until it ends.
    import core.stdc.stdio : remove;
    char[512] pb;
    auto p = tmpPath("-h.jsonl", pb);
    size_t pl = 0; while (p[pl]) pl++;

    auto db = memDb();
    writeFile(p, lines, "wb");
    auto k = keepTranscript(db, p[0 .. pl], "sess-h", 8);
    assert(k.ok);
    enum longLine = "SELECT end FROM transcript_line WHERE session = 'sess-h' AND offset = 0\0";
    assert(counted(db, longLine.ptr) == slash.length + 1, "the line longer than the cap is kept whole");

    remove(p);
    sqlite3_close(db);
}

unittest {
    // A transcript that cannot be read is an error, never nothing kept, and it
    // says which file and why.
    import matcher : contains;
    auto db = memDb();
    auto k = keepTranscript(db, "/nonexistent/ground/transcript.jsonl", "sess-f");
    assert(!k.ok);
    assert(contains(k.why, "/nonexistent/ground/transcript.jsonl"), "names the file");
    assert(contains(k.why, "No such file"), "says why it would not open");
    sqlite3_close(db);
}

import transcript : keepAgentTranscript;

unittest {
    // Claude Code names an agent_transcript_path on every SubagentStop, and
    // writes the file for only some agents: 454 of 454 named since 2026-11-19
    // were never written. There is nothing there to keep.
    auto db = memDb();
    auto k = keepAgentTranscript(db, "/nonexistent/ground/subagents/agent-x.jsonl", "sess-i");
    assert(k.ok);
    assert(k.lines == 0);
    sqlite3_close(db);
}

unittest {
    // One that was written is kept like any other.
    import core.stdc.stdio : remove;
    char[512] pb;
    auto p = tmpPath("-agent.jsonl", pb);
    size_t pl = 0; while (p[pl]) pl++;
    auto db = memDb();
    writeFile(p, lines, "wb");
    auto k = keepAgentTranscript(db, p[0 .. pl], "sess-j");
    assert(k.ok);
    assert(k.lines == 3);
    remove(p);
    sqlite3_close(db);
}
