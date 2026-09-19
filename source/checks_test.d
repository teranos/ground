module checks_test;

// The plan ask and the version check each run when the last one is a day old.
// Each is an attestation in ground's own store, and its age is read from there.
// A copy goes to every QNTX backend a project names; its answer changes no age.

import checks : EVERY, shouldCheck, planIn, tagIn, checkBody, recordCheck, lastCheck,
                noteQntx, qntxBackends, putUptime, putStart, bootTime, uptimeIn;
import proto : parsePbt;

enum D = 86400;
enum NOW = 1789560000;

// Uptime does not matter. A day since the last check does.
static assert(EVERY == D);
static assert(shouldCheck(0, NOW, EVERY), "never checked");
static assert(!shouldCheck(NOW - D + 1, NOW, EVERY), "checked less than a day ago");
static assert(shouldCheck(NOW - D, NOW, EVERY), "a day ago is due");

// Only the plan is taken from what claude auth status prints.
static assert(planIn(`{"orgId": "org", "subscriptionType": "max"}`) == "max");
static assert(planIn(`{"loggedIn": false}`) is null);

// Only the tag is taken from GitHub's latest release.
static assert(tagIn(`{"url":"x","tag_name":"v0.20.0","name":"ground 0.20.0"}`) == "v0.20.0");
static assert(tagIn(`{"tag_name": "0.19.1"}`) == "0.19.1");
static assert(tagIn(`{"message":"Not Found"}`) is null);
static assert(tagIn("") is null);

struct Sink {
    char[1024] data = 0;
    size_t len;
    void put(const(char)[] s) { foreach (c; s) if (len < data.length) data[len++] = c; }
    const(char)[] slice() const return { return data[0 .. len]; }
}

enum H = 3600;
static assert(() { Sink s; putUptime(s, 5 * D + 8 * H + 50 * 60); return s.slice() == "up 5d 8:50"; }());
static assert(() { Sink s; putUptime(s, 7 * H + 5 * 60); return s.slice() == "up 0d 7:05"; }());

// What the session shows: the uptime, and the plan or why there is none.
enum UP = 5 * D + 8 * H + 50 * 60;
static assert(() { Sink s; putStart(s, UP, "max", 0, true); return s.slice() == "up 5d 8:50 | plan max"; }());
static assert(() {
    Sink s;
    putStart(s, UP, null, 1, true);
    return s.slice() == "up 5d 8:50 | plan unknown: claude auth status exited 1";
}());
static assert(() { Sink s; putStart(s, UP, null, 0, false); return s.slice() == "up 5d 8:50 | no plan recorded"; }());

// The kernel's boot time is in the past, and after this machine could exist.
unittest {
    import core.stdc.time : time;
    auto boot = bootTime();
    assert(boot > 1577836800, "boot time was read");
    assert(boot <= time(null), "the machine booted before now");
}

// On Linux the kernel says how long it has been up, not when it started, and
// /proc/uptime is the one file that carries it. Whole seconds are enough here.
static assert(uptimeIn("12345.67 6789.01\n") == 12345);
static assert(uptimeIn("0.42 0.10\n") == 0);
static assert(uptimeIn("980 12\n") == 980);
static assert(uptimeIn("") == -1);
static assert(uptimeIn("not a number\n") == -1);

// What QNTX is sent: the check, what it found, how the lookup exited, and when.
static assert(() {
    Sink s;
    checkBody(s, "plan", "max", 0, NOW);
    return s.slice() == `{"subjects":["plan"],"predicates":["check"],"contexts":["ground"],`
        ~ `"actors":["ground"],"attributes":{"value":"max","exit":0,"checked_at":1789560000}}`;
}());
static assert(() {
    Sink s;
    checkBody(s, "release", "", 6, NOW);
    return s.slice() == `{"subjects":["release"],"predicates":["check"],"contexts":["ground"],`
        ~ `"actors":["ground"],"attributes":{"value":"","exit":6,"checked_at":1789560000}}`;
}());

unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    assert(!lastCheck(db, "plan").found, "nothing checked yet");

    recordCheck(db, "plan", "pro", 0, NOW - 3 * D);
    recordCheck(db, "plan", "max", 0, NOW - D);
    recordCheck(db, "release", "v0.20.0", 0, NOW - 2 * D);

    // The newest of each kind, and the kinds do not see each other.
    auto plan = lastCheck(db, "plan");
    assert(plan.found);
    assert(plan.at == NOW - D);
    assert(plan.value == "max");
    assert(plan.exit == 0);

    auto rel = lastCheck(db, "release");
    assert(rel.found);
    assert(rel.at == NOW - 2 * D);
    assert(rel.value == "v0.20.0");

    // A lookup that failed is a check too: no value, and how it exited.
    recordCheck(db, "plan", null, 1, NOW);
    plan = lastCheck(db, "plan");
    assert(plan.at == NOW);
    assert(plan.value.length == 0);
    assert(plan.exit == 1);

    // QNTX's answer is written beside it and leaves the age where it was.
    assert(plan.qntxStatus == 0, "not answered yet");
    noteQntx(db, "plan", NOW, 201);
    plan = lastCheck(db, "plan");
    assert(plan.qntxStatus == 201);
    assert(plan.at == NOW);

    sqlite3_close(db);
}

// Every backend a project names, each once.
enum backendsSrc = `
project {
  path: "/a"
  qntx: "https://q.one.example"
}

project {
  path: "/b"
  qntx: "https://q.one.example"
}

project {
  path: "/c"
  qntx: "https://q.two.example"
  qntx {
    token: "~/.qntx/two"
  }
}

project {
  path: "/d"
}
`;
enum backends = qntxBackends(parsePbt(backendsSrc));
static assert(backends.len == 2);
static assert(backends.items[0].url == "https://q.one.example");
static assert(backends.items[0].token == "", "no block names no token of its own");
static assert(backends.items[1].url == "https://q.two.example");
// "no double or split config, they all need to go to the same call from the same token"
static assert(backends.items[1].token == "~/.qntx/two");
