module ritual.regoto;

// A ritual with a regoto keeps one performance per project; without one, every
// fire is a performance of its own.

private struct Line {
    char[256] buf = 0;
    size_t len;
    void put(const(char)[] s) { foreach (c; s) if (len < buf.length) buf[len++] = c; }
    const(char)[] text() return { return buf[0 .. len]; }
}

// Why this fire starts no performance, or null when it may. A name that
// resolves to nothing is performFromControl's to report, and a store that
// will not open is the start's.
const(char)[] secondFire(DB, PR)(DB db, auto ref const PR r, const(char)[] ritualName,
                                 const(char)[] project = "") {
    import ritual.resolve : chooseRitual;
    import ritual.store : liveOf;
    auto chosen = chooseRitual(r, ritualName, project);
    if (!chosen.ok || db is null) return null;
    auto rit = r.rituals[chosen.ritualIdx];
    if (rit.regoto.length == 0) return null;

    auto live = liveOf(db, rit.name, rit.projectPath);
    if (live is null) return null;
    __gshared Line why;
    why.len = 0;
    why.put(live);
    why.put(" is live, so no second performance of ");
    why.put(rit.name);
    why.put(" starts");
    return why.text();
}

// The walk back, as a goto takes it, with what it counted started over so
// every eval is asked again. The rites before the target keep what they were;
// from the target on, each is to be walked again. Left as they were, the rite
// that was running still drew as running beside the one the walk went to.
import ritual.position : Position;
Position rewind(Position p, size_t target) {
    import ritual.position : jump, RiteState;
    p = jump(p, target);
    p.gotos = 0;
    p.evals = 0;
    p.holds = 0;
    p.throws = 0;
    foreach (i; target .. p.riteCount) p.states[i] = RiteState.Never;
    return p;
}

// The performance as it stands now, sent to `target`. Anything may write the
// row while its tree is moved, so it is read again for every try. Null is sent.
const(char)[] sendBack(DB)(DB db, const(char)[] id, size_t target, ref Position landed,
                           bool revive = false) {
    import ritual.store : byPerformanceId, writePositionIf;
    import ritual.position : RitualState;
    long tried = -1;
    for (;;) {
        auto now = byPerformanceId(db, id);
        if (!now.valid) return "its row is gone";
        // A push that waited on the rite that ended the walk brings it back,
        // unless the operator aborted it.
        auto ended = now.p.state != RitualState.Live;
        if (ended && !(revive && now.p.state != RitualState.Aborted))
            return "it ended before it could be sent back";
        // The same revision refused twice is a store that will not write.
        if (now.p.rev == tried) return "the store would not write it";
        tried = now.p.rev;
        auto moved = rewind(now.p, target);
        moved.state = RitualState.Live;
        if (writePositionIf(db, moved, now.p.rev)) {
            landed = moved;
            return null;
        }
    }
}

// How a tree was brought onto a push. `thrown` is the fallback: the work in it
// could not be kept, and `why` is what git said when it could not.
struct Moved {
    bool ok;
    bool thrown;
    char[512] whyBuf = 0;
    size_t whyLen;
    const(char)[] why() const return { return whyBuf[0 .. whyLen]; }
    void say(const(char)[] s) { foreach (c; s) if (whyLen < whyBuf.length) whyBuf[whyLen++] = c; }
}

private struct Git {
    int status;
    char[512] outBuf = 0;
    size_t len;
    const(char)[] output() const return { return outBuf[0 .. len]; }
}

extern (C) {
    import core.stdc.stdio : FILE;
    private FILE* popen(const(char)* command, const(char)* mode);
    private int pclose(FILE* stream);
}

// One git command in the tree, with its words quoted. What it printed is kept,
// since that is the reason when it refuses.
private Git git(const(char)[] tree, const(char)[][] words) {
    import worktree : addQuoted;
    import core.stdc.stdio : fread;
    Git g;
    g.status = -1;
    __gshared char[2048] cmd = 0;
    size_t n;
    bool fits = true;
    void add(const(char)[] s) { foreach (c; s) { if (n < cmd.length - 1) cmd[n++] = c; else fits = false; } }
    add("git -C ");
    fits = addQuoted(cmd[], n, tree) && fits;
    foreach (w; words) { add(" "); fits = addQuoted(cmd[], n, w) && fits; }
    add(" 2>&1");
    cmd[n] = 0;
    if (!fits) {
        foreach (c; "the git command did not fit") g.outBuf[g.len++] = c;
        return g;
    }
    auto pipe = popen(&cmd[0], "r");
    if (pipe is null) {
        foreach (c; "git could not be run") g.outBuf[g.len++] = c;
        return g;
    }
    for (;;) {
        auto got = fread(&g.outBuf[g.len], 1, g.outBuf.length - g.len, pipe);
        if (got == 0) break;
        g.len += got;
        if (g.len >= g.outBuf.length) break;
    }
    auto st = pclose(pipe);
    g.status = (st >> 8) & 0xFF;
    return g;
}

