module ritual;

import rite : Verdict;

extern (C) char* getcwd(char* buf, size_t size);

// The two pendings are distinct because a rite waiting for the first time
// and one waiting again are not the same fact.
enum RiteState {
    Never,    // darker gray
    Ran,      // lighter gray — held, will run again
    Running,  // blinking blue
    Passed,   // green
    Halted,   // blinking red
}

// Done and Halted are reached by running, not by a command. Aborted is the
// exception: "it ends when it ends, not because i ran ritual stop".
enum RitualState { Live, Done, Halted, Aborted }

enum MAX_RITES = 32;

// A performance is identified by itself. The worktree is where it is being
// performed, not what it is.
struct Position {
    const(char)[] id;
    const(char)[] repo;
    const(char)[] ritual;
    const(char)[] branch;
    const(char)[] worktree;
    size_t current;
    size_t riteCount;
    RiteState[MAX_RITES] states;
    RitualState state;
}

// The performance and the moment it began. Two performances of one ritual are
// two rows; the same id twice is one performance moving.
struct PerfId {
    char[80] buf = 0;
    size_t len;
    const(char)[] text() const return { return buf[0 .. len]; }
}

PerfId performanceId(const(char)[] ritual, long unixSeconds) {
    PerfId p;
    foreach (c; ritual) { if (p.len < p.buf.length) p.buf[p.len++] = c; }
    if (p.len < p.buf.length) p.buf[p.len++] = '-';

    char[20] digits = 0;
    size_t d;
    auto v = unixSeconds;
    if (v <= 0) digits[d++] = '0';
    while (v > 0) { digits[d++] = cast(char)('0' + v % 10); v /= 10; }
    foreach (i; 0 .. d) {
        if (p.len < p.buf.length) p.buf[p.len++] = digits[d - 1 - i];
    }
    return p;
}

Position start(const(char)[] name, size_t riteCount) {
    Position p;
    p.ritual = name;
    p.riteCount = riteCount;
    p.state = RitualState.Live;
    return p;
}

// The verdict of the rite at `current`, applied.
Position step(Position p, Verdict v) {
    if (p.state != RitualState.Live) return p;
    if (p.current >= p.riteCount) return p;

    final switch (v) {
    case Verdict.Advance:
        p.states[p.current] = RiteState.Passed;
        p.current++;
        if (p.current >= p.riteCount) p.state = RitualState.Done;
        break;
    case Verdict.Hold:
        p.states[p.current] = RiteState.Ran;
        break;
    case Verdict.Halt:
        p.states[p.current] = RiteState.Halted;
        p.state = RitualState.Halted;
        break;
    }
    return p;
}

// One character per rite. The row is legible without a decoder, and collet
// renders the line straight from it.
private immutable char[5] GLYPH = ['.', '-', '>', '+', '!'];

struct Encoded {
    char[MAX_RITES] buf = 0;
    size_t len;
    const(char)[] text() const return { return buf[0 .. len]; }
    bool opEquals(const(char)[] s) const { return text() == s; }
}

Encoded encodeStates(const Position p) {
    Encoded e;
    foreach (i; 0 .. p.riteCount) {
        if (i >= MAX_RITES) break;
        e.buf[e.len++] = GLYPH[cast(size_t) p.states[i]];
    }
    return e;
}

// A row this process cannot read is a row it must not render. Restoring is
// therefore a verdict, not a Position.
struct Restored { bool valid; Position p; }

Restored restore(const(char)[] name, size_t current,
                 const(char)[] states, RitualState st) {
    if (states.length == 0 || states.length > MAX_RITES) return Restored(false);
    if (current > states.length) return Restored(false);

    Position p;
    p.ritual = name;
    p.current = current;
    p.riteCount = states.length;
    p.state = st;

    foreach (i, c; states) {
        bool known = false;
        foreach (g, glyph; GLYPH) {
            if (c == glyph) { p.states[i] = cast(RiteState) g; known = true; break; }
        }
        if (!known) return Restored(false);
    }
    return Restored(true, p);
}

// Told as each other, these send you looking in the wrong place.
enum ResolveFail { None, NoSuchRitual, WrongProject }

struct Resolved { ResolveFail fail; size_t index; }

Resolved resolveRitual(PR)(const PR r, const(char)[] name, const(char)[] cwd) {
    import matcher : contains;
    bool sawName = false;
    foreach (i; 0 .. r.ritualCount) {
        if (r.rituals[i].name != name) continue;
        sawName = true;
        if (contains(cwd, r.rituals[i].projectPath)) return Resolved(ResolveFail.None, i);
    }
    return Resolved(sawName ? ResolveFail.WrongProject : ResolveFail.NoSuchRitual, 0);
}

