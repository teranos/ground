module costgated_test;

// "costgated: w<70;f<30; {"

import proto : parsePbt;
import costgate : holds, Spent, Gate;
import ritual : advance, flatten, start, Position, RiteState;
import rite : Verdict;
import db : sqlite3, sqlite3_open, sqlite3_close, sqlite3_exec, applySchema, SQLITE_OK;

enum src = `
rites orchard {
  APPLE {
    eval: "test -f WILLOW.md"
  }

  costgated: w<70;f<30; {
    CHERRY {
      run: "exit 4"
    }

    MANGO {
      eval: "grep -qxF '  - MANGO' WILLOW.md"
    }
  }
}

project {
  path: "/abcd-nl/grove"
  ritual willow {
    orchard
  }
}
`;
enum parsed = parsePbt(src);

// The gated rites stand in the block, in the order written, after what stands before them.
static assert(parsed.ritesCount == 1);
static assert(parsed.rites[0].riteCount == 3);
static assert(parsed.rites[0].rites[0].name == "APPLE");
static assert(parsed.rites[0].rites[1].name == "CHERRY");
static assert(parsed.rites[0].rites[1].run == "exit 4");
static assert(parsed.rites[0].rites[2].name == "MANGO");
static assert(parsed.rites[0].rites[2].eval == "grep -qxF '  - MANGO' WILLOW.md");

// Each carries its gate; the one outside it carries none.
static assert(parsed.rites[0].rites[0].costgate == "");
static assert(parsed.rites[0].rites[1].costgate == "w<70;f<30;");
static assert(parsed.rites[0].rites[2].costgate == "w<70;f<30;");

// w is the Claude Code week, f is Fable's, each in tenths of a percent as ground.db keeps them.
private Spent at(long w, long f, string window) {
    return Spent(true, window == "seven_day" ? w : f);
}

// Under both, the rites apply.
static assert(holds("w<70;f<30;", (string window) => at(690, 290, window)).gate == Gate.Holds);

// The week at 70% or over: they do not.
static assert(holds("w<70;f<30;", (string window) => at(700, 0, window)).gate == Gate.Spent);
static assert(holds("w<70;f<30;", (string window) => at(700, 0, window)).letter == 'w');

// Fable's week at 30% or over: they do not.
static assert(holds("w<70;f<30;", (string window) => at(0, 300, window)).gate == Gate.Spent);
static assert(holds("w<70;f<30;", (string window) => at(0, 300, window)).letter == 'f');

// Nothing current recorded is neither under a limit nor over it.
static assert(holds("w<70;f<30;", (string window) => Spent(false, 0)).gate == Gate.Unknown);
static assert(holds("w<70;f<30;", (string window) => Spent(false, 0)).missing == "seven_day");

// The walk.

enum flat = flatten(parsed, 0);

private sqlite3* spent(string weeks) {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    if (weeks.length > 0) assert(sqlite3_exec(db, weeks.ptr, null, null, null) == SQLITE_OK);
    return db;
}

// A week that resets long after the test runs.
enum underBoth = "INSERT INTO usage (window, used_percentage, resets_at, seen_at, session) VALUES "
    ~ "('seven_day', '69.9', 4102444800, 1, 's'), ('fable_week', '29.9', 4102444800, 1, 's')\0";
enum weekOver = "INSERT INTO usage (window, used_percentage, resets_at, seen_at, session) VALUES "
    ~ "('seven_day', '72', 4102444800, 1, 's'), ('fable_week', '10', 4102444800, 1, 's')\0";
enum fableOver = "INSERT INTO usage (window, used_percentage, resets_at, seen_at, session) VALUES "
    ~ "('seven_day', '10', 4102444800, 1, 's'), ('fable_week', '31', 4102444800, 1, 's')\0";

private Position onCherry() {
    auto p = start("willow", flat.count);
    p.id = "willow-1";
    p.repo = "/abcd-nl/grove";
    p.worktree = "/tmp";
    p.parent = "parent-session";
    p.branch = "willow-branch";
    p.current = 1;
    return p;
}

unittest {
    // Under both: CHERRY applies, and its run halts the walk as any failed run does.
    auto db = spent(underBoth);
    auto r = advance(db, "sess", onCherry(), flat, 100);
    assert(r.ran);
    assert(r.verdict == Verdict.Halt);
    sqlite3_close(db);
}

unittest {
    // The week over 70%: CHERRY does not apply, nothing of it runs, and the walk is on MANGO.
    auto db = spent(weekOver);
    auto r = advance(db, "sess", onCherry(), flat, 100);
    assert(!r.ran);
    assert(r.verdict == Verdict.Advance);
    assert(r.after.current == 2);
    assert(r.after.states[1] == RiteState.Passed);
    assert(r.output == "CHERRY is not applied: w is at 72.0%, not under 70%", r.output);
    sqlite3_close(db);
}

unittest {
    // Fable's week over 30%: the same.
    auto db = spent(fableOver);
    auto r = advance(db, "sess", onCherry(), flat, 100);
    assert(!r.ran);
    assert(r.after.current == 2);
    assert(r.output == "CHERRY is not applied: f is at 31.0%, not under 30%", r.output);
    sqlite3_close(db);
}

unittest {
    // Nothing current recorded: the gate cannot be asked, which is an error, and the walk halts on CHERRY.
    import ritual : RitualState;
    auto db = spent("");
    auto r = advance(db, "sess", onCherry(), flat, 100);
    assert(r.verdict == Verdict.Halt);
    assert(r.after.state == RitualState.Halted);
    assert(r.after.current == 1);
    sqlite3_close(db);
}
