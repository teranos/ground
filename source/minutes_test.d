module minutes_test;

// The Actions minutes an org has used this month, read from GitHub's billing
// summary and kept in a table of its own, where the status line reads it
// without a network call and without walking the attestations.

import minutes : summaryUrl, usedMinutes, dueAt, EVERY;

// Asked per org and per month, and only of Actions.
static assert(summaryUrl("abcd-nl", 2026, 9).text() ==
    "https://api.github.com/organizations/abcd-nl/settings/billing/usage/summary"
    ~ "?year=2026&month=9&product=actions");

// GitHub's own answer, as it came on 2026-09-17. Minutes and storage arrive in
// one list, and only the minutes are minutes.
enum answered = `{"timePeriod":{"year":2026,"month":9},"organization":"abcd-nl","product":"Actions","usageItems":[`
    ~ `{"product":"Actions","sku":"actions_linux","grossQuantity":2007.0,"discountQuantity":2000.0,"netQuantity":7.0,"grossAmount":12.042,"discountAmount":12.0,"netAmount":0.042,"pricePerUnit":0.006,"unitType":"minutes"},`
    ~ `{"product":"Actions","sku":"actions_storage","grossQuantity":216.956594022,"discountQuantity":216.956594022,"netQuantity":0.0,"grossAmount":0.072900834,"discountAmount":0.072900834,"netAmount":0.0,"pricePerUnit":0.00033602,"unitType":"gigabyte-hours"}]}`;
static assert(usedMinutes(answered).ok);
static assert(usedMinutes(answered).minutes == 2007);

// Every runner's minutes count against the one quota.
enum twoRunners = `{"usageItems":[`
    ~ `{"sku":"actions_linux","grossQuantity":100.5,"unitType":"minutes"},`
    ~ `{"sku":"actions_macos","grossQuantity":40.0,"unitType":"minutes"}]}`;
static assert(usedMinutes(twoRunners).minutes == 140);

// A month nothing ran in is zero minutes, which is an answer.
static assert(usedMinutes(`{"usageItems":[]}`).ok);
static assert(usedMinutes(`{"usageItems":[]}`).minutes == 0);

// What is not the list is not zero minutes. GitHub's refusal is a body too,
// and reading it as a quiet month would draw an all-clear nobody measured.
static assert(!usedMinutes(`{"message":"Not Found","status":"404"}`).ok);
static assert(!usedMinutes("").ok);

// Asked again when the last asking is ten minutes old. The bands a person
// watches for are two points wide, and two points of 2000 is forty minutes.
// One asker at a time. Two sessions ending a turn in the same second both see
// a reading that is due, and only one of them may go and ask.
import minutes : claimAsking, recordReading;
import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK,
            sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_column_int64,
            sqlite3_stmt, SQLITE_ROW;

private long column(sqlite3* db, string sql) {
    sqlite3_stmt* stmt;
    assert(sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK);
    long v = -99;
    if (sqlite3_step(stmt) == SQLITE_ROW) v = sqlite3_column_int64(stmt, 0);
    sqlite3_finalize(stmt);
    return v;
}

unittest {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    assert(claimAsking(db, "abcd-nl", 2000, 10_000), "never asked, so the first asker asks");
    assert(!claimAsking(db, "abcd-nl", 2000, 10_000), "and the second in that second does not");
    assert(!claimAsking(db, "abcd-nl", 2000, 10_599));
    assert(claimAsking(db, "abcd-nl", 2000, 10_600), "due again when the asking is ten minutes old");

    // Asked and not yet answered is not zero minutes.
    assert(column(db, "SELECT used FROM org_minutes WHERE org = 'abcd-nl'\0") == -1);

    assert(recordReading(db, "abcd-nl", 1020, 10_601).ok);
    assert(column(db, "SELECT used FROM org_minutes WHERE org = 'abcd-nl'\0") == 1020);
    assert(column(db, "SELECT quota FROM org_minutes WHERE org = 'abcd-nl'\0") == 2000);
    assert(column(db, "SELECT seen_at FROM org_minutes WHERE org = 'abcd-nl'\0") == 10_601);

    // A quota the pbt changed is the quota from the next asking on.
    assert(claimAsking(db, "abcd-nl", 3000, 20_000));
    assert(column(db, "SELECT quota FROM org_minutes WHERE org = 'abcd-nl'\0") == 3000);

    auto nowhere = recordReading(db, "nobody", 5, 1);
    assert(!nowhere.ok, "a reading for an org never claimed lands nowhere");
    assert(nowhere.noRow, "and that is said as no row, not as a lock");
    sqlite3_close(db);
}

// Measured 2026-09-17, the first live asking: github answered, and the reading
// "could not be written down". The child writes while the Stop hook that forked
// it is still writing, and one refused try was the whole attempt. A lock is
// waited out, and one that outlasts the wait is named as a lock.
unittest {
    import db : sqlite3_exec, SQLITE_BUSY;
    import errors : unlink;

    enum path = "/tmp/ground-minutes-busy-test.db\0";
    unlink(path.ptr);
    scope (exit) unlink(path.ptr);

    sqlite3* a;
    sqlite3* b;
    assert(sqlite3_open(path.ptr, &a) == SQLITE_OK);
    assert(applySchema(a));
    assert(claimAsking(a, "abcd-nl", 2000, 10_000));
    assert(sqlite3_open(path.ptr, &b) == SQLITE_OK);

    assert(sqlite3_exec(a, "BEGIN IMMEDIATE\0".ptr, null, null, null) == SQLITE_OK);
    auto held = recordReading(b, "abcd-nl", 1020, 10_001);
    assert(!held.ok);
    assert(held.rc == SQLITE_BUSY, "a lock that outlasted the wait is said to be a lock");

    assert(sqlite3_exec(a, "COMMIT\0".ptr, null, null, null) == SQLITE_OK);
    auto free = recordReading(b, "abcd-nl", 1020, 10_001);
    assert(free.ok);

    sqlite3_close(a);
    sqlite3_close(b);
}

static assert(EVERY == 600);
static assert(dueAt(0, 1000), "never asked is due");
static assert(!dueAt(1000, 1599));
static assert(dueAt(1000, 1600));