private bool says(const(char)[] hay, const(char)[] needle) {
    import matcher : contains;
    return contains(hay, needle);
}

// "make sure nothing can interrupt the branch from being updated"
// The agent's uncommitted work is stashed, the push pulled and the work put
// back. When any of that fails the tree is set to the push and cleaned.
Moved moveTree(const(char)[] tree, const(char)[] remote, const(char)[] branch,
               const(char)[] commit) {
    Moved m;
    bool kept = true;
    bool stashed = false;

    const(char)[][5] stash = ["stash", "push", "--include-untracked", "-m", "ground regoto"];
    auto s = git(tree, stash[]);
    if (s.status != 0) { kept = false; m.say("stash: "); m.say(s.output()); }
    else stashed = !says(s.output(), "No local changes to save");

    if (kept) {
        const(char)[][5] pull = ["pull", "--no-rebase", "--no-edit", remote, branch];
        auto p = git(tree, pull[]);
        if (p.status != 0) { kept = false; m.say("pull: "); m.say(p.output()); }
    }
    if (kept && stashed) {
        const(char)[][2] pop = ["stash", "pop"];
        auto u = git(tree, pop[]);
        if (u.status != 0) { kept = false; m.say("stash pop: "); m.say(u.output()); }
    }
    if (kept) { m.ok = true; return m; }

    const(char)[][3] reset = ["reset", "--hard", commit];
    auto r = git(tree, reset[]);
    if (r.status != 0) { m.say("; reset: "); m.say(r.output()); return m; }
    const(char)[][2] clean = ["clean", "-ffdx"];
    auto c = git(tree, clean[]);
    if (c.status != 0) { m.say("; clean: "); m.say(c.output()); return m; }
    m.ok = true;
    m.thrown = true;
    return m;
}

private const(char)[] trimmed(const(char)[] s) {
    while (s.length > 0 && (s[$ - 1] == '\n' || s[$ - 1] == '\r' || s[$ - 1] == ' ')) s = s[0 .. $ - 1];
    return s;
}

// The fire that landed on a live performance. The push is kept on the row and
// left waiting: the rite in flight runs on in a tree nobody moves, and the
// driver lands the push when that rite ends. The sentence is for the pusher.
const(char)[] landOn(DB, PR)(DB db, auto ref const PR r, const(char)[] ritualName,
                             const(char)[] project, const(char)[] where,
                             const(char)[] speaker = "",
                             const(char)[] toolInput = "", const(char)[] toolOutput = "") {
    import ritual.resolve : chooseRitual;
    import ritual.store : liveOf, byPerformanceId, setPush, setLanding;
    import git : getBranch;
    import exec : emitError;

    __gshared Line said;
    said.len = 0;
    auto chosen = chooseRitual(r, ritualName, project);
    if (!chosen.ok || db is null) return null;
    auto rit = r.rituals[chosen.ritualIdx];
    auto live = liveOf(db, rit.name, rit.projectPath);
    if (live is null) return null;
    auto found = byPerformanceId(db, live);
    if (!found.valid) return null;
    auto p = found.p;

    __gshared char[64] commitBuf = 0;
    const(char)[][2] revParse = ["rev-parse", "HEAD"];
    auto head = git(where, revParse[]);
    auto commit = trimmed(head.output());
    if (head.status != 0 || commit.length == 0 || commit.length > commitBuf.length) commit = "";
    foreach (i, c; commit) commitBuf[i] = c;
    commit = commitBuf[0 .. commit.length];
    auto branch = getBranch(where);

    said.put(p.id);
    if (commit.length == 0) {
        said.put(" was not sent to ");
        said.put(rit.regoto);
        said.put(": the fire's tree has no commit");
        emitError("ritual.regoto.commit", cast(string) said.text(), 0, 1, cast(string) speaker,
                  cast(string) rit.name, "", cast(string) p.id, cast(string) where);
        return said.text();
    }
    // "because the new one should be the one that is the change"
    cast(void) setPush(db, p.id, branch is null ? "" : branch, toolInput, toolOutput);
    if (!setLanding(db, p.id, commit)) {
        said.put(" was not sent to ");
        said.put(rit.regoto);
        said.put(": the push could not be kept waiting on it");
        return said.text();
    }
    said.put(" goes to ");
    said.put(rit.regoto);
    said.put(" when the rite it is on ends");
    return said.text();
}

