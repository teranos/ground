module probe;

// "on text outside of quotes placed in docs or code comments, we run a Jev Score"
// "nothing will be decided yet, its just to collect how it is evaluating what you say."
// "build the probe on commit, scores into QNTX"

import db : ZBuf, sqlite3;

// Each piece's score is an attestation in ground's store, and sky carries the
// store to the node. The asking runs in a child the hook lets go of.
enum PREDICATE = "AIProseScoreProbeVariantA1";
enum INSTRUCTIONS = "How would you describe this piece of prose?";
static immutable string[10] CRITERIA = ["Inverted", "Hedged", "Caveated", "Deferred", "Expanded",
                                        "Inferred", "Warstory", "Blamed", "Referenced", "Specified"];

private bool isQuote(const(char)[] t) {
    return t.length >= 3 && t[0] == '"' && t[$ - 1] == '"';
}

private bool endsWith(const(char)[] s, const(char)[] tail) {
    return s.length >= tail.length && s[$ - tail.length .. $] == tail;
}

private const(char)[] strip(const(char)[] s) {
    size_t b = 0, e = s.length;
    while (b < e && (s[b] == ' ' || s[b] == '\t')) b++;
    while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t' || s[e - 1] == '\r')) e--;
    return s[b .. e];
}

// Every piece of prose a diff added, outside quotes: a run of comment lines
// in code, a paragraph in a doc. `git show --unified=0 --format=` is the diff.
void eachPiece(const(char)[] diff, scope void delegate(const(char)[] file, const(char)[] prose) found) {
    __gshared char[65536] run = 0;
    __gshared char[512] pathBuf = 0;
    size_t runLen = 0;
    const(char)[] path;
    bool doc = false, fenced = false;

    void close() {
        if (runLen > 0 && path.length > 0) found(path, run[0 .. runLen]);
        runLen = 0;
    }
    void add(const(char)[] text) {
        // A run longer than the buffer is handed over in parts, never cut.
        if (runLen > 0 && runLen + 1 + text.length > run.length) close();
        if (runLen > 0) run[runLen++] = ' ';
        foreach (c; text) if (runLen < run.length) run[runLen++] = c;
    }

    size_t at = 0;
    while (at < diff.length) {
        size_t end = at;
        while (end < diff.length && diff[end] != '\n') end++;
        auto line = diff[at .. end];
        at = end + 1;

        if (line.length >= 4 && line[0 .. 4] == "+++ ") {
            close();
            fenced = false;
            if (line.length > 6 && line[4 .. 6] == "b/") {
                auto p = line[6 .. $];
                auto n = p.length < pathBuf.length ? p.length : pathBuf.length;
                foreach (i; 0 .. n) pathBuf[i] = p[i];
                path = pathBuf[0 .. n];
                doc = endsWith(path, ".md");
            } else {
                path = null;
            }
            continue;
        }
        if (line.length == 0 || line[0] != '+') { close(); continue; }

        auto body_ = strip(line[1 .. $]);
        if (doc) {
            if (body_.length >= 3 && body_[0 .. 3] == "```") { close(); fenced = !fenced; continue; }
            if (fenced || body_.length == 0 || body_[0] == '>' || isQuote(body_)) { close(); continue; }
            add(body_);
            continue;
        }
        if (body_.length < 2 || body_[0 .. 2] != "//") { close(); continue; }
        size_t s = 0;
        while (s < body_.length && body_[s] == '/') s++;
        auto text = strip(body_[s .. $]);
        if (text.length == 0 || isQuote(text)) { close(); continue; }
        add(text);
    }
    close();
}

// The commit `git commit` says it made: `[branch sha]` or
// `[branch (root-commit) sha]` on its first line. Empty when it made none.
const(char)[] committedSha(const(char)[] stdout) {
    __gshared char[64] buf = 0;
    if (stdout.length == 0 || stdout[0] != '[') return "";
    size_t close = 0;
    while (close < stdout.length && stdout[close] != ']' && stdout[close] != '\n') close++;
    if (close >= stdout.length || stdout[close] != ']') return "";
    size_t start = close;
    while (start > 1 && stdout[start - 1] != ' ') start--;
    auto sha = stdout[start .. close];
    if (sha.length < 7 || sha.length > buf.length) return "";
    foreach (c; sha)
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return "";
    foreach (i, c; sha) buf[i] = c;
    return buf[0 .. sha.length];
}