// A ritual names groups; the position walks rites. The flat list is the order
// they run in and the index `goto` needs.
struct FlatRite {
    string group;
    string name;
    string cmd;
    string msg;
    int pass;
    int[8] catches;
    size_t catchCount;
    string goto_;
    string[8] keys;
    string[8] values;
    size_t valueCount;
}

struct Flattened {
    FlatRite[MAX_RITES] rites;
    size_t count;
}

Flattened flatten(PR)(const PR r, size_t ritualIdx) {
    Flattened f;
    if (ritualIdx >= r.ritualCount) return f;
    auto rit = r.rituals[ritualIdx];

    foreach (ri; 0 .. rit.refCount) {
        auto refr = rit.refs[ri];
        foreach (gi; 0 .. r.ritesCount) {
            if (r.rites[gi].name != refr.name) continue;
            auto grp = r.rites[gi];
            foreach (i; 0 .. grp.riteCount) {
                if (f.count >= MAX_RITES) return f;
                auto src = grp.rites[i];
                FlatRite fr;
                fr.group = grp.name;
                fr.name = src.name;
                fr.cmd = src.cmd;
                fr.msg = src.msg;
                fr.pass = src.pass;
                fr.catches = src.catches;
                fr.catchCount = src.catchCount;
                fr.goto_ = src.goto_;
                fr.keys = refr.keys;
                fr.values = refr.values;
                fr.valueCount = refr.valueCount;
                f.rites[f.count++] = fr;
            }
        }
    }
    return f;
}

long indexOfRite(const Flattened f, const(char)[] name) {
    foreach (i; 0 .. f.count)
        if (f.rites[i].name == name) return cast(long) i;
    return -1;
}

private immutable string[4] STATE_WORD = ["live", "done", "halted", "aborted"];

// The row on disk. Keyed on the performance; the worktree is an index.
bool writePosition(DB)(DB db, const Position p) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_bind_int64, sqlite3_stmt, SQLITE_OK, SQLITE_DONE, SQLITE_TRANSIENT;
    import exec : emitError;

    enum sql = "INSERT INTO ritual_position (id, repo, ritual, branch, worktree, current, states, state) "
        ~ "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8) ON CONFLICT(id) DO UPDATE SET "
        ~ "branch=?4, worktree=?5, current=?6, states=?7, state=?8, updated_at=CURRENT_TIMESTAMP\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) {
        emitError("ritual.write.prepare", "could not prepare the position write",
                  0, 0, "", cast(string) p.ritual, "", "", "");
        return false;
    }

    auto row = encodeStates(p);
    auto word = STATE_WORD[cast(size_t) p.state];
    sqlite3_bind_text(stmt, 1, p.id.ptr, cast(int) p.id.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, p.repo.ptr, cast(int) p.repo.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, p.ritual.ptr, cast(int) p.ritual.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, p.branch.ptr, cast(int) p.branch.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, p.worktree.ptr, cast(int) p.worktree.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 6, cast(long) p.current);
    sqlite3_bind_text(stmt, 7, row.buf.ptr, cast(int) row.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 8, word.ptr, cast(int) word.length, SQLITE_TRANSIENT);

    auto rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE) {
        emitError("ritual.write.step", "could not write the position",
                  0, rc, "", cast(string) p.ritual, "", "", "");
        return false;
    }
    return true;
}

// The latest performance of a repo, whatever state it is in. Survives the
// worktree, and survives finishing — a terminal state is the verdict, and a
// query that returns only live ones hides what you walked away to collect.
Restored readPosition(DB)(DB db, const(char)[] repo) {
    enum sql = "SELECT id, repo, ritual, branch, worktree, current, states, state "
        ~ "FROM ritual_position WHERE repo = ?1 ORDER BY updated_at DESC LIMIT 1\0";
    return readOne(db, sql, repo);
}

// The performance being done in this tree.
Restored readPositionAt(DB)(DB db, const(char)[] worktree) {
    enum sql = "SELECT id, repo, ritual, branch, worktree, current, states, state "
        ~ "FROM ritual_position WHERE worktree = ?1 ORDER BY updated_at DESC LIMIT 1\0";
    return readOne(db, sql, worktree);
}

