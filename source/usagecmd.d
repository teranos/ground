module usagecmd;

// "i expected to see soemthing like this initially"
// "so that's three bars"
// "we always show the week"

// The readings are what ug recorded from the status line: every four hours,
// and once for each new session.

enum BOOK_COMMAND = q"EOS
# how much of each rate limit is used, and how the week got there:
ground usage
EOS";

private void put2(S)(ref S s, long v) {
    char[2] d = [cast(char)('0' + (v / 10) % 10), cast(char)('0' + v % 10)];
    s.put(d[]);
}

private void putNum(S)(ref S s, long v) {
    char[20] d = 0;
    size_t n = 0;
    if (v == 0) d[n++] = '0';
    while (v > 0) { d[n++] = cast(char)('0' + v % 10); v /= 10; }
    foreach (i; 0 .. n) s.put(d[n - 1 - i .. n - i]);
}

// Padded to a column, and never run into the column after it.
private void padded(S)(ref S s, const(char)[] text, size_t width) {
    s.put(text);
    if (text.length >= width) { s.put(" "); return; }
    foreach (_; text.length .. width) s.put(" ");
}

// One reading of a window: when ug saw it, and how much was used, in tenths.
struct Reading {
    long seenAt;
    long tenths;
}

// The percentage as Claude Code sent it, to tenths. 23.5 is 235.
long parseTenths(const(char)[] s) {
    long whole = 0;
    long tenth = 0;
    bool dot = false;
    bool gotTenth = false;
    foreach (c; s) {
        if (c == '.') {
            if (dot) break;
            dot = true;
            continue;
        }
        if (c < '0' || c > '9') break;
        if (!dot) whole = whole * 10 + (c - '0');
        else if (!gotTenth) { tenth = c - '0'; gotTenth = true; }
    }
    return whole * 10 + tenth;
}

private long localDays(long epoch, long offset) {
    auto t = epoch + offset;
    return t >= 0 ? t / 86400 : (t - 86399) / 86400;
}

private long localSecs(long epoch, long offset) {
    return epoch + offset - localDays(epoch, offset) * 86400;
}

// Monday is 0. The first day of the epoch was a Thursday.
private size_t weekday(long days) {
    return cast(size_t)(((days % 7) + 7 + 3) % 7);
}

private static immutable string[7] DAY_NAMES = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

void putReset(S)(ref S s, long resetsAt, long now, long offset) {
    // Inside the column, or the bar on this row starts late and every row
    // beside it reads as a different measurement.
    if (resetsAt <= now) {
        s.put("reset, no reading yet");
        return;
    }
    s.put("resets ");
    auto day = localDays(resetsAt, offset);
    s.put(day == localDays(now, offset) ? "today" : DAY_NAMES[weekday(day)]);
    s.put(" ");
    auto secs = localSecs(resetsAt, offset);
    put2(s, secs / 3600);
    s.put(":");
    put2(s, (secs / 60) % 60);
}

enum BAR_WIDTH = 28;

void putBar(S)(ref S s, const(char)[] label, long tenths, const(char)[] reset) {
    padded(s, label, 18);
    padded(s, reset, 22);

    auto t = tenths < 0 ? 0 : (tenths > 1000 ? 1000 : tenths);
    auto full = t * BAR_WIDTH / 1000;
    foreach (i; 0 .. BAR_WIDTH) s.put(i < full ? "█" : "░");

    auto pct = tenths / 10;
    size_t digits = 1;
    for (long v = pct; v >= 10; v /= 10) digits++;
    foreach (_; digits .. 5) s.put(" ");
    putNum(s, pct);
    s.put("% used\n");
}

void putBarMissing(S)(ref S s, const(char)[] label) {
    padded(s, label, 18);
    s.put("no reading recorded\n");
}

