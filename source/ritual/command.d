module ritual.command;

import ritual.position : Position, RitualState, start, performanceId;
import ritual.resolve : Flattened, RiteNames, chooseRitual, flatten, repoRoot, riteNames;
import ritual.run : briefing, spawnScript;
import ritual.store : writePosition;

extern (C) char* getcwd(char* buf, size_t size);

// A Position is slices, so something has to own the text they point at and
// outlive the row being written. Held by the caller for exactly that reason.
struct Staged {
    import ritual.position : PerfId;
    import worktree : Path;
    PerfId pid;
    RiteNames names;
    Path tree;
}

// Everything a performance is before anything is written or spawned. A control
// firing one has no argv and no terminal, so this is the half both callers
// share.
Position preparePerformance(PR)(const PR parsed, size_t ritualIdx,
                                const(char)[] root, long unixSeconds,
                                ref Staged st) {
    import worktree : worktreePath, branchOf;

    auto flat = flatten(parsed, ritualIdx);
    auto p = start(parsed.rituals[ritualIdx].name, flat.count);
    if (flat.count == 0) return p;

    st.pid = performanceId(p.ritual, unixSeconds);
    p.id = st.pid.text();
    p.repo = parsed.rituals[ritualIdx].projectPath;

    // The names travel with the row so collet can draw the line from it alone,
    // without the pbt.
    st.names = riteNames(flat);
    p.rites = st.names.text();

    // The tree is named after the performance. Nothing parses either name —
    // the row is the identity.
    st.tree = worktreePath(root, p.id);
    p.worktree = st.tree.text();
    p.branch = branchOf(p.worktree);
    return p;
}

// Writes the row and nothing else. The caller decides what to spawn, because
// a person at a terminal and a control firing on a push want different things.
bool startPerformance(DB, PR)(DB db, const PR parsed, size_t ritualIdx,
                              const(char)[] root, long unixSeconds) {
    Staged st;
    auto p = preparePerformance(parsed, ritualIdx, root, unixSeconds, st);
    if (p.riteCount == 0) return false;
    return writePosition(db, p);
}

// The agent starts knowing what it carries: its SessionStart reads the row
// that was just written. A background session, so it is a row in
// `claude agents` rather than a pid only pkill could reach.
bool spawnPerformance(const Position p, const Flattened flat, const(char)[] root) {
    import exec : dispatchExec, emitError;

    auto brief = briefing(p, flat);
    auto script = spawnScript(root, p.id, brief.text(), flat.system);
    // No agent is better than a truncated one: the command that starts it
    // carries the briefing, and half a briefing is a different instruction.
    if (script.text().length == 0 || brief.over) {
        emitError("ritual.spawn.toobig",
                  brief.over
                    ? "the briefing did not fit, so the agent would have been told half a rite"
                    : "the command that starts the agent did not fit, so no agent was started",
                  0, 1, cast(string) p.agentSession, "ritual", "", "", "");
        return false;
    }
    dispatchExec(cast(string) script.text(), "ritual", "", 86_400,
                 [], [], "", root, "");
    return true;
}

// The loop that keeps it moving while the agent works. Without this the
// position only advances when a turn ends, which for a working agent can be
// never. The path is quoted rather than pasted — it is a name ground built.
void spawnDriver(const Position p, const(char)[] root) {
    import exec : dispatchExec;
    import ritual.run : SpawnScript, put, putQuoted;

    SpawnScript s;
    s.put("#!/usr/bin/env bash\nexec ground drive ");
    s.putQuoted(p.worktree);
    s.put("\n");
    if (s.text().length == 0) return;
    dispatchExec(cast(string) s.text(), "ritual-drive", "", 86_400,
                 [], [], "", root, "");
}

