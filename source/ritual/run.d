module ritual.run;

import rite : Verdict;
import ritual.position : Position, RitualState, MAX_GOTOS, step, jump;
import ritual.resolve : Flattened, indexOfRite;
import ritual.record : attestRite;
import ritual.store : writePosition;

// One rite, run and recorded, and the position it leaves behind.
struct Advanced {
    bool ran;
    Verdict verdict;
    int code;
    const(char)[] output;
    Position after;
}

// The sequence nothing performed until now: read where we are, run that rite,
// read its code as one of three answers, write it down, move.
Advanced advance(DB)(DB db, const(char)[] sessionId, Position p,
                     const Flattened f, long unixSeconds) {
    import rite : prepareRite, runRite, classify;
    import exec : emitError;

    Advanced a;
    a.after = p;
    if (p.state != RitualState.Live) return a;
    if (p.current >= f.count) return a;

    auto r = f.rites[p.current];
    auto prepared = prepareRite(r, p.worktree,
                                r.keys[0 .. r.valueCount], r.values[0 .. r.valueCount]);
    if (!prepared.ready) {
        emitError("ritual.rite.unresolved", "the rite still holds a placeholder no project env resolves",
                  0, 0, cast(string) sessionId, cast(string) r.name, "",
                  cast(string) prepared.cmd, "");
        return a;
    }

    auto run = runRite(prepared.script.text(), cast(string) r.name, cast(string) sessionId);
    if (!run.ran) return a;

    a.ran = true;
    a.code = run.code;
    a.output = run.output();
    a.verdict = classify(run.code, r);

    // A cycle that cannot be taken again is a halt, not a hold — holding
    // would leave the performance waiting on a jump it will never make.
    bool wantsJump = a.verdict == Verdict.Hold && r.goto_.length > 0;
    if (wantsJump && p.gotos >= MAX_GOTOS) {
        a.verdict = Verdict.Halt;
        a.output = "goto taken 16 times, which is the most one performance gets";
        wantsJump = false;
    }

    attestRite(db, sessionId, p, r.name, a.verdict, run.code, a.output, unixSeconds);

    auto moved = step(p, a.verdict);

    // goto is what a caught code does when the rite names somewhere to go.
    if (wantsJump) {
        auto target = indexOfRite(f, r.goto_);
        if (target >= 0) {
            moved = jump(moved, cast(size_t) target);
            moved.gotos = p.gotos + 1;
        }
    }

    // A rite that passed and changed the tree gets a commit, so the branch
    // history is the walk. Only on Advance: a halt's changes are unreviewed
    // and a hold has not finished doing whatever it is doing.
    if (a.verdict == Verdict.Advance && p.worktree.length > 0) {
        import rite : runRite;
        auto c = commitScript(p.worktree, p.ritual, r.name);
        runRite(c.text(), cast(string) r.name, cast(string) sessionId);
    }

    writePosition(db, moved);

    // The last rite passed. Push the branch and open the thing you merge.
    if (moved.state == RitualState.Done && moved.worktree.length > 0) {
        import rite : runRite;
        import exec : emitError;
        auto pr = prScript(moved.worktree, moved.ritual, moved.id);
        auto out_ = runRite(pr.text(), "ritual-pr", cast(string) sessionId);
        if (!out_.ran || out_.code != 0) {
            emitError("ritual.pr", "the performance finished but its branch did not become a pull request",
                      0, out_.code, cast(string) sessionId, cast(string) moved.ritual, "",
                      cast(string) out_.output(), "");
        }
    }

    a.after = moved;
    return a;
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
    // The rite declares its own pass code. Saying 0 when the rite passes on 1
    // tells the agent the inverse of the condition, and it acts on that.
    b.put(". It is met when this exits ");
    b.putNum(cast(size_t) r.pass);
    b.put(": ");
    b.put(r.cmd);
    if (r.msg.length > 0) {
        b.put(". ");
        b.put(r.msg);
    }
    return b;
}

// The command that starts the agent. -w names the tree and ground's own
// WorktreeCreate handler places it, so the path is known before it exists.
struct SpawnScript {
    char[8192] buf = 0;
    size_t len;
    const(char)[] text() const return { return buf[0 .. len]; }
    void add(const(char)[] t) { foreach (c; t) { if (len < buf.length) buf[len++] = c; } }
}

package void put(ref SpawnScript s, const(char)[] t) {
    foreach (c; t) { if (s.len < s.buf.length) s.buf[s.len++] = c; }
}

private void putQuoted(ref SpawnScript s, const(char)[] v) {
    s.put("'");
    foreach (c; v) {
        if (c == '\'') s.put(`'\''`);
        else if (s.len < s.buf.length) s.buf[s.len++] = c;
    }
    s.put("'");
}

// Ground commits, not the agent: a record the agent writes is a record the
// agent can skip. The staged-and-quiet line means a rite that changed nothing
// leaves no commit, so a walk over an unchanged tree is not empty commits.
SpawnScript commitScript(const(char)[] tree, const(char)[] ritual, const(char)[] rite) {
    SpawnScript s;
    s.put("#!/usr/bin/env bash\nset -euo pipefail\ncd ");
    s.putQuoted(tree);
    s.put("\ngit add -A\n");
    s.put("git diff --cached --quiet && exit 0\n");
    s.put("git commit -q -m ");

    SpawnScript msg;
    msg.put(ritual);
    msg.put(": ");
    msg.put(rite);
    s.putQuoted(msg.text());
    s.put("\n");
    return s;
}

// What a performance ends in. Only on Done — a halt is not something to
// merge, and its branch is left where it stopped.
SpawnScript prScript(const(char)[] tree, const(char)[] ritual, const(char)[] id) {
    SpawnScript s;
    s.put("#!/usr/bin/env bash\nset -euo pipefail\ncd ");
    s.putQuoted(tree);
    s.put("\ngit push -q -u origin HEAD\n");
    s.put("gh pr create --title ");

    SpawnScript title;
    title.put(ritual);
    title.put(": ");
    title.put(id);
    s.putQuoted(title.text());
    s.put(" --body 'Performed by ground.'\n");
    return s;
}

SpawnScript spawnScript(const(char)[] root, const(char)[] treeName, const(char)[] prompt) {
    SpawnScript s;
    s.put("#!/usr/bin/env bash\nset -euo pipefail\ncd ");
    s.putQuoted(root);
    s.put("\nclaude -w ");
    s.putQuoted(treeName);
    s.put(" -p ");
    s.putQuoted(prompt);
    s.put("\n");
    return s;
}