// The plan the last ask found, or why it found none.
void putPlan(S)(ref S s, bool found, const(char)[] plan, long exit) {
    padded(s, "Plan", 18);
    if (!found) {
        s.put("no plan recorded\n");
        return;
    }
    if (plan.length > 0) {
        s.put(plan);
        s.put("\n");
        return;
    }
    s.put("unknown: claude auth status exited ");
    putNum(s, exit);
    s.put("\n");
}

// What a window stands at now. Claude Code hands some sessions a payload frozen
// at the value their session started on, so the newest row can be days stale.
// Inside one window the number only rises, so the highest of it is the true one.
struct Current {
    bool found;
    bool readable = true;
    long tenths;
    long seenAt;
    long resetsAt;
}

Current currentReading(DB)(DB db, const(char)[] window) {
    import db : sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_step, sqlite3_finalize,
                sqlite3_column_text, sqlite3_column_int64, sqlite3_stmt,
                SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    import profile : cstr;

    // The current window is the one the newest row names, and every row of it
    // carries the same resets_at whoever wrote it.
    enum sql = "SELECT used_percentage, seen_at, resets_at FROM usage WHERE window = ?1 "
        ~ "AND resets_at = (SELECT resets_at FROM usage WHERE window = ?1 "
        ~ "ORDER BY seen_at DESC, id DESC LIMIT 1) "
        ~ "ORDER BY CAST(used_percentage AS REAL) DESC, seen_at DESC LIMIT 1\0";

    Current c;
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) {
        c.readable = false;
        return c;
    }
    sqlite3_bind_text(stmt, 1, window.ptr, cast(int) window.length, SQLITE_TRANSIENT);
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        c.found = true;
        c.tenths = parseTenths(cstr(sqlite3_column_text(stmt, 0)));
        c.seenAt = sqlite3_column_int64(stmt, 1);
        c.resetsAt = sqlite3_column_int64(stmt, 2);
    }
    sqlite3_finalize(stmt);
    return c;
}

// "the active day needs to be \/ pointed at"
// Six four-hour blocks, two columns wide: over the day letter and the column
// before it until 12:00, over the letter and the column after it from then.
private static immutable string[6] MARKS = ["🌌", "🌄", "🌇", "🏞️", "🏙️", "🌃"];

void putMarker(S)(ref S s, long now, long offset) {
    auto secs = localSecs(now, offset);
    auto col = 4 + 4 * weekday(localDays(now, offset));
    if (secs < 12 * 3600) col--;
    foreach (_; 0 .. col) s.put(" ");
    s.put(MARKS[cast(size_t)(secs / (4 * 3600))]);
    s.put("\n");
}

void putWeekHeader(S)(ref S s) {
    s.put("    m   d   w   d   f   s   s\n");
}

private static immutable string[4] SHADES = [" ", "░", "▒", "█"];

// The week that ends at weekEnd, one column per day and three 8h slots across
// each. A slot stands as high as the week's total had reached by its end, in
// nine levels over three rows. A slot that has not begun is empty.
void putGrid(S)(ref S s, const Reading[] rs, long weekEnd, long now, long offset) {
    enum SLOT = 8 * 3600;
    auto weekStart = weekEnd - 7 * 86400;
    auto lastDay = localDays(weekEnd, offset);

    int[3][7] level;
    foreach (k; 0 .. 7) {
        auto day = lastDay - 6 + k;
        auto col = weekday(day);
        auto dayStart = day * 86400 - offset;
        foreach (j; 0 .. 3) {
            auto slotStart = dayStart + j * SLOT;
            auto slotEnd = slotStart + SLOT;
            if (slotStart > now || slotStart >= weekEnd || slotEnd <= weekStart) continue;

            long most = 0;
            foreach (r; rs)
                if (r.seenAt >= weekStart && r.seenAt < slotEnd && r.seenAt <= now && r.tenths > most)
                    most = r.tenths;
            auto l = most * 9 / 1000;
            level[col][j] = cast(int)(l > 9 ? 9 : l);
        }
    }

    foreach_reverse (row; 0 .. 3) {
        char[256] line = 0;
        size_t n = 0;
        size_t used = 0;
        void put(const(char)[] t) { foreach (c; t) if (n < line.length) line[n++] = c; }

        put("   ");
        foreach (col; 0 .. 7) {
            if (col > 0) put(" ");
            foreach (j; 0 .. 3) {
                auto v = level[col][j] - 3 * cast(int) row;
                if (v < 0) v = 0;
                if (v > 3) v = 3;
                put(SHADES[v]);
                if (v > 0) used = n;
            }
        }
        s.put(line[0 .. used]);
        s.put("\n");
    }
}