// No row is a verdict, not an empty Position.
private Restored readOne(DB)(DB db, string sql, const(char)[] key) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_column_text, sqlite3_column_int64, sqlite3_stmt,
                SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    import exec : emitError;

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) {
        emitError("ritual.read.prepare", "could not prepare the position read",
                  0, 0, "", "", "", "", "");
        return Restored(false);
    }
    sqlite3_bind_text(stmt, 1, key.ptr, cast(int) key.length, SQLITE_TRANSIENT);

    if (sqlite3_step(stmt) != SQLITE_ROW) {
        sqlite3_finalize(stmt);
        return Restored(false);
    }

    // sqlite frees its column memory at finalize, so every text column is
    // copied out before the statement dies.
    __gshared char[80]  idBuf = 0;
    __gshared char[256] repoBuf = 0;
    __gshared char[64]  nameBuf = 0;
    __gshared char[128] branchBuf = 0;
    __gshared char[256] treeBuf = 0;
    __gshared char[MAX_RITES] rowBuf = 0;
    size_t idLen, repoLen, nameLen, branchLen, treeLen, rowLen;

    copyText(sqlite3_column_text(stmt, 0), idBuf.ptr, idBuf.length, idLen);
    copyText(sqlite3_column_text(stmt, 1), repoBuf.ptr, repoBuf.length, repoLen);
    copyText(sqlite3_column_text(stmt, 2), nameBuf.ptr, nameBuf.length, nameLen);
    copyText(sqlite3_column_text(stmt, 3), branchBuf.ptr, branchBuf.length, branchLen);
    copyText(sqlite3_column_text(stmt, 4), treeBuf.ptr, treeBuf.length, treeLen);
    auto current = cast(size_t) sqlite3_column_int64(stmt, 5);
    copyText(sqlite3_column_text(stmt, 6), rowBuf.ptr, rowBuf.length, rowLen);

    auto wordPtr = sqlite3_column_text(stmt, 7);
    RitualState st = RitualState.Live;
    bool knownWord = false;
    foreach (i, w; STATE_WORD) {
        if (colEquals(wordPtr, w)) { st = cast(RitualState) i; knownWord = true; break; }
    }
    sqlite3_finalize(stmt);

    if (!knownWord) {
        emitError("ritual.read.state", "the row names a ritual state this build does not have",
                  0, 0, "", cast(string) nameBuf[0 .. nameLen], "", "", "");
        return Restored(false);
    }

    auto r = restore(nameBuf[0 .. nameLen], current, rowBuf[0 .. rowLen], st);
    if (!r.valid) return r;
    r.p.id = idBuf[0 .. idLen];
    r.p.repo = repoBuf[0 .. repoLen];
    r.p.branch = branchBuf[0 .. branchLen];
    r.p.worktree = treeBuf[0 .. treeLen];
    return r;
}

private void copyText(const(char)* src, char* dst, size_t cap, ref size_t len) {
    len = 0;
    if (src is null) return;
    while (src[len] != 0 && len < cap) { dst[len] = src[len]; len++; }
}

private void copyCol(const(char)* src, ref char[64] dst, ref size_t len) {
    len = 0;
    if (src is null) return;
    while (src[len] != 0 && len < dst.length - 1) { dst[len] = src[len]; len++; }
}

private void copyCol(const(char)* src, ref char[MAX_RITES] dst, ref size_t len) {
    len = 0;
    if (src is null) return;
    while (src[len] != 0 && len < dst.length) { dst[len] = src[len]; len++; }
}

private bool colEquals(const(char)* src, const(char)[] s) {
    if (src is null) return false;
    foreach (i, c; s) {
        if (src[i] == 0 || src[i] != c) return false;
    }
    return src[s.length] == 0;
}

// goto. History is left alone: a rite that passed still passed, even if the
// ritual is about to walk over it again.
Position jump(Position p, size_t target) {
    if (target >= p.riteCount) return p;
    p.current = target;
    if (p.state == RitualState.Done) p.state = RitualState.Live;
    return p;
}

// The record a rite leaves behind. Without it nothing outside the ritual can
// tell that anything happened at all.
struct RiteAttrs {
    char[6144] buf = 0;
    size_t len;
    const(char)[] text() const return { return buf[0 .. len]; }
}

private void put(ref RiteAttrs a, const(char)[] s) {
    foreach (c; s) { if (a.len < a.buf.length) a.buf[a.len++] = c; }
}

// Output is whatever the command printed, so it carries anything that would
// break the row it is going into.
private void putEscaped(ref RiteAttrs a, const(char)[] s) {
    foreach (c; s) {
        if (c == '"') a.put(`\"`);
        else if (c == '\\') a.put(`\\`);
        else if (c == '\n') a.put(`\n`);
        else if (c == '\r') a.put(`\r`);
        else if (c == '\t') a.put(`\t`);
        else if (a.len < a.buf.length) a.buf[a.len++] = c;
    }
}