// The commit a PostToolUse commit made. `git commit -q` prints nothing, and
// PostToolUse is only heard for a command that exited 0, so silence names the
// tree's HEAD. Anything else printed without a sha made no commit.
const(char)[] commitOf(const(char)[] stdout, const(char)[] tree) {
    auto sha = committedSha(stdout);
    if (sha.length > 0) return sha;
    foreach (c; stdout)
        if (c != '\n' && c != '\r' && c != ' ' && c != '\t') return "";
    import libgit2 : Repo;
    __gshared Repo g;
    __gshared char[40] head = 0;
    if (!g.open(tree)) return "";
    auto id = g.headId();
    size_t n;
    if (id !is null) foreach (i, c; id) { head[i] = c; n = i + 1; }
    g.close();
    return head[0 .. n];
}

private void putJson(ref char[] dest, ref size_t n, const(char)[] s) {
    foreach (c; s) {
        const(char)[] esc;
        if (c == '"') esc = `\"`;
        else if (c == '\\') esc = `\\`;
        else if (c == '\n') esc = `\n`;
        else if (c == '\t') esc = `\t`;
        else if (c < 0x20) continue;
        if (esc.length > 0) { foreach (e; esc) if (n < dest.length) dest[n++] = e; }
        else if (n < dest.length) dest[n++] = c;
    }
}

// One piece's attestation attributes: where it came from, the prose, and
// Jev's answer as Jev gave it, or why there is none.
const(char)[] probeAttrs(char[] dest, const(char)[] sha, const(char)[] file, const(char)[] prose,
                         int status, const(char)[] answer, long inTokens, long outTokens,
                         const(char)[] why) {
    size_t n;
    void put(const(char)[] s) { foreach (c; s) if (n < dest.length) dest[n++] = c; }
    void num(long v) {
        if (v < 0) { put("-"); v = -v; }
        char[20] d = 0;
        size_t dl;
        do { d[dl++] = cast(char)('0' + v % 10); v /= 10; } while (v > 0);
        foreach_reverse (i; 0 .. dl) put(d[i .. i + 1]);
    }
    put(`{"commit":"`); putJson(dest, n, sha);
    put(`","file":"`); putJson(dest, n, file);
    put(`","prose":"`); putJson(dest, n, prose);
    put(`","status":`); num(status);
    if (answer.length > 0) {
        put(`,"answer":`); put(answer);
        put(`,"input_tokens":`); num(inTokens);
        put(`,"output_tokens":`); num(outTokens);
    } else {
        put(`,"why":"`); putJson(dest, n, why); put(`"`);
    }
    put("}");
    return dest[0 .. n];
}

extern (C) {
    private int setsid();
    private void _exit(int status);
}

// The probe for one commit, in a child the hook does not wait for. The store
// is shut in the caller: a fork with it open hands the child no kernel locks.
void probeDetached(const(char)[] sha, const(char)[] tree, const(char)[] sessionId) {
    import forkguard : forkClean;
    import errors : sayQuietly;
    auto pid = forkClean("prose-probe", sessionId);
    if (pid < 0) {
        sayQuietly("probe.fork", "could not fork to score this commit's prose", -1,
                   sessionId, PREDICATE, sha);
        return;
    }
    if (pid != 0) return;

    setsid();
    {
        import core.stdc.stdio : freopen, stdin, stdout, stderr;
        freopen("/dev/null\0".ptr, "r\0".ptr, stdin);
        freopen("/dev/null\0".ptr, "w\0".ptr, stdout);
        freopen("/dev/null\0".ptr, "w\0".ptr, stderr);
    }
    // Read before the scoring, which needs a Jev token and the removal check does not.
    import quoteremoval : attestRemovals;
    attestRemovals(sha, tree, sessionId);
    probeCommit(sha, tree, sessionId);
    _exit(0);
}

