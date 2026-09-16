module usagecmd_test;

// "i expected to see soemthing like this initially"
// "so that's three bars"
// "we always show the week"

import usagecmd : parseTenths, putBar, putBarMissing, putReset, putMarker,
                  putWeekHeader, putGrid, putPlan, Reading;

struct Sink {
    char[4096] data = 0;
    size_t len;
    void put(const(char)[] s) { foreach (c; s) if (len < data.length) data[len++] = c; }
    const(char)[] slice() const return { return data[0 .. len]; }
}

// The percentage is recorded as the text Claude Code sent, read to tenths.
static assert(parseTenths("94.0") == 940);
static assert(parseTenths("23.5") == 235);
static assert(parseTenths("7") == 70);
static assert(parseTenths("100") == 1000);
static assert(parseTenths("12.34") == 123);
static assert(parseTenths("0.0") == 0);

// Wed 2026-09-16 15:45 UTC, the week resetting at 21:00 that day.
enum NOW = 1789573500;
enum WEEK_END = 1789592400;

static assert(() { Sink s; putReset(s, WEEK_END, NOW, 0); return s.slice() == "resets today 21:00"; }());
static assert(() { Sink s; putReset(s, 1789578600, NOW, 0); return s.slice() == "resets today 17:10"; }());
static assert(() { Sink s; putReset(s, 1789678800, NOW, 0); return s.slice() == "resets Thu 21:00"; }());
// A reading whose window has already reset says so rather than a time gone by.
// It has to fit the column: longer than that and every bar on the row shifts.
static assert(() { Sink s; putReset(s, 1789570000, NOW, 0); return s.slice() == "reset, no reading yet"; }());

static assert(() {
    Sink s;
    putBar(s, "Current session", 230, "reset, no reading yet");
    return s.slice() == "Current session   reset, no reading yet ██████░░░░░░░░░░░░░░░░░░░░░░   23% used\n";
}());

// The bars.
static assert(() {
    Sink s;
    putBar(s, "This week", 940, "resets today 21:00");
    return s.slice() == "This week         resets today 21:00    ██████████████████████████░░   94% used\n";
}());
static assert(() {
    Sink s;
    putBar(s, "Current session", 400, "resets today 17:10");
    return s.slice() == "Current session   resets today 17:10    ███████████░░░░░░░░░░░░░░░░░   40% used\n";
}());
static assert(() {
    Sink s;
    putBar(s, "Fable this week", 1000, "resets today 21:00");
    return s.slice() == "Fable this week   resets today 21:00    ████████████████████████████  100% used\n";
}());
// The plan the last ask found, above the bars. When it was asked is not what
// the line is for, and reading it took longer than it was worth.
static assert(() { Sink s; putPlan(s, true, "max", 0); return s.slice() == "Plan              max\n"; }());

// An ask that failed says how, and nothing asked says so.
static assert(() {
    Sink s;
    putPlan(s, true, "", 1);
    return s.slice() == "Plan              unknown: claude auth status exited 1\n";
}());
static assert(() { Sink s; putPlan(s, false, "", 0); return s.slice() == "Plan              no plan recorded\n"; }());

// A session Claude Code hands a frozen payload writes the same percentage for
// days. Inside one window the number only rises, so the highest reading of the
// current window is the one that is true, whatever arrived last.
unittest {
    import db : sqlite3, sqlite3_open, sqlite3_exec, sqlite3_close, applySchema, SQLITE_OK;
    import usagecmd : currentReading;

    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    enum rows = "INSERT INTO usage (window, used_percentage, resets_at, seen_at, session) VALUES "
        ~ "('seven_day', '84', 1789592400, 1789570000, 'live'), "
        ~ "('seven_day', '91', 1789592400, 1789573000, 'live'), "
        ~ "('seven_day', '59', 1789592400, 1789574000, 'frozen'), "
        ~ "('seven_day', '99', 1788987600, 1788980000, 'old')\0";
    assert(sqlite3_exec(db, rows.ptr, null, null, null) == SQLITE_OK);

    auto r = currentReading(db, "seven_day");
    assert(r.found);
    assert(r.tenths == 910, "the highest of this window, not the newest row");
    assert(r.resetsAt == 1789592400);
    assert(r.seenAt == 1789573000, "and when that reading was taken");

    // A window nothing recorded says so.
    assert(!currentReading(db, "five_hour").found);
    sqlite3_close(db);
}

// A window nothing recorded is said to be missing, not drawn empty.
static assert(() {
    Sink s;
    putBarMissing(s, "Fable this week");
    return s.slice() == "Fable this week   no reading recorded\n";
}());

// "the active day needs to be \/ pointed at"
// The marker is the four hours it is now, flush over the day letter before
// 12:00 and one column right after.
static assert(() { Sink s; putMarker(s, NOW, 0); return s.slice() == "            🏞️\n"; }());
static assert(() { Sink s; putMarker(s, 1789549200, 0); return s.slice() == "           🌇\n"; }());
static assert(() { Sink s; putMarker(s, 1789345800, 0); return s.slice() == "   🌌\n"; }());
static assert(() { Sink s; putMarker(s, 1789343940, 0); return s.slice() == "                            🌃\n"; }());
static assert(() { Sink s; putMarker(s, NOW, 7200); return s.slice() == "            🏙️\n"; }());

static assert(() {
    Sink s;
    putWeekHeader(s);
    return s.slice() == "    m   d   w   d   f   s   s\n";
}());

// Each day is three 8h slots across. A slot stands as high as the week's total
// had reached by its end: nine levels over three rows, and never lower than
// the slot before it. A reading from before the week, or after now, is not in it.
static immutable Reading[10] thisWeek = [
    Reading(1788984000, 990),
    Reading(1789030800, 112), Reading(1789059600, 224),
    Reading(1789117200, 336),
    Reading(1789203600, 448),
    Reading(1789318800, 560),
    Reading(1789376400, 672), Reading(1789405200, 784),
    Reading(1789491600, 896),
    Reading(1789577100, 1000),
];

static assert(() {
    Sink s;
    putGrid(s, thisWeek[], WEEK_END, NOW, 0);
    return s.slice() ==
          "     ░ ░░▒ ▒▒\n"
        ~ "   ▒██ ███ ██           ░░ ░░▒\n"
        ~ "   ███ ███ ██   ░▒ ▒██ ███ ███\n";
}());

// Burning through Fable in the first three days: full from Saturday evening on.
static immutable Reading[7] fable = [
    Reading(1789002000, 112), Reading(1789030800, 336), Reading(1789059600, 448),
    Reading(1789117200, 672), Reading(1789146000, 784),
    Reading(1789203600, 896), Reading(1789232400, 1000),
];

static assert(() {
    Sink s;
    putGrid(s, fable[], WEEK_END, NOW, 0);
    return s.slice() ==
          "   ███ ███ ██        ░ ░▒█ ███\n"
        ~ "   ███ ███ ██    ░ ░██ ███ ███\n"
        ~ "   ███ ███ ██  ░██ ███ ███ ███\n";
}());