private void putInt(ref RiteAttrs a, int v) {
    if (v < 0) { a.put("-"); v = -v; }
    char[12] d = 0;
    size_t n;
    if (v == 0) d[n++] = '0';
    while (v > 0) { d[n++] = cast(char)('0' + v % 10); v /= 10; }
    foreach (i; 0 .. n) a.put(d[n - 1 - i .. n - i]);
}

// The verdict is spelled out rather than left to be inferred from the code —
// a reader would otherwise need the rite's pass and catch values to know what
// the number meant.
private immutable string[3] VERDICT_WORD = ["advance", "hold", "halt"];

RiteAttrs riteAttributes(const(char)[] performance, const(char)[] ritual,
                         const(char)[] rite, Verdict v, int code,
                         const(char)[] output) {
    RiteAttrs a;
    a.put(`{"performance":"`);
    a.putEscaped(performance);
    a.put(`","ritual":"`);
    a.putEscaped(ritual);
    a.put(`","rite":"`);
    a.putEscaped(rite);
    a.put(`","verdict":"`);
    a.put(VERDICT_WORD[cast(size_t) v]);
    a.put(`","code":`);
    a.putInt(code);
    a.put(`,"output":"`);
    a.putEscaped(output);
    a.put(`"}`);
    return a;
}

// One row per rite that ran. Keyed on the performance, the rite and the
// attempt, so a held rite re-run twenty times leaves twenty rows and a count
// of them is a count of attempts.
bool attestRite(DB)(DB db, const(char)[] sessionId, const Position p,
                    const(char)[] rite, Verdict v, int code,
                    const(char)[] output, long unixSeconds) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_stmt, SQLITE_OK, SQLITE_DONE, SQLITE_TRANSIENT,
                formatTimestamp, versionString, ZBuf;
    import exec : emitError;

    enum sql = "INSERT OR REPLACE INTO attestations "
        ~ "(id, subjects, predicates, contexts, actors, timestamp, source, attributes) "
        ~ "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)\0";

    __gshared ZBuf idBuf, subjBuf, ctxBuf, srcBuf;
    idBuf.reset();
    idBuf.put("ritual:rite:");
    idBuf.put(p.id);
    idBuf.put(":");
    idBuf.put(rite);
    idBuf.put(":");
    {
        char[24] d = 0;
        size_t n;
        auto t = unixSeconds < 0 ? 0 : unixSeconds;
        if (t == 0) d[n++] = '0';
        while (t > 0 && n < 23) { d[n++] = cast(char)('0' + t % 10); t /= 10; }
        foreach_reverse (i; 0 .. n) idBuf.putChar(d[i]);
    }

    subjBuf.reset();
    subjBuf.put(`["`);
    subjBuf.put(p.ritual);
    subjBuf.put(`"]`);

    ctxBuf.reset();
    ctxBuf.put(`["session:`);
    ctxBuf.put(sessionId);
    ctxBuf.put(`","performance:`);
    ctxBuf.put(p.id);
    ctxBuf.put(`"]`);

    srcBuf.reset();
    srcBuf.put("ground ");
    srcBuf.put(versionString());

    auto attrs = riteAttributes(p.id, p.ritual, rite, v, code, output);
    auto ts = formatTimestamp();

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) {
        emitError("ritual.attest.prepare", "could not prepare the rite attestation",
                  0, 0, cast(string) sessionId, cast(string) rite, "", "", "");
        return false;
    }

    sqlite3_bind_text(stmt, 1, idBuf.ptr(), cast(int) idBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, subjBuf.ptr(), cast(int) subjBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, `["ritual:rite"]`.ptr, 15, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, ctxBuf.ptr(), cast(int) ctxBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, `["ground"]`.ptr, 10, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 6, ts.ptr, cast(int) ts.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 7, srcBuf.ptr(), cast(int) srcBuf.len, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 8, attrs.buf.ptr, cast(int) attrs.len, SQLITE_TRANSIENT);

    auto rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE) {
        emitError("ritual.attest.step", "could not write the rite attestation",
                  0, rc, cast(string) sessionId, cast(string) rite, "", "", "");
        return false;
    }
    return true;
}

// What an agent is told at the start of a turn.
struct Brief {
    char[1024] buf = 0;
    size_t len;
    const(char)[] text() const return { return buf[0 .. len]; }
}

private void put(ref Brief b, const(char)[] s) {
    foreach (c; s) { if (b.len < b.buf.length) b.buf[b.len++] = c; }
}

private void putNum(ref Brief b, size_t v) {
    char[20] d = 0;
    size_t n;
    if (v == 0) d[n++] = '0';
    while (v > 0) { d[n++] = cast(char)('0' + v % 10); v /= 10; }
    foreach (i; 0 .. n) b.put(d[n - 1 - i .. n - i]);
}

