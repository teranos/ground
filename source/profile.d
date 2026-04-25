module profile;

import db : openDb, sqlite3, sqlite3_close, sqlite3_prepare_v2, sqlite3_step,
                sqlite3_bind_text, sqlite3_bind_int64, sqlite3_finalize, sqlite3_stmt,
                sqlite3_column_text, sqlite3_column_int64,
                SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
import core.stdc.stdio : stdout, stderr, fputs, fwrite;

struct Buf {
    char[4096] data = 0;
    size_t len;
    void put(const(char)[] s) { foreach (c; s) putChar(c); }
    void putChar(char c) { if (len < data.length) data[len++] = c; }
    const(char)[] slice() { return data[0 .. len]; }
    const(char)* ptr() { if (len < data.length) data[len] = 0; return &data[0]; }
    void reset() { len = 0; }
    void flush() { if (len > 0) { fwrite(&data[0], 1, len, stdout); len = 0; } }
}

void padRight(ref Buf buf, const(char)[] s, size_t width) {
    buf.put(s);
    if (s.length < width)
        foreach (_; 0 .. width - s.length) buf.putChar(' ');
}

void padLeft(ref Buf buf, long v, size_t width) {
    char[20] digits = 0;
    int dLen = 0;
    if (v == 0) { digits[0] = '0'; dLen = 1; }
    else { while (v > 0) { digits[dLen++] = cast(char)('0' + v % 10); v /= 10; } }
    if (cast(size_t) dLen < width)
        foreach (_; 0 .. width - dLen) buf.putChar(' ');
    foreach (i; 0 .. dLen) buf.putChar(digits[dLen - 1 - i]);
}

const(char)[] cstr(const(char)* p) {
    if (p is null) return "";
    size_t n = 0;
    while (p[n] != 0) n++;
    return p[0 .. n];
}

// Percentile via LIMIT 1 OFFSET. filter is a WHERE clause fragment bound to ?1.
long percentile(sqlite3* db, const(char)[] filter, const(char)[] bindVal, long count, int pct) {
    auto offset = count * (100 - pct) / 100; // descending order offset
    // "SELECT duration_us/1000 FROM timing WHERE <filter> ORDER BY duration_us DESC LIMIT 1 OFFSET ?2"
    __gshared Buf sql;
    sql.reset();
    sql.put("SELECT duration_us/1000 FROM timing WHERE ");
    sql.put(filter);
    sql.put(" ORDER BY duration_us DESC LIMIT 1 OFFSET ?2\0");

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr(), -1, &stmt, null) != SQLITE_OK)
        return 0;
    sqlite3_bind_text(stmt, 1, bindVal.ptr, cast(int) bindVal.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 2, offset);
    long result = 0;
    if (sqlite3_step(stmt) == SQLITE_ROW)
        result = sqlite3_column_int64(stmt, 0);
    sqlite3_finalize(stmt);
    return result;
}