// Whether this commit's prose was scored already: a PostToolUse can be heard twice.
private bool probedAlready(sqlite3* db, const(char)[] sha) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_stmt, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    enum sql = "SELECT 1 FROM attestations WHERE predicates = '[\"" ~ PREDICATE ~ "\"]' "
        ~ "AND json_extract(attributes, '$.commit') = ?1 LIMIT 1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return false;
    sqlite3_bind_text(stmt, 1, sha.ptr, cast(int) sha.length, SQLITE_TRANSIENT);
    auto found = sqlite3_step(stmt) == SQLITE_ROW;
    sqlite3_finalize(stmt);
    return found;
}

void probeCommit(const(char)[] sha, const(char)[] tree, const(char)[] sessionId) {
    import errors : sayQuietly;
    import noul : jevToken, askJev, answersOf, Wide;
    import db : openDb, sqlite3_close, attestEvent;

    auto token = jevToken();
    if (token.length == 0) {
        sayQuietly("probe.token", "no Jev token at ~/.qntx/jev-token, so this commit's prose was not scored",
                   -1, sessionId, PREDICATE, sha);
        return;
    }

    // The commit as `git show --unified=0 --format=` prints it, read in this
    // process by libgit2.
    import libgit2 : Repo;
    __gshared Repo g;
    if (!g.open(tree)) {
        sayQuietly("probe.diff", "the tree would not open, so this commit's prose was not scored",
                   -1, sessionId, PREDICATE, sha);
        return;
    }
    __gshared char[4 * 1024 * 1024] diff = 0;
    auto shown = g.show(sha, diff[]);
    auto over = g.overflowed;
    g.close();
    if (shown is null) {
        sayQuietly("probe.diff", "the commit would not read, so its prose was not scored",
                   -1, sessionId, PREDICATE, sha);
        return;
    }
    size_t len = shown.length;
    if (over)
        sayQuietly("probe.diff", "the commit's diff is larger than the probe reads; the prose past it was not scored",
                   -1, sessionId, PREDICATE, sha);

    auto db = openDb();
    if (db is null) {
        sayQuietly("probe.store", "the store would not open, so this commit's prose was not scored",
                   -1, sessionId, PREDICATE, sha);
        return;
    }
    scope (exit) sqlite3_close(db);
    if (probedAlready(db, sha)) return;

    size_t index = 0;
    eachPiece(diff[0 .. len], (const(char)[] file, const(char)[] prose) {
        __gshared Wide state;
        state.reset();
        state.put(`{"prose":"`);
        foreach (c; prose) {
            if (c == '"') state.put(`\"`);
            else if (c == '\\') state.put(`\\`);
            else if (c < 0x20) continue;
            else state.putChar(c);
        }
        state.put(`"}`);

        __gshared char[8192] reply = 0;
        auto ask = askJev(state.slice(), "prose", "score", INSTRUCTIONS, CRITERIA[], [], token, reply);

        __gshared char[80000] attrs = 0;
        auto a = ask.ok
            ? probeAttrs(attrs[], sha, file, prose, ask.status, answersOf(reply[0 .. ask.replyLen]),
                         ask.answer.inputTokens, ask.answer.outputTokens, "")
            : probeAttrs(attrs[], sha, file, prose, ask.status, "", -1, -1, ask.why());

        __gshared ZBuf tag;
        tag.reset();
        tag.put(sha);
        tag.put(":");
        tag.putUint(cast(ulong) index++);
        attestEvent(db, PREDICATE, tree, sessionId, a, tag.slice());

        if (!ask.ok)
            sayQuietly("probe.jev", cast(string) ask.why(), ask.status, sessionId, PREDICATE, sha);
    });
}

