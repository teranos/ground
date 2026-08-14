module ritual.run;

import rite : Verdict;
import ritual.position : Position, RitualState, RiteState, MAX_GOTOS, step, jump;
import ritual.resolve : Flattened, indexOfRite;
import ritual.record : attestRite;
import ritual.store : writePosition;
import receiver : Receiver;
import db : ZBuf;

// Who an error raised inside a rite is owed to. Routed to whichever of the
// four callers of `advance` happened to drive until 2026-08-10, so a rite that
// failed under the watcher told the watcher's session and nobody else.
struct Owed {
    const(char)[][3] who;
    size_t count;
    const(char)[][] all() const return { return cast(const(char)[][]) who[0 .. count]; }
}

// The causer first, then the operator, then the driver if it is neither. `to:`
// does not appear: it gates an outcome, and an error is not an outcome.
Owed owedSessions(const(char)[] agentSession, const(char)[] parent,
                  const(char)[] driver) {
    Owed o;
    // A static array, not a literal: betterC has no GC to allocate one in.
    const(char)[][3] candidates = [agentSession, parent, driver];
    foreach (one; candidates) {
        if (one.length == 0) continue;
        bool already;
        foreach (i; 0 .. o.count) if (o.who[i] == one) already = true;
        if (already) continue;
        o.who[o.count++] = one;
    }
    return o;
}

private void riteError(const Position p, const(char)[] driver, string origin,
                       string message, int code, const(char)[] rite,
                       const(char)[] cmd, const(char)[] output) {
    import exec : emitError;
    auto owed = owedSessions(p.agentSession, p.parent, driver);
    foreach (who; owed.all()) {
        emitError(origin, message, 0, code, cast(string) who,
                  cast(string) rite, "", cast(string) cmd, cast(string) output);
    }
}

