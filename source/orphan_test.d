module orphan_test;

import ritual : writePosition, start, byPerformanceId, Position, RitualState;
import ritual.orphan : driverGone, haltOrphans;
import lifecycle : processStarted, processEnded, pidEnded;
import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
import immediate : readImmediateMessage;

// "I dont know how to explain how serious this defect is"
// q-deploy-1791041543 stood live on SACRED from 16:04:17Z with driver 75014
// gone, and the status line drew SACRED for four hours.

static assert(driverGone(true, false, false), "never ended and the pid is gone");
static assert(driverGone(true, true, true), "ended its record with the walk still live");
static assert(!driverGone(true, false, true), "alive and walking");
static assert(!driverGone(false, false, false), "no record yet is a driver still being forked");

private sqlite3* memDb() {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    return db;
}

private Position deploying(string id) {
    auto p = start("q-deploy", 3);
    p.id = id;
    p.repo = "/teranos/QNTX";
    p.rites = "ATS,SACRED,TAGGED";
    p.current = 1;
    p.agentSession = "agent-1";
    p.parent = "parent-1";
    return p;
}

enum DEAD_PID = 75014;
enum LIVE_PID = 4242;
private bool onlyLiveAnswers(long pid) { return pid == LIVE_PID; }

unittest {
    // The driver's pid is gone and its record never ended: the walk is halted,
    // the record ended, and the agent and the parent are told which rite.
    auto db = memDb();
    assert(writePosition(db, deploying("q-deploy-1")));
    processStarted(db, "drive", DEAD_PID, 1, "q-deploy-1", "", 1000);

    size_t heard;
    long heardPid;
    auto swept = haltOrphans(db, 2000, &onlyLiveAnswers,
        (const Position p, long pid, const(char)[] said) { heard++; heardPid = pid; });

    assert(swept.halted == 1 && swept.refused == 0);
    assert(heard == 1 && heardPid == DEAD_PID);
    auto got = byPerformanceId(db, "q-deploy-1");
    assert(got.p.state == RitualState.Halted);
    assert(got.p.current == 1, "halted where it stood");
    assert(pidEnded(db, DEAD_PID), "the driver's record says it ended");

    enum want = "q-deploy-1 halted on SACRED: its driver, pid 75014, is gone, so nobody was walking it";
    assert(readImmediateMessage(db, "/tmp", "parent-1").message == want);
    assert(readImmediateMessage(db, "/tmp", "agent-1").message == want);

    auto again = haltOrphans(db, 2001, &onlyLiveAnswers,
        (const Position p, long pid, const(char)[] said) { heard++; });
    assert(again.halted == 0 && heard == 1, "halted once");
    sqlite3_close(db);
}

unittest {
    // A driver that is alive, and a performance with no driver recorded yet,
    // are left walking.
    auto db = memDb();
    assert(writePosition(db, deploying("q-deploy-2")));
    processStarted(db, "drive", LIVE_PID, 1, "q-deploy-2", "", 1000);
    assert(writePosition(db, deploying("q-deploy-3")));

    auto swept = haltOrphans(db, 2000, &onlyLiveAnswers,
        (const Position p, long pid, const(char)[] said) { assert(false, "nothing is gone"); });
    assert(swept.halted == 0);
    assert(byPerformanceId(db, "q-deploy-2").p.state == RitualState.Live);
    assert(byPerformanceId(db, "q-deploy-3").p.state == RitualState.Live);
    sqlite3_close(db);
}

unittest {
    // A driver that wrote its ending with the walk still live walks nothing.
    auto db = memDb();
    assert(writePosition(db, deploying("q-deploy-4")));
    auto rec = processStarted(db, "drive", LIVE_PID, 1, "q-deploy-4", "", 1000);
    processEnded(db, rec, "no performance by that id", 0, 1500);

    auto swept = haltOrphans(db, 2000, &onlyLiveAnswers,
        (const Position p, long pid, const(char)[] said) {});
    assert(swept.halted == 1);
    assert(byPerformanceId(db, "q-deploy-4").p.state == RitualState.Halted);
    sqlite3_close(db);
}

// Driver 75014 ended with nothing written anywhere. One that a signal ends
// writes which, and the halt says it.
import ritual.deathnote : signalName, deathNoteInto, signalIn;
static assert(signalName(15) == "SIGTERM");
static assert(signalName(1) == "SIGHUP");
static assert(signalName(2) == "SIGINT");
static assert(signalName(3) == "SIGQUIT");
static assert(signalName(99) == "", "a number with no name is said as a number");
static assert(signalIn("15\n") == 15);
static assert(signalIn("") == 0, "no note is no signal");
static assert(signalIn("x") == 0);

char[8] note(int sig)() {
    char[8] b = '.';
    deathNoteInto(sig, b[]);
    return b;
}
static assert(note!15()[0 .. 3] == "15\n");

private int termedDead(long pid) { return pid == DEAD_PID ? 15 : 0; }

unittest {
    auto db = memDb();
    assert(writePosition(db, deploying("q-deploy-6")));
    processStarted(db, "drive", DEAD_PID, 1, "q-deploy-6", "", 1000);
    const(char)[] heard;
    auto swept = haltOrphans(db, 2000, &onlyLiveAnswers,
        (const Position p, long pid, const(char)[] said) { heard = said; }, &termedDead);
    assert(swept.halted == 1);
    assert(heard == "q-deploy-6 halted on SACRED: its driver, pid 75014, was ended by signal 15 (SIGTERM)", heard);
    sqlite3_close(db);
}

unittest {
    // An ended performance is not looked at, whatever became of its driver.
    auto db = memDb();
    auto done = deploying("q-deploy-5");
    done.state = RitualState.Done;
    assert(writePosition(db, done));
    processStarted(db, "drive", DEAD_PID, 1, "q-deploy-5", "", 1000);

    auto swept = haltOrphans(db, 2000, &onlyLiveAnswers,
        (const Position p, long pid, const(char)[] said) { assert(false, "ended is ended"); });
    assert(swept.halted == 0);
    sqlite3_close(db);
}
