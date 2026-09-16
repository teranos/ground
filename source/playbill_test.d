module playbill_test;

// What a session in this project is told about the rituals that could fire.

import proto : parsePbt;
import controls : allParsed;
import playbill : cuesOf, billInto, ritualCues;

// One cue per control that names a ritual, counted from the compiled set. A
// build with no controls has none of either, which is what CI compiles.
private enum namingRituals = () {
    size_t n = 0;
    foreach (si; 0 .. allParsed.scopeCount) {
        auto sc = allParsed.scopes[si];
        foreach (ci; sc.controlStart .. sc.controlEnd)
            if (allParsed.ctrlPool[ci].ritual.length > 0) n++;
    }
    return n;
}();
static assert(ritualCues.length == namingRituals);

// A checkout with no control directories on it compiles no controls, so the
// table is empty and the count above is zero on both sides. This is CI.
static assert(cuesOf(parsePbt("")).len == 0);

enum src = `
rites deployment {
  BRANCH {
    eval: "true"
  }
  SACRED {
    eval: "true"
    to: parent
  }
}

scope {
  path: ["/teranos/QNTX", "!/teranos/QNTX-App"]
  event: "PostToolUse"
  cmd: "git push"

  control {
    name: "q-deploy"
    ritual {
      deployment
    }
  }
}
`;
enum parsed = parsePbt(src);
enum bill = cuesOf(parsed);

// One control names one ritual, so there is one cue.
static assert(bill.len == 1);
static assert(bill.cues[0].ritual == "q-deploy");
static assert(bill.cues[0].event == "PostToolUse");
static assert(bill.cues[0].cmdCount == 1);
static assert(bill.cues[0].cmds[0] == "git push");

// The rite names in the order the walk takes them, which are the names a halt
// line names. Without them SACRED arrives as a word from nowhere.
static assert(bill.cues[0].riteCount == 2);
static assert(bill.cues[0].rites[0] == "BRANCH");
static assert(bill.cues[0].rites[1] == "SACRED");

size_t drawnLen(const(char)[] cwd)() {
    char[512] buf = '.';
    return billInto(bill.cues[0 .. bill.len], cwd, buf[]);
}

char[512] drawn(const(char)[] cwd)() {
    char[512] buf = '.';
    billInto(bill.cues[0 .. bill.len], cwd, buf[]);
    return buf;
}

enum want = "q-deploy performs here on `git push` (PostToolUse): BRANCH > SACRED";
static assert(drawnLen!"/Users/x/teranos/QNTX"() == want.length);
static assert(drawn!"/Users/x/teranos/QNTX"()[0 .. want.length] == want);

// The negation belongs to the scope, so the app repo is told nothing — the
// same rule that decides whether the ritual fires decides whether it is named.
static assert(drawnLen!"/Users/x/teranos/QNTX-App"() == 0);

// Nowhere near it, nothing to say.
static assert(drawnLen!"/Users/x/other"() == 0);

// A scope with no cmd is started by the event alone, and the sentence says so
// rather than leaving an empty pair of backticks.
enum eventOnly = `
rites watch {
  LOOK {
    eval: "true"
  }
}

scope {
  path: "/abcd-nl/grove"
  event: "Stop"

  control {
    name: "vigil"
    ritual {
      watch
    }
  }
}
`;
enum eventBill = cuesOf(parsePbt(eventOnly));

size_t eventLen(const(char)[] cwd)() {
    char[512] buf = '.';
    return billInto(eventBill.cues[0 .. eventBill.len], cwd, buf[]);
}

char[512] eventDrawn(const(char)[] cwd)() {
    char[512] buf = '.';
    billInto(eventBill.cues[0 .. eventBill.len], cwd, buf[]);
    return buf;
}

enum eventWant = "vigil performs here on Stop: LOOK";
static assert(eventLen!"/x/abcd-nl/grove"() == eventWant.length);
static assert(eventDrawn!"/x/abcd-nl/grove"()[0 .. eventWant.length] == eventWant);

// A project names a path and no command, so the control under it carries the
// command. A session told the ritual performs here, and not told a push is what
// performs it, learns the deploy is something other than the push it just made.
enum onControl = `
rites deployment {
  WEB {
    eval: "true"
  }
}

project {
  origin: "teranos/QNTX"
  path: "/teranos/QNTX"

  control {
    name: "q-deploy"
    event: "PostToolUse"
    cmd: "git push"
    ritual {
      deployment
    }
  }
}
`;
enum controlBill = cuesOf(parsePbt(onControl));

static assert(controlBill.cues[0].cmdCount == 1);
static assert(controlBill.cues[0].cmds[0] == "git push");

size_t controlLen(const(char)[] cwd)() {
    char[512] buf = '.';
    return billInto(controlBill.cues[0 .. controlBill.len], cwd, buf[]);
}

char[512] controlDrawn(const(char)[] cwd)() {
    char[512] buf = '.';
    billInto(controlBill.cues[0 .. controlBill.len], cwd, buf[]);
    return buf;
}

enum controlWant = "q-deploy performs here on `git push` (PostToolUse): WEB";
static assert(controlLen!"/Users/x/teranos/QNTX"() == controlWant.length);
static assert(controlDrawn!"/Users/x/teranos/QNTX"()[0 .. controlWant.length] == controlWant);

// "we say it once during a compaction window, once, not every message"
// The mark kept the row it was first written to, so every hook after a
// compaction found the compaction newer than the mark and said the bill again.

import playbill : unsaidBillInto;
import db : sqlite3, sqlite3_open, sqlite3_close, sqlite3_exec, applySchema, SQLITE_OK;

unittest {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    static immutable bill = controlBill;
    auto cues = bill.cues[0 .. bill.len];
    enum here = "/Users/x/teranos/QNTX";
    char[512] buf;

    assert(unsaidBillInto(db, "s1", here, buf[], cues) > 0, "a session is told once");
    assert(unsaidBillInto(db, "s1", here, buf[], cues) == 0, "and not again");

    enum compact = "INSERT INTO attestations "
        ~ "(id, subjects, predicates, contexts, actors, timestamp, source, attributes) "
        ~ `VALUES ('pc1', '[]', '["PreCompact"]', '["session:s1"]', '[]', 't', 'test', '{}')` ~ "\0";
    assert(sqlite3_exec(db, compact.ptr, null, null, null) == SQLITE_OK);

    assert(unsaidBillInto(db, "s1", here, buf[], cues) > 0, "a compaction forgets it, so it is told once more");
    assert(unsaidBillInto(db, "s1", here, buf[], cues) == 0, "once per compaction window, not every message");

    sqlite3_close(db);
}