// A control performing one. There is no argv and no terminal, so why it did
// not start goes to the error record rather than to a stderr nobody reads.
bool performFromControl(const(char)[] ritualName, const(char)[] sessionId) {
    import controls : allParsed;
    import db : openDb, sqlite3_close;
    import core.stdc.time : time;
    import exec : emitError;

    static immutable parsed = allParsed;
    auto chosen = chooseRitual(parsed, ritualName, "");
    if (!chosen.ok) {
        emitError("ritual.control.resolve", "a control names a ritual that does not resolve",
                  0, 1, cast(string) sessionId, cast(string) ritualName, "", "", "");
        return false;
    }

    auto projectPath = parsed.rituals[chosen.ritualIdx].projectPath;
    auto root = repoRoot(parsed, projectPath);
    if (root.length == 0) {
        emitError("ritual.control.root", "nothing declares where that project is on disk",
                  0, 1, cast(string) sessionId, cast(string) ritualName, "", "", "");
        return false;
    }

    auto flat = flatten(parsed, chosen.ritualIdx);
    Staged st;
    auto p = preparePerformance(parsed, chosen.ritualIdx, root, cast(long) time(null), st);
    if (p.riteCount == 0) return false;

    // The session whose tool call fired the control is the one owed the news.
    p.parent = sessionId;

    auto db = openDb();
    if (db is null) return false;
    auto ok = writePosition(db, p);
    sqlite3_close(db);
    if (!ok) return false;

    if (!spawnPerformance(p, flat, root)) return false;
    spawnDriver(p, root);
    return true;
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

// ground abort <name>. Until this existed the only way to stop a runaway
// performance was to know the schema and write the UPDATE yourself.
int handleAbort(int argc, const(char)** argv) {
    import core.stdc.stdio : stdout, stderr, fputs, fwrite;
    import controls : allParsed;
    import db : openDb, sqlite3_close;
    import main : argLen;
    import ritual.position : RitualState, abort;
    import ritual.store : readPosition;

    if (argc < 3) {
        fputs("usage: ground abort <ritual>\n", stderr);
        return 1;
    }
    auto name = argv[2][0 .. argLen(argv[2])];

    static immutable parsed = allParsed;
    size_t idx;
    bool known = false;
    foreach (i; 0 .. parsed.ritualCount) {
        if (parsed.rituals[i].name != name) continue;
        idx = i;
        known = true;
        break;
    }

    auto db = openDb();
    if (db is null) {
        fputs("ground abort: cannot open the ground db\n", stderr);
        return 1;
    }

    // The three characters off the status line name one performance. A ritual
    // name names whichever row was written last, which is not a choice.
    import ritual.store : byHandle;
    auto found = known ? readPosition(db, parsed.rituals[idx].projectPath)
                       : byHandle(db, name);

    if (!known && !found.valid) {
        sqlite3_close(db);
        fputs("ground abort: no ritual and no live performance named ", stderr);
        fwrite(name.ptr, 1, name.length, stderr);
        fputs("\n", stderr);
        return 1;
    }
    if (!found.valid || found.p.state != RitualState.Live) {
        sqlite3_close(db);
        fputs("ground abort: nothing live to abort\n", stderr);
        return 1;
    }

    auto p = abort(found.p);
    auto ok = writePosition(db, p);
    sqlite3_close(db);

    // The row is not the performance. An agent left running keeps editing a
    // worktree and committing into a walk that ended.
    {
        import rite : runRite;
        import ritual.run : reapScript;
        import exec : emitError;
        auto reap = reapScript(p.worktree);
        if (reap.text().length > 0) {
            // An abort that leaves the agent running has aborted nothing.
            auto done = runRite(reap.text(), "ritual-reap", "");
            if (!done.ran || done.code != 0)
                emitError("ritual.reap", "the performance was aborted and its agent did not stop",
                          0, done.code, cast(string) p.parent,
                          cast(string) p.ritual, "",
                          cast(string) p.worktree, cast(string) done.output());
        }
    }
    if (!ok) {
        fputs("ground abort: could not write the position\n", stderr);
        return 1;
    }

    // The tree stays. What the rite it stopped on left behind is the reason
    // somebody aborted, and removing it removes the evidence.
    // Reached by handle, the ritual index was never resolved — find it from
    // the row, which names its own ritual.
    if (!known) {
        foreach (i; 0 .. parsed.ritualCount) {
            if (parsed.rituals[i].name != p.ritual) continue;
            idx = i;
            break;
        }
    }
    printLine(p, flatten(parsed, idx));
    fwrite(p.worktree.ptr, 1, p.worktree.length, stdout);
    fputs("\n", stdout);
    return 0;
}

// ground ritual <name>.
int handleRitual(int argc, const(char)** argv) {
    import core.stdc.stdio : stdout, stderr, fputs, fwrite;
    import core.stdc.time : time;
    import controls : allParsed;
    import db : openDb, sqlite3_close;
    import exec : dispatchExec;
    import main : argLen;
    import worktree : worktreePath, branchOf;
    import db : ZBuf;

    if (argc < 3) {
        fputs("usage: ground ritual [project] <ritual>\n", stderr);
        return 1;
    }
    auto name = argv[2][0 .. argLen(argv[2])];
    // Two words are a project and one of its rituals; one is looked up as both.
    auto second = argc > 3 ? argv[3][0 .. argLen(argv[3])] : "";

    char[1024] cwdBuf = 0;
    if (getcwd(&cwdBuf[0], cwdBuf.length) is null) {
        fputs("ground ritual: cannot read the working directory\n", stderr);
        return 1;
    }
    size_t cwdLen = 0;
    while (cwdBuf[cwdLen] != 0) cwdLen++;
    auto cwd = cwdBuf[0 .. cwdLen];

    static immutable parsed = allParsed;
    auto chosen = chooseRitual(parsed, name, second);

    // "ground should refuse if it cant resolve to a single one cleanly"
    if (!chosen.ok) {
        fputs("ground ritual: ", stderr);
        fwrite(chosen.why.ptr, 1, chosen.why.length, stderr);
        fputs(" — ", stderr);
        fwrite(name.ptr, 1, name.length, stderr);
        if (second.length > 0) {
            fputs(" ", stderr);
            fwrite(second.ptr, 1, second.length, stderr);
        }
        fputs("\n", stderr);
        return 1;
    }
    auto found = chosen;

    auto flat = flatten(parsed, found.ritualIdx);
    if (flat.count == 0) {
        fputs("ground ritual: that ritual has no rites\n", stderr);
        return 1;
    }

    auto projectPath = parsed.rituals[found.ritualIdx].projectPath;
    auto root = repoRoot(parsed, projectPath);
    if (root.length == 0) {
        fputs("ground ritual: nothing declares where ", stderr);
        fwrite(projectPath.ptr, 1, projectPath.length, stderr);
        fputs(" is on disk\n", stderr);
        return 1;
    }

    Staged st;
    auto p = preparePerformance(parsed, found.ritualIdx, root, cast(long) time(null), st);

    // The session that asked, claimed at PreToolUse. Stamped here, at row
    // creation, so a performance that ends in twenty seconds still has an
    // address to send its rite lines to.
    {
        import ritual.intent : takeIntent;
        auto owed = takeIntent(p.ritual);
        if (owed !is null) p.parent = owed;
    }

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

    if (!spawnPerformance(p, flat, root)) {
        fputs("ground ritual: the briefing or spawn command did not fit\n", stderr);
        return 1;
    }

    spawnDriver(p, root);

    printLine(p, flat);
    fwrite(p.worktree.ptr, 1, p.worktree.length, stdout);
    fputs("\n", stdout);
    return 0;
}
