module ritual.drive;

import ritual.position : RitualState;
import ritual.resolve : flatten;
import ritual.run : advance, briefing;
import ritual.store : readPositionAt;
import rite : Verdict;

extern (C) uint sleep(uint seconds);
extern (C) int access(const(char)* path, int mode);

// ground drive <worktree> — the loop that keeps a performance moving. The
// watcher cannot: delivery is `exit 2`, so it dies every time it speaks, and
// an agent working a rite reaches neither a Stop nor a new watcher.
int handleDrive(int argc, const(char)** argv) {
    import core.stdc.stdio : stderr, fputs;
    import core.stdc.time : time;
    import controls : allParsed;
    import db : openDb, sqlite3_close;
    import immediate : writeNote;
    import main : argLen;

    if (argc < 3) {
        fputs("usage: ground drive <worktree>\n", stderr);
        return 1;
    }
    auto tree = argv[2][0 .. argLen(argv[2])];

    static immutable parsed = allParsed;
    uint nextSleep = 2;

    // The driver starts before the agent has made the tree, so a missing one
    // means not yet. Once seen, a missing one means gone.
    bool sawTree = false;

    for (;;) {
        if (access(argv[2], 0) == 0) sawTree = true;
        else if (sawTree) return 0;

        auto db = openDb();
        if (db is null) return 0;

        auto found = readPositionAt(db, tree);
        if (!found.valid || found.p.state != RitualState.Live) {
            sqlite3_close(db);
            return 0;
        }

        bool moved = false;
        foreach (i; 0 .. parsed.ritualCount) {
            if (parsed.rituals[i].name != found.p.ritual) continue;
            auto flat = flatten(parsed, i);
            auto res = advance(db, found.p.session, found.p, flat, cast(long) time(null));
            if (!res.ran) break;

            // A held rite waits on the world, so asking twice a second is noise.
            nextSleep = res.verdict == Verdict.Hold ? 15 : 2;

            if (res.after.current != found.p.current
                || res.after.state != RitualState.Live) {
                moved = true;
                if (found.p.session.length > 0)
                    writeNote(db, found.p.session, "ritual-moved",
                              briefing(res.after, flat).text());
            }
            break;
        }

        sqlite3_close(db);
        if (moved) nextSleep = 1;
        sleep(nextSleep);
    }
}