unittest {
    enum diff = "diff --git a/source/x.d b/source/x.d\n"
        ~ "--- a/source/x.d\n"
        ~ "+++ b/source/x.d\n"
        ~ "@@ -1,0 +2,4 @@\n"
        ~ "+// The store is shut first: a child of a process with a connection\n"
        ~ "+// open inherits its lock bookkeeping.\n"
        ~ "+// \"a quote stays a quote\"\n"
        ~ "+int x = 1; // trailing code is not prose\n"
        ~ "@@ -9,0 +14,1 @@\n"
        ~ "+    // Second run.\n"
        ~ "diff --git a/README.md b/README.md\n"
        ~ "--- a/README.md\n"
        ~ "+++ b/README.md\n"
        ~ "@@ -3,0 +4,6 @@\n"
        ~ "+QNTX gets every event\n"
        ~ "+without its tool payloads.\n"
        ~ "+\n"
        ~ "+```\n"
        ~ "+// inside a fence is code\n"
        ~ "+```\n"
        ~ "diff --git a/old.d b/old.d\n"
        ~ "--- a/old.d\n"
        ~ "+++ /dev/null\n";

    __gshared char[64][8] files;
    __gshared char[256][8] prose;
    __gshared size_t[8] fileLen, proseLen;
    __gshared size_t n;
    n = 0;
    eachPiece(diff, (const(char)[] file, const(char)[] text) {
        foreach (i, c; file) files[n][i] = c;
        fileLen[n] = file.length;
        foreach (i, c; text) prose[n][i] = c;
        proseLen[n] = text.length;
        n++;
    });
    assert(n == 3, "two comment runs and one paragraph");
    assert(files[0][0 .. fileLen[0]] == "source/x.d");
    assert(prose[0][0 .. proseLen[0]]
        == "The store is shut first: a child of a process with a connection open inherits its lock bookkeeping.",
        "a run is its lines joined, and a quote ends it");
    assert(prose[1][0 .. proseLen[1]] == "Second run.");
    assert(files[2][0 .. fileLen[2]] == "README.md");
    assert(prose[2][0 .. proseLen[2]] == "QNTX gets every event without its tool payloads.",
        "a doc's paragraph is prose, and a fence is not");
}

unittest {
    // git commit names what it made on its first line.
    assert(committedSha("[main d4bf9cd] SKY: a 429 from the node is asked again\n 1 file changed") == "d4bf9cd");
    assert(committedSha("[main (root-commit) 3a1b2c4] first\n") == "3a1b2c4");
    assert(committedSha("[sre-review-and-fixes f274a92] HOOKS: x") == "f274a92");
    assert(committedSha("On branch main\nnothing to commit, working tree clean\n") == "",
        "no commit made is no commit to probe");
    assert(committedSha("") == "");
}

unittest {
    // `git commit -q` prints nothing, and PostToolUse is only heard for a
    // command that exited 0, so the commit it made is the tree's HEAD.
    import libgit2_test : fixture, gitOut;
    auto root = fixture();
    auto head = gitOut(root.text(), "rev-parse HEAD");
    assert(commitOf("", root.text()) == head.text());
    assert(commitOf("\n", root.text()) == head.text());
    assert(commitOf("[main d4bf9cd] x\n", root.text()) == "d4bf9cd");
    assert(commitOf("On branch main\nnothing to commit, working tree clean\n", root.text()) == "",
        "a command that printed something else made no commit");
}

unittest {
    // What QNTX is sent for each piece: where it came from, the prose, and
    // Jev's answer as Jev gave it.
    __gshared char[4096] buf = 0;
    auto a = probeAttrs(buf[], "d4bf9cd", "source/x.d", "Said \"so\".", 200,
                        `{"prose":{"type":"score","score":6.49}}`, 397, 18, "");
    assert(a == `{"commit":"d4bf9cd","file":"source/x.d","prose":"Said \"so\".","status":200,`
        ~ `"answer":{"prose":{"type":"score","score":6.49}},"input_tokens":397,"output_tokens":18}`);
    auto f = probeAttrs(buf[], "d4bf9cd", "a.md", "x", 503, "", -1, -1, "jev answered 503: busy");
    assert(f == `{"commit":"d4bf9cd","file":"a.md","prose":"x","status":503,"why":"jev answered 503: busy"}`,
        "a piece Jev did not score is attested with why");
}