// "But regoto should wait for the existing rite to finish and then resolve"
// The driver's half, between rites: the tree onto the waiting push and the walk
// to the regoto rite. Null when nothing waits.
const(char)[] resolveLanding(DB, PR)(DB db, auto ref const PR r, const(char)[] perfId) {
    import ritual.resolve : chooseRitual, flatten, indexOfRite;
    import ritual.store : byPerformanceId, writePositionIf, landingOf, clearLanding, readPush;
    import ritual.position : step, RitualState;
    import ritual.delivery : deliver, PARENT;
    import rite : Verdict;
    import exec : emitError;

    auto waiting = landingOf(db, perfId);
    if (waiting.length == 0) return null;
    __gshared char[64] commitBuf = 0;
    foreach (i, c; waiting) commitBuf[i] = c;
    auto commit = commitBuf[0 .. waiting.length];

    auto found = byPerformanceId(db, perfId);
    if (!found.valid) return null;
    auto p = found.p;
    __gshared Line said;
    said.len = 0;
    said.put(p.id);

    if (p.state == RitualState.Aborted) {
        cast(void) clearLanding(db, perfId, commit);
        said.put(" was aborted, so the push that waited on it did not land");
        cast(void) deliver(db, p, PARENT, "ritual-regoto", said.text(), "");
        return said.text();
    }
    auto chosen = chooseRitual(r, p.ritual, "");
    if (!chosen.ok) {
        cast(void) clearLanding(db, perfId, commit);
        said.put(": its ritual is no longer declared, so the push that waited on it did not land");
        emitError("ritual.regoto.ritual", cast(string) said.text(), 0, 1, cast(string) p.parent,
                  cast(string) p.ritual, "", cast(string) p.id, "");
        return said.text();
    }
    auto rit = r.rituals[chosen.ritualIdx];

    auto push = readPush(db, perfId);
    auto m = moveTree(p.worktree, "origin", push.branch(), commit);
    if (!m.ok) {
        auto halted = step(p, Verdict.Halt);
        cast(void) writePositionIf(db, halted, p.rev);
        cast(void) clearLanding(db, perfId, commit);
        said.put(" halted: its tree could not be brought onto the push: ");
        said.put(m.why());
        emitError("ritual.regoto.tree", "a regoto could not bring the performance's tree onto the push",
                  0, 1, cast(string) p.parent, cast(string) rit.name, "", cast(string) p.id,
                  cast(string) m.why());
        cast(void) deliver(db, p, PARENT, "ritual-regoto", said.text(), "");
        return said.text();
    }

    auto flat = flatten(r, chosen.ritualIdx);
    auto target = indexOfRite(flat, rit.regoto);
    Position moved;
    auto refused = sendBack(db, p.id, target < 0 ? 0 : cast(size_t) target, moved, true);
    cast(void) clearLanding(db, perfId, commit);
    if (refused !is null) {
        said.put(" was not sent to ");
        said.put(rit.regoto);
        said.put(": ");
        said.put(refused);
        emitError("ritual.regoto.write", cast(string) said.text(),
                  0, 1, cast(string) p.parent, cast(string) rit.name, "", cast(string) p.id,
                  cast(string) refused);
        cast(void) deliver(db, p, PARENT, "ritual-regoto", said.text(), "");
        return said.text();
    }
    said.put(" went to ");
    said.put(rit.regoto);
    said.put(" at ");
    said.put(commit[0 .. commit.length < 7 ? commit.length : 7]);
    if (m.thrown) {
        said.put(", its tree thrown away onto the push: ");
        said.put(m.why());
    } else said.put(", the work in its tree kept");
    cast(void) deliver(db, moved, PARENT, "ritual-regoto", said.text(), "");
    return said.text();
}
