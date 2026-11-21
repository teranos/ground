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

    enum cmd = "SELECT count(*) FROM attestations WHERE json_extract(predicates, '$[0]') = 'transcript:line' "
        ~ "AND json_extract(contexts, '$[0]') = 'session:sess-a' "
        ~ "AND json_extract(json_extract(attributes, '$.line'), '$.message.content') LIKE '<command-name>/model</command-name>%'\0";
    assert(counted(db, cmd.ptr) == 1, "a slash command is in the store");

    enum other = "SELECT count(*) FROM attestations "
        ~ "WHERE json_extract(json_extract(attributes, '$.line'), '$.type') = 'a-type-nobody-has-written-yet'\0";
    assert(counted(db, other.ptr) == 1, "a line type ground has never heard of is kept too");

    enum asWritten = "SELECT count(*) FROM attestations WHERE json_extract(attributes, '$.line') = '" ~ mode ~ "'\0";
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

    enum second = "SELECT json_extract(attributes, '$.offset') FROM attestations WHERE json_extract(attributes, '$.line') = '" ~ mode ~ "'\0";
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
    enum n = "SELECT count(*) FROM attestations WHERE json_extract(attributes, '$.path') = '/t/d.jsonl'\0";
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
    enum longLine = "SELECT json_extract(attributes, '$.end') FROM attestations "
        ~ "WHERE json_extract(contexts, '$[0]') = 'session:sess-h' AND json_extract(attributes, '$.offset') = 0\0";
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


// "by default i dont want to send the tooloutput"
// "we dont really need to put all the PostTool to k, unless we can reach k directly"
// A kept line carries tool output: it is kept whole, and no pass of the stream,
// which goes through q, claims it. It waits for a node reached directly.

unittest {
    import stream : claimStream;
    import db : DIRECT_ONLY;
    auto db = memDb();
    assert(keepLines(db, "/t/s.jsonl", "sess-s", lines, 0).ok);

    assert(DIRECT_ONLY == 2);
    enum aside = "SELECT count(*) FROM attestations WHERE json_extract(predicates, '$[0]') = 'transcript:line' "
        ~ "AND qntx_at = 2\0";
    assert(counted(db, aside.ptr) == 3, "every kept line waits for a direct node");
    assert(claimStream(db, 77, 10) == 0, "and the stream through q claims none");
    sqlite3_close(db);
}

unittest {
    // 379 lines in this machine's transcripts are larger than the 272 KB a row
    // could be streamed at; the largest is 1.34 MB (2026-11-21). A row holds them whole.
    import stream : claimStream, nextClaimed, Claimed;
    import matcher : contains;
    auto db = memDb();
    enum head = `{"type":"user","message":{"content":"`;
    enum tail = `ENDOFLINE"}}`;
    __gshared char[1_400_000] big = 'x';
    big[0 .. head.length] = head;
    big[$ - tail.length - 1 .. $ - 1] = tail;
    big[$ - 1] = '\n';
    assert(keepLines(db, "/t/big.jsonl", "sess-big", big[], 0).lines == 1);
    // As a pass to a direct node will take it.
    import db : sqlite3_exec;
    sqlite3_exec(db, "UPDATE attestations SET qntx_at = 0\0".ptr, null, null, null);
    assert(claimStream(db, 78, 10) == 1);
    __gshared Claimed c;
    assert(nextClaimed(db, 78, 0, c));
    assert(!c.body_.over, "a 1.4 MB line fits the stream");
    assert(contains(c.body_.slice(), "ENDOFLINE"), "and goes whole");
    sqlite3_close(db);
}

unittest {
    // At the moment the line says it was written; a line that says none is
    // kept at the moment it was kept.
    auto db = memDb();
    enum stamped = `{"type":"user","timestamp":"2026-08-19T00:42:08.852Z"}` ~ "\n";
    assert(keepLines(db, "/t/ts.jsonl", "sess-ts", stamped, 0).ok);
    enum at = "SELECT count(*) FROM attestations WHERE json_extract(predicates, '$[0]') = 'transcript:line' "
        ~ "AND timestamp = '2026-08-19T00:42:08Z'\0";
    assert(counted(db, at.ptr) == 1);
    sqlite3_close(db);
}

import transcript : sessionOfPath;

unittest {
    assert(sessionOfPath("/h/.claude/projects/-x/c21677df-3b62-45ca-848b-27c489e877a0.jsonl")
        == "c21677df-3b62-45ca-848b-27c489e877a0");
    assert(sessionOfPath("/h/.claude/projects/-x/c21677df-3b62-45ca-848b-27c489e877a0/subagents/agent-a5b2.jsonl")
        == "c21677df-3b62-45ca-848b-27c489e877a0", "a subagent's lines belong to the session that started it");
}

import transcript : keepAll;

unittest {
    // "i dont want to come back, and find out i missed something"
    // Every transcript under a root, main and subagent, read to its end: what
    // was written before ground kept lines, and after a session's last hook.
    import db : mkdir;
    import core.stdc.stdio : remove;
    char[512] rb;
    auto root = tmpPath("-root", rb);
    size_t rl = 0; while (root[rl]) rl++;
    char[1024] pb;
    size_t n;
    const(char)* at(const(char)[] rest) {
        n = 0;
        foreach (c; root[0 .. rl]) pb[n++] = c;
        foreach (c; rest) pb[n++] = c;
        pb[n] = 0;
        return &pb[0];
    }
    mkdir(at(""), 493);
    mkdir(at("/proj"), 493);
    mkdir(at("/proj/sess-m"), 493);
    mkdir(at("/proj/sess-m/subagents"), 493);
    writeFile(at("/proj/sess-m.jsonl"), lines, "wb");
    writeFile(at("/proj/sess-m/subagents/agent-1.jsonl"), mode ~ "\n", "wb");
    writeFile(at("/proj/notes.txt"), "not a transcript\n", "wb");

    auto db = memDb();
    const(char)[][1] roots = [root[0 .. rl]];
    auto swept = keepAll(db, roots[], 2 * 1024 * 1024);
    assert(swept.ok);
    assert(swept.files == 2, "both transcripts, and nothing else");
    assert(swept.lines == 4);

    enum mine = "SELECT count(*) FROM attestations WHERE json_extract(predicates, '$[0]') = 'transcript:line' "
        ~ "AND json_extract(contexts, '$[0]') = 'session:sess-m'\0";
    assert(counted(db, mine.ptr) == 4, "the subagent's line is its session's");

    assert(keepAll(db, roots[], 2 * 1024 * 1024).lines == 0, "a second sweep keeps nothing twice");

    // Proven, not assumed: each file's bytes against what was kept of it.
    import transcript : provenAll;
    auto proof = provenAll(db, roots[]);
    assert(proof.same == 2 && proof.differ == 0, "what was kept is what each file holds");

    // A whole line the store does not hold is a file that differs.
    writeFile(at("/proj/sess-m.jsonl"), unseen ~ "\n", "ab");
    auto after = provenAll(db, roots[]);
    assert(after.same == 1 && after.differ == 1, "a line not kept is found");
    assert(after.shown == 1);

    remove(at("/proj/sess-m/subagents/agent-1.jsonl"));
    remove(at("/proj/sess-m.jsonl"));
    remove(at("/proj/notes.txt"));
    import core.sys.posix.unistd : rmdir;
    rmdir(at("/proj/sess-m/subagents"));
    rmdir(at("/proj/sess-m"));
    rmdir(at("/proj"));
    rmdir(at(""));
    sqlite3_close(db);
}
