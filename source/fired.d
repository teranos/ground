module fired;

// "i just want to know if controls fired at all, or generally"
// Every firing of every control, as one outbox item. Not the once-per-session
// mark the advisory messages dedup on: a rewrite firing for the hundredth time
// is a hundred of these.

import db : sqlite3;

// `kind` is control, permission or rewrite; `decision` is what it did.
void noteFired(sqlite3* db, const(char)[] sessionId, const(char)[] event, const(char)[] kind,
               const(char)[] name, const(char)[] decision, const(char)[] cwd) {
    import core.stdc.time : time;
    import db : cwdTail, ZBuf;
    import sentry : openItem;
    import outbox : leave;

    if (db is null) return;
    auto now = cast(long) time(null);

    __gshared ZBuf body_;
    body_.reset();
    body_.put(kind);
    body_.put(" ");
    body_.put(name);
    body_.put(" fired: ");
    body_.put(decision);

    auto it = openItem(now, sessionId, "info", body_.slice());
    it.str("kind", kind);
    it.str("control", name);
    it.str("event", event);
    it.str("decision", decision);
    it.str("project", cwdTail(cwd));
    it.close();
    cast(void) leave(db, sessionId, "info", it, now);
}

// For a site that holds no store handle. One open, one row, one close.
void noteFiredNow(const(char)[] sessionId, const(char)[] event, const(char)[] kind,
                  const(char)[] name, const(char)[] decision, const(char)[] cwd) {
    import db : openDb, sqlite3_close;
    auto db = openDb();
    if (db is null) return;
    noteFired(db, sessionId, event, kind, name, decision, cwd);
    sqlite3_close(db);
}

unittest {
    import db : sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    import sentry : Batch;
    import outbox : claimOutbox, claimedInto;
    import matcher : contains;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    // The same control twice is two firings, not one.
    noteFired(db, "sess-f", "PreToolUse", "control", "no-skip-hooks", "rewrite", "/Users/x/teranos/ground");
    noteFired(db, "sess-f", "PreToolUse", "control", "no-skip-hooks", "rewrite", "/Users/x/teranos/ground");
    noteFired(db, "sess-f", "PreToolUse", "permission", "git-status", "allow", "/Users/x/teranos/ground");

    Batch!32768 b;
    assert(claimOutbox(db, "sess-f", 111) == 3);
    assert(claimedInto(db, 111, b) == 3);
    assert(b.count == 3);
    auto text = b.buf[0 .. b.len];
    assert(contains(text, `"body":"control no-skip-hooks fired: rewrite"`));
    assert(contains(text, `"project":{"value":"teranos/ground","type":"string"}`), "two path components, never the path");
    assert(!contains(text, "/Users/x"));
    assert(contains(text, `"body":"permission git-status fired: allow"`));

    // No store, nothing said, nothing broken.
    noteFired(null, "sess-f", "Stop", "control", "x", "block", "/p");
    sqlite3_close(db);
}
