module ritual.drive;

// BOOK_GLOSSARY **Driver**: The loop that keeps a performance moving, one per performance, forked when it starts.

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

// Only a tree ground cut is ground's to remove. A ritual that names none
// performs where the work already was, and removing that deletes a checkout
// the person is using.
bool mayRemoveTree(RitualState ended, const(char)[] declaredTree) {
    return ended == RitualState.Done && declaredTree.length > 0;
}

// Where a performance reports: the nearest dsn its ritual resolves to, or
// empty when no pbt names one.
private const(char)[] dsnOf(PR)(const ref PR parsed, const(char)[] ritual) {
    import ritual.resolve : resolveSentry;
    foreach (i; 0 .. parsed.ritualCount) {
        if (parsed.rituals[i].name != ritual) continue;
        return resolveSentry(flatten(parsed, i).sentry);
    }
    return "";
}

// How long an ending waits to learn who carried it before saying nobody did.
enum BIND_WAIT_SEC = 10;

// The driver's ending, in the record and in the outbox of the session that is
// owed the news. A driver that dies without reaching this leaves a row that
// stopped being seen, which is the fact the record exists to hold.
private void driverEnded(DB)(DB db, long record, const(char)[] owed, const(char)[] perfId,
                             const(char)[] how, long polls, long startedAt) {
    import core.stdc.time : time;
    import lifecycle : processEnded;
    import sentry : openItem;
    import outbox : leave;
    import db : ZBuf;

    auto now = cast(long) time(null);
    processEnded(db, record, how, 0, now);

    __gshared ZBuf body_;
    body_.reset();
    body_.put("driver ");
    body_.put(how);
    auto it = openItem(now, perfId, "info", body_.slice());
    it.str("kind", "drive");
    it.str("performance", perfId);
    it.num("polls", polls);
    it.num("seconds", now - startedAt);
    it.close();
    cast(void) leave(db, owed, "info", it, now);
}

// The runs this performance sent, asked after. What the watcher does for the
// parent, done here for the walk that waits on them: a run still going is
// parked until its likely end, one not yet listed is parked briefly, and an
// outcome is written onto the row so the block can close and the parent's
// watcher can hand it over without asking again.
private size_t resolveOwed(DB)(DB db, const(char)[] perfId, long now) {
    import immediate : DispatchRow, owedDispatches, resolveDispatch, parkImmediate;
    import deferred : checkRunByToken, CIQuery;
    import adaptive : pickAdaptiveSleep;
    import sky : DISPATCH_APPEAR_SEC;

    __gshared DispatchRow[8] rows;
    auto n = owedDispatches(db, perfId, now, rows[]);
    size_t found = 0;
    foreach (ref row; rows[0 .. n]) {
        if (row.repo.length == 0 || row.token.length == 0) continue;
        auto run = checkRunByToken(row.repo, row.token);
        if (run.kind == CIQuery.InProgress) {
            parkImmediate(db, row.id, now + pickAdaptiveSleep(now - row.pushTime, row.p50, row.p90));
            continue;
        }
        if (run.kind == CIQuery.NoWorkflow) {
            if (now - row.pushTime < DISPATCH_APPEAR_SEC) {
                parkImmediate(db, row.id, now + 2);
                continue;
            }
            if (resolveDispatch(db, row.id, "no run carries the name ground gave it")) found++;
            continue;
        }
        // gh not answering is not the run's outcome. Asked again later; the
        // parent's watcher still hands "could not find out" over as it does.
        if (run.kind == CIQuery.Unavailable) {
            parkImmediate(db, row.id, now + 30);
            continue;
        }
        if (resolveDispatch(db, row.id, run.text)) found++;
    }
    return found;
}

// The ending, in the word sentry is told. Live is not one.
const(char)[] endingWord(RitualState s) {
    final switch (s) {
    case RitualState.Live:    return "";
    case RitualState.Done:    return "done";
    case RitualState.Halted:  return "halted";
    case RitualState.Aborted: return "aborted";
    }
}

// ground drive <performance> — the loop that keeps a performance moving. The
// watcher cannot: delivery is `exit 2`, so it dies every time it speaks, and
// an agent working a rite reaches neither a Stop nor a new watcher.
enum BOOK_COMMAND = q"EOS
# the driver ground ritual forks, one per performance, by the performance id:
ground drive ground-coinflip-1786812152
EOS";

