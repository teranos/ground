module ritual.command;

import ritual.position : Position, RitualState, start, performanceId;
import ritual.resolve : Flattened, ResolveFail, resolveRitual, flatten, repoRoot, riteNames;
import ritual.run : briefing, spawnScript;
import ritual.store : writePosition;

extern (C) char* getcwd(char* buf, size_t size);

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
        auto reap = reapScript(p.id);
        if (reap.text().length > 0) runRite(reap.text(), "ritual-reap", "");
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
    import worktree : worktreePath;
    import db : ZBuf;

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

    auto flat = flatten(parsed, found.index);
    if (flat.count == 0) {
        fputs("ground ritual: that ritual has no rites\n", stderr);
        return 1;
    }

    auto projectPath = parsed.rituals[found.index].projectPath;
    auto root = repoRoot(parsed, projectPath);
    if (root.length == 0) {
        fputs("ground ritual: nothing declares where ", stderr);
        fwrite(projectPath.ptr, 1, projectPath.length, stderr);
        fputs(" is on disk\n", stderr);
        return 1;
    }

    auto p = start(parsed.rituals[found.index].name, flat.count);
    auto pid = performanceId(p.ritual, cast(long) time(null));
    p.id = pid.text();
    p.repo = projectPath;

    // The names travel with the row so collet can draw the line from it
    // alone, without the pbt.
    auto names = riteNames(flat);
    p.rites = names.text();

    // The tree is named after the performance. Nothing parses either name —
    // the row is the identity.
    auto tree = worktreePath(root, p.id);
    p.worktree = tree.text();
    p.branch = "";

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

    // The agent starts knowing what it carries: its SessionStart reads the row
    // that was just written. A background session and not print mode, so it is
    // a row in `claude agents` rather than a pid only pkill could reach.
    {
        auto brief = briefing(p, flat);
        auto script = spawnScript(root, p.id, brief.text());
        dispatchExec(cast(string) script.text(), "ritual", "", 86_400,
                     [], [], "", root, "");
    }

    // And the loop that keeps it moving while the agent works. Without this
    // the position only advances when a turn ends, which for a working agent
    // can be never.
    {
        __gshared ZBuf driver;
        driver.reset();
        driver.put("#!/usr/bin/env bash\nexec ground drive '");
        driver.put(p.worktree);
        driver.put("'\n");
        dispatchExec(cast(string) driver.slice(), "ritual-drive", "", 86_400,
                     [], [], "", root, "");
    }

    printLine(p, flat);
    fwrite(p.worktree.ptr, 1, p.worktree.length, stdout);
    fputs("\n", stdout);
    return 0;
}
