module ritual.drive;

import ritual.position : RitualState;
import ritual.resolve : flatten;
import ritual.run : advance, briefing;
import ritual.store : readPositionAt;
import rite : Verdict;

extern (C) uint sleep(uint seconds);
extern (C) int access(const(char)* path, int mode);

// A tree that is not there is two different facts, and the driver ran rites
// through both of them.
enum TreeVerdict { Run, Wait, Gone }

TreeVerdict treeVerdict(bool exists, bool sawTree) {
    if (exists) return TreeVerdict.Run;
    return sawTree ? TreeVerdict.Gone : TreeVerdict.Wait;
}

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
        final switch (treeVerdict(access(argv[2], 0) == 0, sawTree)) {
        case TreeVerdict.Run:  sawTree = true; break;
        case TreeVerdict.Gone: return 0;
        case TreeVerdict.Wait: sleep(1); continue;
        }

        auto db = openDb();
        if (db is null) return 0;

        auto found = readPositionAt(db, tree);
        if (!found.valid || found.p.state != RitualState.Live) {
            auto ended = found.valid ? found.p.state : RitualState.Aborted;
            auto repo = found.valid ? found.p.repo : "";
            sqlite3_close(db);

            // Done takes its tree with it: the branch is pushed and the
            // commits are the record, so the checkout is spare. A halt keeps
            // its tree — what the rite left uncommitted is what you look at.
            if (ended == RitualState.Done && repo.length > 0) {
                import ritual.resolve : repoRoot;
                import worktree : removeWorktree;
                auto root = repoRoot(parsed, repo);
                if (root.length > 0) removeWorktree(root, tree);
            }

            // Whatever the ending, the agent stops. Done removed the tree out
            // from under one that was still running in it.
            if (found.valid && found.p.id.length > 0) {
                import rite : runRite;
                import ritual.run : reapScript;
                auto reap = reapScript(found.p.id);
                if (reap.text().length > 0) runRite(reap.text(), "ritual-reap", "");
            }
            return 0;
        }

        bool moved = false;
        foreach (i; 0 .. parsed.ritualCount) {
            if (parsed.rituals[i].name != found.p.ritual) continue;
            auto flat = flatten(parsed, i);
            auto res = advance(db, found.p.agentSession, found.p, flat, cast(long) time(null));
            if (!res.ran) break;

            // A held rite waits on the world, so asking twice a second is noise.
            nextSleep = res.verdict == Verdict.Hold ? 15 : 2;

            // A rite the agent has not met, said to the agent. Its watcher
            // delivers this as a wake — the driver otherwise notices a stall
            // every fifteen seconds and tells nobody.
            if (res.verdict == Verdict.Hold && found.p.agentSession.length > 0)
                writeNote(db, found.p.agentSession, "rite-open",
                          briefing(found.p, flat).text());

            if (res.after.current != found.p.current
                || res.after.state != RitualState.Live) {
                moved = true;
                if (found.p.agentSession.length > 0)
                    writeNote(db, found.p.agentSession, "ritual-moved",
                              briefing(res.after, flat).text());
            }

            // Every rite, not only the ones an agent's Stop answered — the
            // driver walks most of them, and walked all of them silently.
            // Only on a move: a held rite is re-run every cycle.
            if (moved) {
                import notification : riteLine;
                import ritual.delivery : deliver;
                import db : ZBuf;

                auto rite = flat.rites[found.p.current].name;
                auto line = riteLine(found.p.ritual, rite, res.verdict, "", found.p.id,
                                     flat.rites[found.p.current].mic);

                __gshared ZBuf key;
                key.reset();
                key.put("rite:");
                key.put(found.p.id);
                key.put(":");
                key.put(rite);

                // The rite says where it goes, here too. Writing to the parent
                // unconditionally is what put a `to: human` rite in the model's
                // queue while stop.d was correctly leaving it out.
                deliver(db, found.p, flat.rites[found.p.current].to,
                        key.slice(), line.text());
            }
            break;
        }

        sqlite3_close(db);
        if (moved) nextSleep = 1;
        sleep(nextSleep);
    }
}
