module ritual.orphan;

// "I dont know how to explain how serious this defect is"
// A live performance whose driver is gone is walked by nobody, and nothing
// said so: q-deploy-1791041543 stood on SACRED for four hours on 2026-10-03.

import ritual.position : Position;

// Gone: the record holds a driver for the performance, and that driver ended
// or its pid does not answer. No record yet is a driver still being forked.
bool driverGone(bool recorded, bool ended, bool alive) {
    return recorded && (ended || !alive);
}

struct Swept {
    size_t halted;
    int refused;   // sqlite's code when the live rows could not be read
}

// More live performances than this at once is a store nobody is walking anyway.
enum LIVE_MAX = 32;
enum ID_MAX = 80;

// Every live performance whose driver is gone is halted where it stands, its
// driver's record ended, and its agent and parent told which rite. `gone` is
// the caller's, for what reaches past the store: sentry, and the agent's stop.
Swept haltOrphans(DB)(DB db, long now, bool function(long) alive,
                      scope void delegate(const Position p, long pid, const(char)[] said) gone,
                      int function(long pid) diedBy = null) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_column_text,
                sqlite3_stmt, SQLITE_OK, SQLITE_ROW, ZBuf;
    import lifecycle : watchingAt, processKilled;
    import ritual.store : byPerformanceId, writePositionIf;
    import ritual.position : step, RitualState;
    import ritual.delivery : deliver, PARENT;
    import notification : nthRite;
    import rite : Verdict;

    Swept swept;
    enum sql = "SELECT id FROM ritual_position WHERE state = 'live'\0";
    sqlite3_stmt* stmt;
    auto rc = sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null);
    if (rc != SQLITE_OK) {
        swept.refused = rc;
        return swept;
    }
    char[ID_MAX][LIVE_MAX] ids;
    size_t[LIVE_MAX] lens;
    size_t count;
    while (count < LIVE_MAX && sqlite3_step(stmt) == SQLITE_ROW) {
        auto t = sqlite3_column_text(stmt, 0);
        size_t n;
        if (t !is null) while (n < ID_MAX && t[n] != 0) { ids[count][n] = t[n]; n++; }
        lens[count++] = n;
    }
    sqlite3_finalize(stmt);

    foreach (i; 0 .. count) {
        auto id = ids[i][0 .. lens[i]];
        auto w = watchingAt(db, "drive", id, now);
        if (!driverGone(w.ever, w.lastEndedAt != 0, alive(w.lastPid))) continue;
        auto found = byPerformanceId(db, id);
        if (!found.valid || found.p.state != RitualState.Live) continue;
        auto p = found.p;
        // Another writer moved the row first, and the row is theirs.
        if (!writePositionIf(db, step(p, Verdict.Halt), p.rev)) continue;

        __gshared ZBuf said;
        said.reset();
        said.put(p.id);
        said.put(" halted on ");
        said.put(nthRite(p.rites, p.current));
        said.put(": its driver, pid ");
        said.putUint(cast(ulong) w.lastPid);

        // What the driver noted as it was ended, if it could note anything.
        import ritual.deathnote : signalName;
        auto sig = diedBy !is null ? diedBy(w.lastPid) : 0;
        __gshared ZBuf how;
        how.reset();
        if (sig > 0) {
            how.put("was ended by signal ");
            how.putUint(cast(ulong) sig);
            auto name = signalName(sig);
            if (name.length > 0) { how.put(" ("); how.put(name); how.put(")"); }
            said.put(", ");
            said.put(how.slice());
        } else {
            how.put("gone without a word, found so by a hook");
            said.put(", is gone, so nobody was walking it");
        }

        if (w.lastEndedAt == 0)
            processKilled(db, w.lastPid, how.slice(), now);
        cast(void) deliver(db, p, PARENT, "ritual-orphan", said.slice(), "");
        gone(p, w.lastPid, said.slice());
        swept.halted++;
    }
    return swept;
}

extern (C) private int kill(int pid, int sig);

// Signal 0 asks whether the pid exists and delivers nothing.
private bool pidAnswers(long pid) {
    return pid > 0 && kill(cast(int) pid, 0) == 0;
}

private int noted(long pid) {
    import ritual.deathnote : readDeathNote;
    return readDeathNote(pid);
}

// From a hook. The store carries the halt and the notes; sentry hears the
// error, and the agent is stopped, since its driver is not there to stop it.
void sweepOrphans(DB)(DB db) {
    import core.stdc.time : time;
    import errors : GroundError, reportQuietly;
    import ritual.run : reapNow;

    auto now = cast(long) time(null);
    auto swept = haltOrphans(db, now, &pidAnswers,
        (const Position p, long pid, const(char)[] said) {
            GroundError err;
            err.origin = "ritual.drive.gone";
            err.message = cast(string) said;
            err.exitCode = 1;
            err.sessionId = cast(string) p.parent;
            err.controlName = cast(string) p.ritual;
            err.timestamp = now;
            reportQuietly(err);
            cast(void) reapNow(p, "its driver is gone, so the performance was halted and its agent did not stop");
        }, &noted);
    if (swept.refused != 0) {
        GroundError err;
        err.origin = "ritual.drive.sweep";
        err.message = "the live performances could not be read, so a dead driver would go unseen";
        err.exitCode = swept.refused;
        err.timestamp = now;
        reportQuietly(err);
    }
}
