module db_schema_test;

// applySchema has to reach a store that already exists, not only an empty one.
// Every other db test opens :memory: and gets a fresh store, so a live table
// three columns behind the product schema passes all of them.

import db : sqlite3, sqlite3_open, sqlite3_close, sqlite3_exec,
            applySchema, hasColumn, SQLITE_OK;

private sqlite3* openWith(string ddl) {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    if (ddl.length > 0)
        assert(sqlite3_exec(db, ddl.ptr, null, null, null) == SQLITE_OK);
    return db;
}

unittest {
    // A store from before hook_event, project and phases existed. This is not
    // hypothetical — main.d carried three ALTER TABLE lines for exactly it.
    enum old = "CREATE TABLE timing (id INTEGER PRIMARY KEY, "
        ~ "duration_us INTEGER NOT NULL, created_at DATETIME)\0";
    auto db = openWith(old);

    assert(applySchema(db));
    assert(hasColumn(db, "timing", "hook_event"));
    assert(hasColumn(db, "timing", "project"));
    assert(hasColumn(db, "timing", "phases"));
    sqlite3_close(db);
}

unittest {
    // An empty store gets the same shape.
    auto db = openWith("");
    assert(applySchema(db));
    assert(hasColumn(db, "timing", "hook_event"));
    assert(hasColumn(db, "ritual_position", "id"));
    assert(hasColumn(db, "ritual_position", "worktree"));
    sqlite3_close(db);
}

unittest {
    // Applied twice, because it runs on every openDb.
    auto db = openWith("");
    assert(applySchema(db));
    assert(applySchema(db));
    assert(hasColumn(db, "timing", "phases"));
    sqlite3_close(db);
}

unittest {
    // A column nobody declared is absent, so a passing assertion above means
    // the column is there rather than the check being blind.
    auto db = openWith("");
    assert(applySchema(db));
    assert(!hasColumn(db, "timing", "nosuchcolumn"));
    assert(!hasColumn(db, "nosuchtable", "id"));
    sqlite3_close(db);
}
