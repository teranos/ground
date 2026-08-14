module control_ritual_test;

// A control that performs a ritual. The scope says when — path, event, cmd —
// and the control says which ritual. Nothing types `ground ritual` for this.

import proto : parsePbt;
import ritual : flatten;

enum src = `
scope {
  path:  "/sbvh-nl/grove"
  event: "PostToolUse"
  cmd:   "echo ritual-of-control"

  control {
    name: "ritual-of-control"

    ritual {
      system: "You do the one thing the rite names."

      obedience
    }
  }
}

rites obedience {
  MARK  { eval: ` ~ "`test -s CONTROL.md`" ~ `  to: parent  msg: "Write it." }
  CLEAR { run:  ` ~ "`rm -f CONTROL.md`" ~ `    to: parent  mic: "Cleared." }
}
`;
enum parsed = parsePbt(src);

// The control names what it performs. An inline body is registered under the
// control's own name, so nothing needs a second name to refer to it.
private enum ctrl = parsed.ctrlPool[parsed.scopes[0].controlStart];
static assert(ctrl.name == "ritual-of-control");
static assert(ctrl.ritual == "ritual-of-control");

// The scope is what locates it. An inline ritual has no project block, so the
// one place left that says where it performs is the path it fired under.
private enum idx = () {
    foreach (i; 0 .. parsed.ritualCount)
        if (parsed.rituals[i].name == "ritual-of-control") return cast(long) i;
    return -1L;
}();
static assert(idx >= 0, "an inline ritual is registered like a named one");
static assert(parsed.rituals[cast(size_t) idx].projectPath == "/sbvh-nl/grove");

// It flattens like any other, so the walk that runs it is the walk that
// already exists.
private enum flat = flatten(parsed, cast(size_t) idx);
static assert(flat.count == 2);
static assert(flat.rites[0].name == "MARK");
static assert(flat.rites[1].name == "CLEAR");
static assert(flat.system == "You do the one thing the rite names.");

// Everything a performance needs before anything is written or spawned. A
// control has no terminal to print to and no argv, so this is the half of
// `ground ritual` that both callers share.
import ritual : preparePerformance, Staged, RitualState;

private enum root = "/home/u/src/grove";

// The caller holds the buffers. Measured on the first live fire: with them
// local to preparePerformance, the row was written with an empty id and an
// empty worktree — every slice pointing at a dead stack frame.
unittest {
    Staged st;
    auto p = preparePerformance(parsed, cast(size_t) idx, root, 1000, st);

    assert(p.ritual == "ritual-of-control");
    assert(p.id == "ritual-of-control-1000");
    assert(p.repo == "/sbvh-nl/grove");
    assert(p.rites == "MARK,CLEAR");
    assert(p.riteCount == 2);
    assert(p.state == RitualState.Live);

    // The tree is named after the performance, beside the repo it belongs to.
    assert(p.worktree == "/home/u/src/grove-ritual-of-control-1000");
    assert(p.branch == "grove-ritual-of-control-1000");
}

// A scope naming two paths says when the control fires, not where a ritual
// performs. Refused at compile time rather than guessed at on a push.
enum twoPaths = `
rites obedience { MARK { eval: "true" } }

scope {
  path:  ["/sbvh-nl/grove", "/QNTX"]
  event: "PostToolUse"

  control {
    name: "two-paths"
    ritual { obedience }
  }
}
`;
static assert(!__traits(compiles, { enum bad = parsePbt(twoPaths); }));

// A negated path is a place a ritual must not be, which resolves to nowhere.
enum negated = `
rites obedience { MARK { eval: "true" } }

scope {
  path:  "!/ground"
  event: "PostToolUse"

  control {
    name: "negated"
    ritual { obedience }
  }
}
`;
static assert(!__traits(compiles, { enum bad = parsePbt(negated); }));

// Starting one without the CLI. A control has no terminal, so failure is a
// return value here rather than a line on stderr.
import ritual : startPerformance, readPosition;
import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;

private sqlite3* memDb() {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    return db;
}

unittest {
    auto db = memDb();
    assert(startPerformance(db, parsed, cast(size_t) idx, root, 1000));

    // The row is the performance. Nothing typed `ground ritual` for this one.
    auto got = readPosition(db, "/sbvh-nl/grove");
    assert(got.valid);
    assert(got.p.id == "ritual-of-control-1000");
    assert(got.p.state == RitualState.Live);
    assert(got.p.rites == "MARK,CLEAR");
    sqlite3_close(db);
}

// A control that names one instead of carrying one resolves the same way
// `ground ritual <name>` does.
enum namedSrc = `
rites obedience {
  MARK { eval: "true" }
}

project {
  path: "/sbvh-nl/grove"
  ritual elsewhere { obedience }
}

scope {
  path:  "/QNTX"
  event: "PostToolUse"
  cmd:   "git push"

  control {
    name:   "qntx-landed"
    ritual: "elsewhere"
  }
}
`;
enum namedParsed = parsePbt(namedSrc);
static assert(namedParsed.ctrlPool[namedParsed.scopes[0].controlStart].ritual == "elsewhere");
