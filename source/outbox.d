module outbox;

// What a hook has to say to sentry, left in the store as a finished log item.
// A hook opens no socket: it writes the row and exits, and the watcher of its
// session posts what is pending in one envelope per pass.

import db : sqlite3;
import sentry : Item;

// One row. The item is complete JSON, so the reader wraps and never parses.
bool leave(sqlite3* db, const(char)[] session, const(char)[] level, const Item it, long now) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_bind_int64, sqlite3_stmt, SQLITE_OK, SQLITE_DONE, SQLITE_TRANSIENT;

    auto text = it.text();
    if (text.length == 0) return false;
    enum sql = "INSERT INTO outbox (session, level, item, at) VALUES (?1, ?2, ?3, ?4)\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return false;
    sqlite3_bind_text(stmt, 1, session.ptr, cast(int) session.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, level.ptr, cast(int) level.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, text.ptr, cast(int) text.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 4, now);
    auto rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return rc == SQLITE_DONE;
}

// How many items one pass takes. The envelope holds a quarter megabyte, and an
// item is under four kilobytes.
enum TAKE = 60;

// The pending items of one session, oldest first, into the batch. Returns the
// highest id taken, so the caller can mark exactly those as shipped once the
// post has landed, and 0 when nothing was pending.
long pendingInto(B)(sqlite3* db, const(char)[] session, ref B batch) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_bind_int64, sqlite3_column_int64, sqlite3_column_text,
                sqlite3_stmt, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;

    // Items nobody's session wrote, an error raised with no session to name,
    // go with whichever watcher passes first.
    enum sql = "SELECT id, item FROM outbox WHERE shipped_at = 0 AND (session = ?1 OR session = '') "
        ~ "ORDER BY id LIMIT ?2\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return 0;
    sqlite3_bind_text(stmt, 1, session.ptr, cast(int) session.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 2, TAKE);

    long last = 0;
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        auto text = sqlite3_column_text(stmt, 1);
        if (text is null) continue;
        size_t n = 0;
        while (text[n] != 0) n++;
        if (!batch.fits(n)) break;
        batch.add(text[0 .. n]);
        last = sqlite3_column_int64(stmt, 0);
    }
    sqlite3_finalize(stmt);
    return last;
}

// The rows up to `last` of this session are shipped. Called only once the
// post has answered 200, so a post that did not land ships them again.
void shipped(sqlite3* db, const(char)[] session, long last, long now) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_bind_int64, sqlite3_stmt, SQLITE_OK, SQLITE_TRANSIENT;

    enum sql = "UPDATE outbox SET shipped_at = ?3 WHERE shipped_at = 0 AND (session = ?1 OR session = '') AND id <= ?2\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return;
    sqlite3_bind_text(stmt, 1, session.ptr, cast(int) session.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 2, last);
    sqlite3_bind_int64(stmt, 3, now);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

unittest {
    import db : sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    import sentry : openItem, Batch;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    Batch!8192 none;
    assert(pendingInto(db, "sess-o", none) == 0, "nothing left is nothing pending");

    auto a = openItem(1000, "sess-o", "info", "control x fired"); a.close();
    auto b = openItem(1001, "sess-o", "warn", "over budget"); b.close();
    auto c = openItem(1002, "sess-p", "info", "somebody else's"); c.close();
    assert(leave(db, "sess-o", "info", a, 1000));
    assert(leave(db, "sess-o", "warn", b, 1001));
    assert(leave(db, "sess-p", "info", c, 1002));

    // One session's items, oldest first, and not another session's.
    Batch!8192 batch;
    auto last = pendingInto(db, "sess-o", batch);
    assert(batch.count == 2);
    assert(last == 2);

    // Not shipped until the post landed: asking again hands them over again.
    Batch!8192 again;
    assert(pendingInto(db, "sess-o", again) == 2);

    shipped(db, "sess-o", last, 1005);
    Batch!8192 after;
    assert(pendingInto(db, "sess-o", after) == 0, "shipped is shipped");

    // The other session's item is still its watcher's to take.
    Batch!8192 theirs;
    assert(pendingInto(db, "sess-p", theirs) == 3);

    // An item that did not fit its buffer is not left: half an item is not JSON.
    Item over;
    over.over = true;
    assert(!leave(db, "sess-o", "info", over, 1006));
    sqlite3_close(db);
}
