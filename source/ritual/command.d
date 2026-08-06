module ritual.command;

import ritual.position : Position, RitualState, start, performanceId;
import ritual.resolve : Flattened, ResolveFail, resolveRitual, flatten, repoRoot;
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

// ground ritual <name>.
int handleRitual(int argc, const(char)** argv) {
    import core.stdc.stdio : stdout, stderr, fputs, fwrite;
    import core.stdc.time : time;
    import controls : allParsed;
    import db : openDb, sqlite3_close;
    import exec : dispatchExec;
    import main : argLen;
    import worktree : worktreePath;

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

    // The tree is named after the performance. Nothing parses either name —
    // the row is the identity.
    auto tree = worktreePath(root, p.id);
    p.worktree = tree.text();
    p.branch = "";

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

    // The agent starts knowing what it carries: its SessionStart reads the
    // row that was just written.
    {
        auto brief = briefing(p, flat);
        auto script = spawnScript(root, p.id, brief.text());
        dispatchExec(cast(string) script.text(), "ritual", "", 86_400,
                     [], [], "", root, "");
    }

    printLine(p, flat);
    fwrite(p.worktree.ptr, 1, p.worktree.length, stdout);
    fputs("\n", stdout);
    return 0;
}