// A held rite reads the same as a fresh one: holding is not a failure, and an
// agent told it failed goes looking for something to fix.
Brief briefing(const Position p, const Flattened f) {
    Brief b;
    if (p.state == RitualState.Done) {
        b.put("Ritual ");
        b.put(p.ritual);
        b.put(" is done.");
        return b;
    }
    if (p.current >= f.count) return b;
    auto r = f.rites[p.current];

    if (p.state == RitualState.Halted) {
        b.put("Ritual ");
        b.put(p.ritual);
        b.put(" halted on rite ");
        b.putNum(p.current + 1);
        b.put(" of ");
        b.putNum(f.count);
        b.put(": ");
        b.put(r.name);
        b.put(".");
        return b;
    }

    b.put("Performing ritual ");
    b.put(p.ritual);
    b.put(", rite ");
    b.putNum(p.current + 1);
    b.put(" of ");
    b.putNum(f.count);
    b.put(": ");
    b.put(r.name);
    b.put(". It is met when this exits 0: ");
    b.put(r.cmd);
    if (r.msg.length > 0) {
        b.put(". ");
        b.put(r.msg);
    }
    return b;
}

// The line the operator reads back, and the one collet renders: brackets say
// where, the names say what is behind and ahead.
void printLine(const Position p, const Flattened f) {
    import core.stdc.stdio : stdout, fputs, fwrite;
    foreach (i; 0 .. f.count) {
        if (i > 0) fputs(" > ", stdout);
        bool cur = (i == p.current && p.state == RitualState.Live);
        if (cur) fputs("[", stdout);
        fwrite(f.rites[i].name.ptr, 1, f.rites[i].name.length, stdout);
        if (cur) fputs("]", stdout);
    }
    fputs("\n", stdout);
}

// ground ritual <name>. Naming it is starting it, and starting it is the only
// thing that makes any rite reachable.
int handleRitual(int argc, const(char)** argv) {
    import core.stdc.stdio : stdout, stderr, fputs, fwrite;
    import controls : allParsed;
    import db : openDb, sqlite3_close;
    import main : argLen;

    if (argc < 3) {
        fputs("usage: ground ritual <name>\n", stderr);
        return 1;
    }
    auto name = argv[2][0 .. argLen(argv[2])];

    char[1024] cwdBuf = 0;
    if (getcwd(&cwdBuf[0], cwdBuf.length) is null) {
        fputs("ground ritual: cannot read the working directory\n", stderr);
        return 1;
    }
    size_t cwdLen = 0;
    while (cwdBuf[cwdLen] != 0) cwdLen++;
    auto cwd = cwdBuf[0 .. cwdLen];

    static immutable parsed = allParsed;
    auto found = resolveRitual(parsed, name, cwd);

    if (found.fail == ResolveFail.NoSuchRitual) {
        fputs("ground ritual: no ritual named ", stderr);
        fwrite(name.ptr, 1, name.length, stderr);
        fputs("\n", stderr);
        return 1;
    }
    if (found.fail == ResolveFail.WrongProject) {
        fputs("ground ritual: ", stderr);
        fwrite(name.ptr, 1, name.length, stderr);
        fputs(" belongs to ", stderr);
        auto path = parsed.rituals[found.index].projectPath;
        fwrite(path.ptr, 1, path.length, stderr);
        fputs(", and this is not it\n", stderr);
        return 1;
    }

    auto flat = flatten(parsed, found.index);
    if (flat.count == 0) {
        fputs("ground ritual: that ritual has no rites\n", stderr);
        return 1;
    }

    import core.stdc.time : time;
    import db : getBranch;

    auto p = start(parsed.rituals[found.index].name, flat.count);
    auto pid = performanceId(p.ritual, cast(long) time(null));
    p.id = pid.text();
    p.repo = parsed.rituals[found.index].projectPath;
    p.worktree = cwd;
    p.branch = getBranch(cwd);
    if (p.branch is null) p.branch = "";

    auto db = openDb();
    if (db is null) {
        fputs("ground ritual: cannot open the ground db\n", stderr);
        return 1;
    }
    auto ok = writePosition(db, p);
    sqlite3_close(db);
    if (!ok) {
        // The GroundError reaches the db or a breadcrumb. Neither is in front
        // of somebody who just typed a command and got an empty terminal.
        fputs("ground ritual: could not write the position — see ", stderr);
        fputs("~/.local/share/ground/errors/\n", stderr);
        return 1;
    }

    printLine(p, flat);
    return 0;
}
