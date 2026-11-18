module policy_test;

// "Which policy a session ran under. ground records what a session did, but not
// which version of the global CLAUDE.md it was given. Without that, nothing can
// be compared before and after a change."
// "this is something i want"

import policy : keepPolicy, policyFiles, PolicyFiles;

// 「[Opus 5.5] The files Claude Code gives a session: the global one, then each」
// 「[Opus 5.5] CLAUDE.md from the root down to where the session starts.」
static assert(() {
    auto f = policyFiles("/u", "/u/teranos/ground");
    return f.count == 5
        && f[0] == "/u/.claude/CLAUDE.md"
        && f[1] == "/CLAUDE.md"
        && f[2] == "/u/CLAUDE.md"
        && f[3] == "/u/teranos/CLAUDE.md"
        && f[4] == "/u/teranos/ground/CLAUDE.md";
}());

// 「[Opus 5.5] A session that starts in the home directory: the global one, the root's, and」
// 「[Opus 5.5] the home's own, which is another file than the global one.」
static assert(policyFiles("/u", "/u").count == 3);

unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK,
        sqlite3_prepare_v2, sqlite3_step, sqlite3_column_int64, sqlite3_finalize, sqlite3_stmt, SQLITE_ROW;

    long scalarCount(sqlite3* d, string sql) {
        sqlite3_stmt* st;
        if (sqlite3_prepare_v2(d, sql.ptr, -1, &st, null) != SQLITE_OK) return -1;
        scope (exit) sqlite3_finalize(st);
        return sqlite3_step(st) == SQLITE_ROW ? sqlite3_column_int64(st, 0) : -1;
    }

    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    scope (exit) sqlite3_close(db);

    enum G = "/u/.claude/CLAUDE.md";
    enum V1 = "# USER INSTRUCTIONS\n7. ask the user for permission for running `make install`\n";
    enum V2 = "# USER INSTRUCTIONS\n7. dont ask the user for permission for running `make install`\n";

    // 「[Opus 5.5] A session starts under the first version.」
    assert(keepPolicy(db, "s-1", G, V1, 1000), "a first version is written down");
    // 「[Opus 5.5] Resumed with nothing changed: nothing new to say.」
    assert(!keepPolicy(db, "s-1", G, V1, 2000), "the same text again is not a change");
    // 「[Opus 5.5] Resumed after the person changed the file: the session now runs under the second.」
    assert(keepPolicy(db, "s-1", G, V2, 3000), "a changed text is a change");
    // 「[Opus 5.5] Another session under the first version shares its text, kept once.」
    assert(keepPolicy(db, "s-2", G, V1, 4000));

    assert(scalarCount(db, "SELECT count(*) FROM session_policy\0") == 3);
    assert(scalarCount(db, "SELECT count(*) FROM policy_text\0") == 2, "each text once, by its hash");
    assert(scalarCount(db, "SELECT count(*) FROM session_policy WHERE session = 's-1'\0") == 2);
    assert(scalarCount(db, "SELECT count(DISTINCT hash) FROM session_policy WHERE path = '/u/.claude/CLAUDE.md'\0") == 2);

    // 「[Opus 5.5] The node is told: which text each session ran under, and each text once.」
    assert(scalarCount(db, "SELECT count(*) FROM attestations WHERE predicates = '[\"session:policy\"]'\0") == 3);
    assert(scalarCount(db, "SELECT count(*) FROM attestations WHERE predicates = '[\"policy:text\"]'\0") == 2);
    assert(scalarCount(db, "SELECT count(*) FROM attestations WHERE predicates = '[\"policy:text\"]' "
        ~ "AND json_extract(attributes, '$.text') LIKE '%dont ask the user%'\0") == 1);
}