int handleUsage() {
    import core.stdc.stdio : stdout, stderr, fputs, fwrite;
    import core.stdc.time : time, localtime;
    import db : openDb, sqlite3_close, sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize,
                sqlite3_bind_text, sqlite3_bind_int64, sqlite3_column_int64, sqlite3_column_text,
                sqlite3_stmt, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    import profile : cstr;
    import zbuf : ZBuf;

    auto db = openDb();
    if (db is null) {
        fputs("ground usage: cannot open the ground db\n", stderr);
        return 1;
    }

    auto now = time(null);
    long offset = localtime(&now).tm_gmtoff;

    auto session = currentReading(db, "five_hour");
    auto week = currentReading(db, "seven_day");
    if (!session.readable || !week.readable) {
        sqlite3_close(db);
        fputs("ground usage: cannot read the usage table\n", stderr);
        return 1;
    }
    if (!session.found && !week.found) {
        sqlite3_close(db);
        fputs("ground usage: no readings recorded yet\n", stderr);
        return 0;
    }

    __gshared ZBuf out_;
    __gshared ZBuf when;
    out_.reset();

    {
        import checks : lastCheck, Check;
        __gshared Check plan;
        plan = lastCheck(db, "plan");
        putPlan(out_, plan.found, plan.value, plan.exit);
    }

    if (session.found) {
        when.reset();
        putReset(when, session.resetsAt, now, offset);
        putBar(out_, "Current session", session.tenths, when.slice());
    } else putBarMissing(out_, "Current session");

    if (week.found) {
        when.reset();
        putReset(when, week.resetsAt, now, offset);
        putBar(out_, "This week", week.tenths, when.slice());
    } else putBarMissing(out_, "This week");

    // Nothing ug reads carries a Fable window, so there is none to draw.
    putBarMissing(out_, "Fable this week");

    out_.put("\n");
    putMarker(out_, now, offset);
    putWeekHeader(out_);
    out_.put("tw\n");

    if (week.found) {
        enum sql = "SELECT seen_at, used_percentage FROM usage "
            ~ "WHERE window = 'seven_day' AND seen_at >= ?1 AND seen_at < ?2 ORDER BY seen_at\0";
        __gshared Reading[4096] readings;
        size_t count = 0;
        bool more = false;

        sqlite3_stmt* stmt;
        if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) {
            sqlite3_close(db);
            fputs("ground usage: cannot read this week's readings\n", stderr);
            return 1;
        }
        sqlite3_bind_int64(stmt, 1, week.resetsAt - 7 * 86400);
        sqlite3_bind_int64(stmt, 2, week.resetsAt);
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            if (count == readings.length) { more = true; break; }
            readings[count++] = Reading(sqlite3_column_int64(stmt, 0),
                                        parseTenths(cstr(sqlite3_column_text(stmt, 1))));
        }
        sqlite3_finalize(stmt);

        if (more)
            fputs("ground usage: more readings this week than the grid holds; it is drawn from the first 4096\n", stderr);
        putGrid(out_, readings[0 .. count], week.resetsAt, now, offset);
    } else {
        out_.put("   no reading recorded\n");
    }
    sqlite3_close(db);

    out_.put("\nfa\n   no Fable window is recorded\n");

    auto text = out_.slice();
    fwrite(text.ptr, 1, text.length, stdout);
    return 0;
}