// How long a rite may read as Running before another driver takes it anyway.
// A driver that dies mid-rite would otherwise park the walk forever, and
// "things either fail or pass, nothing is ever stuck".
// One rite, run and recorded, and the position it leaves behind.
struct Advanced {
    bool ran;
    bool applied;   // the write landed; another driver had not moved the row
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
        riteError(p, sessionId, "ritual.rite.unresolved",
                  "the rite still holds a placeholder no project env resolves",
                  0, r.name, prepared.cmd, "");
        return a;
    }

    // "it keeps holding the mic until ci has an outcome"
    {
        import ritual.position : takeMic;
        import ritual.store : writePositionIf;
        import mic : holder;
        auto held = takeMic(p, holder(r.wait), unixSeconds);
        // Declared with a glyph and a colour and never once written. It says a
        // rite is running and nothing reads it to decide anything: ground does
        // not refuse to act on what this row says.
        held.states[held.current] = RiteState.Running;
        if (!writePositionIf(db, held, p.rev)) return a;
        p = held;
        p.rev = p.rev + 1;
    }

    // Measured 2026-08-10 on `sun`: one review comment reached the agent 19
    // times, because the delivery key carries `rev` and a held rite re-enters
    // with a new one. A verdict is still an event; its words are not.
    import mic : wordsHash, freshWords;
    long spoken = 0;

    // "a failed run: is critical enough for us not to want to continue and
    // return the error point blanc , keep the mic" — so nothing downstream of
    // it is asked, including an eval that would have passed.
    if (r.run.length > 0) {
        import rite : prepareCmd;
        auto act = prepareCmd(r.run, p.worktree,
                              r.keys[0 .. r.valueCount], r.values[0 .. r.valueCount]);
        if (!act.ready) {
            riteError(p, sessionId, "ritual.run.unresolved",
                      "the rite's run still holds a placeholder no project env resolves",
                      0, r.name, act.cmd, "");
            return a;
        }
        auto did = runRite(act.script.text(), cast(string) r.name, cast(string) sessionId);
        if (!did.ran || did.code != 0) {
            a.ran = did.ran;
            a.code = did.code;
            a.output = did.output();
            a.verdict = Verdict.Halt;
            riteError(p, sessionId, "ritual.run",
                      "the rite's run did not succeed, so nothing it was for was asked",
                      did.code, r.name, act.cmd, a.output);
            import ritual.store : writePositionIf;
            auto stopped = step(p, Verdict.Halt);
            attestRite(db, sessionId, p, r.name, a.verdict, did.code, a.output, unixSeconds);
            cast(void) writePositionIf(db, stopped, p.rev);
            a.applied = true;
            a.after = stopped;
            return a;
        }
        // The tool succeeded and said something. That is owed now, not after
        // the eval decides: a hold sends the agent back to a rite it can only
        // act on if it has read what the tool printed.
        if (did.output().length > 0) {
            a.output = did.output();
            auto h = wordsHash(a.output);
            if (freshWords(h, spoken)) {
                spoken = h;
                riteSpeaks(db, p, p, r, Verdict.Advance, a.output, "run");
            }
        }
    }

    // A rite with a run and no eval asked nothing, so there is no code to read.
    if (r.eval.length == 0) {
        a.ran = true;
        a.verdict = Verdict.Advance;
    } else {
        auto run = runRite(prepared.script.text(), cast(string) r.name, cast(string) sessionId);
        if (!run.ran) return a;

        a.ran = true;
        a.code = run.code;
        a.output = run.output();
        a.verdict = classify(run.code, r);
    }

    // A cycle that cannot be taken again is a halt, not a hold — holding
    // would leave the performance waiting on a jump it will never make.
    bool wantsJump = a.verdict == Verdict.Hold && r.goto_.length > 0;
    if (wantsJump && p.gotos >= f.maxGoto) {
        a.verdict = Verdict.Halt;
        __gshared ZBuf spent;
        spent.reset();
        spent.put("goto taken ");
        putRev(spent, cast(long) p.gotos);
        spent.put(" times, and max_goto for this project is ");
        putRev(spent, cast(long) f.maxGoto);
        a.output = spent.slice();
        wantsJump = false;
    }

    // A halt is the outcome that needs a person, and the block message only
    // reaches the agent. This is the one path that reaches the operator.
    if (a.verdict == Verdict.Halt) {
        import rite : unreached;
        auto why = unreached(a.code)
            ? "the rite never reached its tree, so its condition did not run"
            : "the rite answered with a code it does not declare";
        riteError(p, sessionId, "ritual.rite.halt", why, a.code, r.name,
                  prepared.cmd, a.output);
    }

    auto moved = step(p, a.verdict);

    // goto is what a caught code does when the rite names somewhere to go.
    if (wantsJump) {
        auto target = indexOfRite(f, r.goto_);
        if (target >= 0) {
            moved = jump(moved, cast(size_t) target);
            moved.gotos = p.gotos + 1;
        }
    }

    // "move it into advance"
    {
        import ritual.position : takeMic;
        import mic : Mic;
        moved = takeMic(moved, moved.state == RitualState.Live ? Mic.Agent : Mic.Human,
                        unixSeconds);
    }

    // A run-only rite already spoke, above, under its own key. Saying it again
    // here is the same words twice to the same session.
    auto said = r.eval.length > 0 ? a.output : null;
    auto words = wordsHash(said);
    bool fresh = freshWords(words, spoken);

    // Claim the position before anything is recorded or committed. A driver
    // that read the row before another one moved it has run a rite whose
    // verdict is about a position that no longer exists.
    {
        import ritual.store : writePositionIf;
        a.applied = writePositionIf(db, moved, p.rev);
    }
    if (!a.applied) return a;
    moved.rev = p.rev + 1;

    attestRite(db, sessionId, p, r.name, a.verdict, a.code, a.output, unixSeconds);

    // "the outcome is what is spoken back into the mic to both the agent and
    // parent". Gated on `wait > 0 && to != None` until 2026-08-10, so a rite
    // that was not slow CI and named no receiver was answered into nothing.
    if (fresh) riteSpeaks(db, p, moved, r, a.verdict, said, "");

    // "we want to get rid of the auto commit" / "make commit be done by run:".
    // Every advancing rite used to commit whatever was in the tree. A ritual
    // that wants a commit writes one, or asks its agent and gates on finding it.

    // The position was already written by the claim above. Writing it again
    // unconditionally is what let a stale driver overwrite a winner.

    // "i want NO pr to be created if i did not set it". Done used to open one
    // here. A pbt that wants a pull request says so, in a rite, like anything
    // else ground runs.

    a.after = moved;
    return a;
}

// "  ░▓▓▏[REPONAME] [BRANCHNAME] ci all checks passed ✓"
private immutable string[3] CI_SAID =
    ["ci all checks passed ✓", "ci checks failed", "ci could not be read"];

// What every other rite is. `wait:` says a rite is slow, not that it is CI, and
// a PR comment signed `ci all checks passed ✓` is the record lying.
private immutable string[3] RITE_SAID = ["passed", "held", "halted"];

private void putRev(ref ZBuf b, long v) {
    char[20] d = 0;
    size_t n;
    if (v == 0) d[n++] = '0';
    while (v > 0) { d[n++] = cast(char)('0' + v % 10); v /= 10; }
    foreach (i; 0 .. n) b.put(d[n - 1 - i .. n - i]);
}