int handleProfile(int argc, const(char)** argv) {
    auto db = openDb();
    if (db is null) { fputs("ground profile: cannot open db\n", stderr); return 1; }

    __gshared Buf out_;

    // === Per-event summary ===
    out_.reset();
    out_.put("── by event ──\n");
    padRight(out_, "event", 20);
    out_.put("samples");
    out_.put("   avg");
    out_.put("   med");
    out_.put("   p95");
    out_.put("   max\n");
    out_.flush();

    {
        enum sql = "SELECT hook_event, COUNT(*), CAST(AVG(duration_us)/1000 AS INTEGER), CAST(MAX(duration_us)/1000 AS INTEGER) FROM timing GROUP BY hook_event ORDER BY AVG(duration_us) DESC\0";
        sqlite3_stmt* stmt;
        if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK) {
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                auto event = cstr(sqlite3_column_text(stmt, 0));
                auto count = sqlite3_column_int64(stmt, 1);
                auto avg = sqlite3_column_int64(stmt, 2);
                auto max = sqlite3_column_int64(stmt, 3);

                auto med = percentile(db, "hook_event = ?1", event, count, 50);
                auto p95 = percentile(db, "hook_event = ?1", event, count, 95);

                out_.reset();
                padRight(out_, event, 20);
                padLeft(out_, count, 7);
                padLeft(out_, avg, 6); out_.put("ms");
                padLeft(out_, med, 6); out_.put("ms");
                padLeft(out_, p95, 6); out_.put("ms");
                padLeft(out_, max, 6); out_.put("ms");
                out_.put("\n");
                out_.flush();
            }
            sqlite3_finalize(stmt);
        }
    }

    // === Per-project (top 15 by avg) ===
    out_.reset();
    out_.put("\n── by project (top 15 avg) ──\n");
    padRight(out_, "project", 24);
    padRight(out_, "event", 20);
    out_.put("samples");
    out_.put("   avg");
    out_.put("   max\n");
    out_.flush();

    {
        enum sql = "SELECT project, hook_event, COUNT(*), CAST(AVG(duration_us)/1000 AS INTEGER), CAST(MAX(duration_us)/1000 AS INTEGER) FROM timing GROUP BY project, hook_event ORDER BY AVG(duration_us) DESC LIMIT 15\0";
        sqlite3_stmt* stmt;
        if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK) {
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                auto project = cstr(sqlite3_column_text(stmt, 0));
                auto event = cstr(sqlite3_column_text(stmt, 1));
                auto count = sqlite3_column_int64(stmt, 2);
                auto avg = sqlite3_column_int64(stmt, 3);
                auto max = sqlite3_column_int64(stmt, 4);

                out_.reset();
                if (project.length > 23)
                    padRight(out_, project[$ - 23 .. $], 24);
                else
                    padRight(out_, project, 24);
                padRight(out_, event, 20);
                padLeft(out_, count, 5);
                padLeft(out_, avg, 6); out_.put("ms");
                padLeft(out_, max, 6); out_.put("ms");
                out_.put("\n");
                out_.flush();
            }
            sqlite3_finalize(stmt);
        }
    }

    // === Worst 10 calls ===
    out_.reset();
    out_.put("\n── worst 10 ──\n");
    out_.flush();

    {
        enum sql = "SELECT duration_us/1000, hook_event, project, phases, created_at FROM timing ORDER BY duration_us DESC LIMIT 10\0";
        sqlite3_stmt* stmt;
        if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK) {
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                auto ms = sqlite3_column_int64(stmt, 0);
                auto event = cstr(sqlite3_column_text(stmt, 1));
                auto project = cstr(sqlite3_column_text(stmt, 2));
                auto phases = cstr(sqlite3_column_text(stmt, 3));
                auto created = cstr(sqlite3_column_text(stmt, 4));

                out_.reset();
                padLeft(out_, ms, 6); out_.put("ms ");
                padRight(out_, event, 18);
                padRight(out_, project, 20);
                out_.put(created.length >= 16 ? created[0 .. 16] : created);
                if (phases.length > 0) {
                    out_.put("\n        ");
                    if (phases.length > 120)
                        out_.put(phases[0 .. 120]);
                    else
                        out_.put(phases);
                }
                out_.put("\n");
                out_.flush();
            }
            sqlite3_finalize(stmt);
        }
    }

    // === Daily aggregates (last 14 days) ===
    out_.reset();
    out_.put("\n── daily (last 14 days) ──\n");
    padRight(out_, "day", 14);
    out_.put("samples");
    out_.put("   avg");
    out_.put("   med");
    out_.put("   p95");
    out_.put("   max\n");
    out_.flush();

    {
        enum sql = "SELECT date(created_at) as day, COUNT(*), CAST(AVG(duration_us)/1000 AS INTEGER), CAST(MAX(duration_us)/1000 AS INTEGER) FROM timing WHERE created_at > datetime('now', '-14 days') GROUP BY day ORDER BY day DESC\0";
        sqlite3_stmt* stmt;
        if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK) {
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                auto day = cstr(sqlite3_column_text(stmt, 0));
                auto count = sqlite3_column_int64(stmt, 1);
                auto avg = sqlite3_column_int64(stmt, 2);
                auto max = sqlite3_column_int64(stmt, 3);

                // Build filter: "created_at >= '<day>' AND created_at < date('<day>', '+1 day')"
                __gshared Buf filter;
                filter.reset();
                filter.put("created_at >= '");
                filter.put(day);
                filter.put("' AND created_at < date('");
                filter.put(day);
                filter.put("', '+1 day')");

                // percentile needs ?1 bind — use dummy bind since filter is inline
                auto med = percentileInline(db, filter.slice(), count, 50);
                auto p95 = percentileInline(db, filter.slice(), count, 95);

                out_.reset();
                padRight(out_, day, 14);
                padLeft(out_, count, 5);
                padLeft(out_, avg, 6); out_.put("ms");
                padLeft(out_, med, 6); out_.put("ms");
                padLeft(out_, p95, 6); out_.put("ms");
                padLeft(out_, max, 6); out_.put("ms");
                out_.put("\n");
                out_.flush();
            }
            sqlite3_finalize(stmt);
        }
    }

    sqlite3_close(db);
    return 0;
}

// Percentile with inline filter (no bind parameter needed)
long percentileInline(sqlite3* db, const(char)[] filter, long count, int pct) {
    auto offset = count * (100 - pct) / 100;
    __gshared Buf sql;
    sql.reset();
    sql.put("SELECT duration_us/1000 FROM timing WHERE ");
    sql.put(filter);
    sql.put(" ORDER BY duration_us DESC LIMIT 1 OFFSET ");
    // Write offset as text
    char[20] digits = 0;
    int dLen = 0;
    auto v = offset;
    if (v == 0) { digits[0] = '0'; dLen = 1; }
    else { while (v > 0) { digits[dLen++] = cast(char)('0' + v % 10); v /= 10; } }
    foreach (i; 0 .. dLen) sql.putChar(digits[dLen - 1 - i]);
    sql.putChar('\0');

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr(), -1, &stmt, null) != SQLITE_OK)
        return 0;
    long result = 0;
    if (sqlite3_step(stmt) == SQLITE_ROW)
        result = sqlite3_column_int64(stmt, 0);
    sqlite3_finalize(stmt);
    return result;
}