int handleDrive(int argc, const(char)** argv) {
    import core.stdc.stdio : stderr, fputs;
    import core.stdc.time : time;
    import controls : allParsed;
    import db : openDb, sqlite3_close, ZBuf;
    import immediate : writeNote;
    import main : argLen;
    import ritual.store : byPerformanceId;

    if (argc < 3) {
        fputs("usage: ground drive <performance>\n", stderr);
        return 1;
    }
    // The performance, not its tree: in place two of them share one checkout
    // and the tree cannot say which this drives.
    auto perfId = argv[2][0 .. argLen(argv[2])];

    static immutable parsed = allParsed;
    uint nextSleep = 2;

    // The driver starts before the agent has made the tree, so a missing one
    // means not yet. Once seen, a missing one means gone.
    bool sawTree = false;
    __gshared ZBuf treePath;

    // A driver is forked where a performance starts and nowhere else, so its
    // first live pass is the start. Sent from here and not from the fork: that
    // runs inside a hook, and a post is a network round trip.
    bool announced = false;
    size_t openRite = size_t.max;
    long openedUs;

    // The driver's own record, so an ended performance and a driver that died
    // under it are two different facts on disk.
    import lifecycle : processStarted, processSeen;
    import sky : getpid, getppid;
    long record = 0;
    long polls = 0;
    auto startedAt = cast(long) time(null);
    const(char)[] owed = "";
    {
        auto rdb = openDb();
        if (rdb !is null) {
            record = processStarted(rdb, "drive", getpid(), getppid(), perfId, "", startedAt);
            sqlite3_close(rdb);
        }
    }

    for (;;) {
        auto db = openDb();
        if (db is null) return 0;
        polls++;
        processSeen(db, record, cast(long) time(null));

        auto found = byPerformanceId(db, perfId);
        if (!found.valid) {
            driverEnded(db, record, owed, perfId, "no performance by that id", polls, startedAt);
            sqlite3_close(db);
            return 0;
        }
        owed = found.p.parent;

        treePath.reset();
        treePath.put(found.p.worktree);
        final switch (treeVerdict(access(treePath.ptr(), 0) == 0, sawTree)) {
        case TreeVerdict.Run:  sawTree = true; break;
        case TreeVerdict.Gone:
            driverEnded(db, record, owed, perfId, "the tree is gone", polls, startedAt);
            sqlite3_close(db);
            return 0;
        case TreeVerdict.Wait: sqlite3_close(db); sleep(1); continue;
        }

        if (found.p.state != RitualState.Live) {
            auto ended = found.p.state;
            auto repo = found.p.repo;
            auto tree = found.p.worktree;
            const(char)[] declaredTree = "";
            foreach (i; 0 .. parsed.ritualCount) {
                if (parsed.rituals[i].name != found.p.ritual) continue;
                declaredTree = parsed.rituals[i].tree;
                break;
            }
            sqlite3_close(db);

            // A walk can end before `ground bind` has said who carries it: the
            // bind follows the start by the time `claude --bg` takes to answer.
            // Bounded, because a start that failed never binds at all.
            {
                import ritual.run : reapTarget;
                foreach (attempt; 0 .. BIND_WAIT_SEC) {
                    if (reapTarget(found.p).length > 0) break;
                    sleep(1);
                    auto again = openDb();
                    if (again is null) break;
                    auto fresh = byPerformanceId(again, perfId);
                    sqlite3_close(again);
                    if (fresh.valid) found = fresh;
                }
            }

            // Whatever the ending, the agent stops, and before the tree goes:
            // Done removed the tree out from under one still running in it.
            import ritual.run : reapNow, REAPED_WORD;
            auto reaped = reapNow(found.p, "the performance ended and its agent did not");

            // The ending and what became of the agent, said together. The tree
            // going can still fail, and the ending happened whether it does.
            {
                import sentry : report, performanceEnvelope;
                auto dsn = dsnOf(parsed, found.p.ritual);
                report(dsn, performanceEnvelope(dsn, cast(long) time(null), found.p.id,
                                                found.p.ritual, endingWord(ended),
                                                REAPED_WORD[cast(size_t) reaped]),
                       found.p.parent, found.p.ritual);
            }

            // Done takes its tree with it: the branch is pushed and the
            // commits are the record, so the checkout is spare. A halt keeps
            // its tree — what the rite left uncommitted is what you look at.
            if (mayRemoveTree(ended, declaredTree) && repo.length > 0) {
                import ritual.resolve : repoRoot;
                import worktree : removeWorktree;
                auto root = repoRoot(parsed, repo);
                if (root.length > 0) removeWorktree(root, tree);
            }

            {
                auto edb = openDb();
                if (edb !is null) {
                    __gshared ZBuf how;
                    how.reset();
                    how.put("the performance ended ");
                    how.put(endingWord(ended));
                    how.put(", agent ");
                    how.put(REAPED_WORD[cast(size_t) reaped]);
                    driverEnded(edb, record, owed, perfId, how.slice(), polls, startedAt);
                    sqlite3_close(edb);
                }
            }
            return 0;
        }

        // Posted after the store is closed: a post is a round trip, and nothing
        // it waits on is the store's business.
        import sentry : Envelope, report, performanceEnvelope, riteEnvelope;
        auto dsn = dsnOf(parsed, found.p.ritual);
        Envelope riteSaid;
        bool riteRan = false;

        // When the walk arrived at the rite it stands on. The row does not keep
        // it, and one driver walks one performance, so it is kept here.
        import stop : usecNow;
        if (found.p.current != openRite) {
            openRite = found.p.current;
            openedUs = usecNow();
        }

        Envelope startSaid;
        bool startNow = !announced;
        if (startNow) {
            announced = true;
            startSaid = performanceEnvelope(dsn, cast(long) time(null), found.p.id,
                                            found.p.ritual, "started");
        }

        // The runs this performance sent, asked after by the process that is
        // waiting on them, rather than by a watcher that may not be there.
        cast(void) resolveOwed(db, found.p.id, cast(long) time(null));

        bool moved = false;
        foreach (i; 0 .. parsed.ritualCount) {
            if (parsed.rituals[i].name != found.p.ritual) continue;
            auto flat = flatten(parsed, i);
            auto res = advance(db, found.p.agentSession, found.p, flat, cast(long) time(null));
            if (!res.ran) break;

            // Only a verdict that landed. One another driver walked past is
            // theirs to report.
            if (res.applied) {
                import sentry : RiteReport;
                auto rite = flat.rites[found.p.current];
                RiteReport said;
                said.performance = found.p.id;
                said.ritual = found.p.ritual;
                said.rite = rite.name;
                said.verdict = res.verdict;
                said.code = res.code;
                said.pass = rite.pass;
                said.catches = rite.catches;
                said.catchCount = rite.catchCount;
                said.tookMs = res.tookUs / 1000;
                said.openMs = (usecNow() - openedUs) / 1000;
                said.evals = found.p.evals + 1;
                said.gotos = res.after.gotos;
                said.maxGoto = flat.maxGoto;
                said.jumpedTo = res.jumpedTo;
                said.gotoSpent = res.gotoSpent;
                said.evalsSpent = res.evalsSpent;
                riteRan = true;
                riteSaid = riteEnvelope(dsn, cast(long) time(null), said);
            }

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
                import notification : riteLine, riteWords;
                import ritual.delivery : deliver;
                import db : ZBuf;

                auto rite = flat.rites[found.p.current].name;
                auto line = riteLine(found.p.ritual, rite, res.verdict, "", found.p.id,
                                     riteWords(res.verdict,
                                               flat.rites[found.p.current].mic,
                                               flat.rites[found.p.current].msg),
                                     flat.rites[found.p.current].dispatch);

                // The note id is the key, so the revision keeps a rite asked
                // twice from writing the id it was already delivered under.
                import stop : putInt;
                __gshared ZBuf key;
                key.reset();
                key.put("rite:");
                key.put(found.p.id);
                key.put(":");
                key.put(rite);
                key.put(":");
                putInt(key, res.after.rev);

                // The rite says where it goes, here too. Writing to the parent
                // unconditionally is what put a `to: human` rite in the model's
                // queue while stop.d was correctly leaving it out.
                deliver(db, found.p, flat.rites[found.p.current].to,
                        key.slice(), line.text());
            }
            break;
        }

        sqlite3_close(db);
        if (startNow) report(dsn, startSaid, found.p.parent, found.p.ritual);
        if (riteRan) report(dsn, riteSaid, found.p.parent, found.p.ritual);
        if (moved) nextSleep = 1;
        sleep(nextSleep);
    }
}