// The head names the run; what hangs under it is whatever the rite printed,
// which is the only place the tool's own words exist. `part` is "run" for the
// unconditional half of a rite, which speaks before the eval is even asked.
private void riteSpeaks(DB, R)(DB db, const Position p, const Position moved,
                               const R r, Verdict v, const(char)[] output,
                               const(char)[] part) {
    import ritual.delivery : deliver, both;

    // A waiting rite keeps the `ci:` namespace the gutter reads, and its key is
    // the one 46 was proven on.
    bool isCi = r.wait > 0;

    __gshared ZBuf key;
    key.reset();
    key.put(isCi ? "ci:" : "rite:");
    key.put(p.id);
    key.put(":");
    key.put(r.name);
    key.put(":");
    putRev(key, moved.rev);
    if (part.length > 0) {
        key.put(":");
        key.put(part);
    }

    __gshared ZBuf said;
    said.reset();
    said.put(p.repo);
    said.put(" ");
    said.put(p.branch);
    said.put(" ");
    if (isCi) said.put(CI_SAID[cast(size_t) v]);
    else if (part.length > 0) { said.put(r.name); said.put(" "); said.put(part); }
    else { said.put(r.name); said.put(" "); said.put(RITE_SAID[cast(size_t) v]); }
    if (output.length > 0) {
        said.put("\n");
        said.put(output);
    }

    deliver(db, moved, both(r.to, Receiver.AgentLlm), key.slice(), said.slice());
}

// What an agent is told at the start of a turn.
struct Brief {
    char[1024] buf = 0;
    size_t len;
    // The tail is what a cut takes — the eval, the msg, the mic — and the agent
    // acts on the half that arrived. Kept readable, but never silently.
    bool over;
    const(char)[] text() const return { return buf[0 .. len]; }
}

private void put(ref Brief b, const(char)[] s) {
    foreach (c; s) { if (b.len < b.buf.length) b.buf[b.len++] = c; else b.over = true; }
}

private void putNum(ref Brief b, size_t v) {
    char[20] d = 0;
    size_t n;
    if (v == 0) d[n++] = '0';
    while (v > 0) { d[n++] = cast(char)('0' + v % 10); v /= 10; }
    foreach (i; 0 .. n) b.put(d[n - 1 - i .. n - i]);
}

// Reported where a briefing is used, since the text still reads as an
// instruction and nothing about it looks partial.
bool briefTruncated(const Brief b) { return b.over; }

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
    // Being asked again is the one thing a held rite's briefing never said, so
    // an agent in a loop had no way to know it was in one.
    if (p.throws > 0) {
        b.put("x");
        b.putNum(p.throws);
    }
    // The rite declares its own pass code. Saying 0 when the rite passes on 1
    // tells the agent the inverse of the condition, and it acts on that.
    b.put(". It is met when this exits ");
    b.putNum(cast(size_t) r.pass);
    b.put(": ");
    b.put(r.eval);
    if (r.msg.length > 0) {
        b.put(". ");
        b.put(r.msg);
    }
    // "if it goes through the mic, it means both the parent and the child
    // agent would be receivers"
    if (r.mic.length > 0) {
        b.put(". ");
        b.put(r.mic);
    }
    return b;
}

// The command that starts the agent. -w names the tree and ground's own
// WorktreeCreate handler places it, so the path is known before it exists.
struct SpawnScript {
    char[8192] buf = 0;
    size_t len;
    bool over;
    // A script that did not fit is a different script: the closing quote is
    // gone and sh reads the rest as its own words. Empty is the refusal every
    // caller of reapScript already understands.
    const(char)[] text() const return { return over ? null : buf[0 .. len]; }
    void add(const(char)[] t) {
        foreach (c; t) { if (len < buf.length) buf[len++] = c; else over = true; }
    }
}

package void put(ref SpawnScript s, const(char)[] t) {
    foreach (c; t) { if (s.len < s.buf.length) s.buf[s.len++] = c; else s.over = true; }
}

package void putQuoted(ref SpawnScript s, const(char)[] v) {
    s.put("'");
    foreach (c; v) {
        if (c == '\'') s.put(`'\''`);
        else if (s.len < s.buf.length) s.buf[s.len++] = c;
        else s.over = true;
    }
    s.put("'");
}

// An ending ends the agent. The pid ground forked is the wrapper's, whose
// child is the script, whose child is the agent — so the id is the handle,
// and it appears in the agent's command line and nowhere else.
SpawnScript reapScript(const(char)[] performanceId) {
    SpawnScript s;
    if (performanceId.length == 0) return s;
    s.put("#!/usr/bin/env bash\nset -euo pipefail\npkill -f ");

    SpawnScript pat;
    pat.put("claude -w ");
    pat.put(performanceId);
    if (pat.over) s.over = true;
    s.putQuoted(pat.text());
    s.put(" || true\n");
    return s;
}

SpawnScript spawnScript(const(char)[] root, const(char)[] treeName,
                        const(char)[] prompt, const(char)[] system = "") {
    SpawnScript s;
    s.put("#!/usr/bin/env bash\nset -euo pipefail\ncd ");
    s.putQuoted(root);
    s.put("\nclaude -w ");
    s.putQuoted(treeName);
    s.put(" --bg ");
    // Appended rather than replacing: what a ritual declares is what this
    // agent additionally is, the way a CLAUDE.md is.
    if (system.length > 0) {
        s.put("--append-system-prompt ");
        s.putQuoted(system);
        s.put(" ");
    }
    s.putQuoted(prompt);
    s.put("\n");
    return s;
}
