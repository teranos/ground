module saidonce_test;

// "ALSO, IT SPAMS, ONCE IS FINE"
// A refusal that is the same on every hook of a session is said to it once.

unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    import immediate : writeExecResult, saidToSession;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);
    assert(applySchema(db));
    scope (exit) sqlite3_close(db);

    enum said = "sandload: /x/libground_sand.dylib: the sand was built for engine ABI 1, and this engine is ABI 2";
    assert(!saidToSession(db, "s1", "", said), "nothing was said yet");
    assert(writeExecResult(db, "s1", "", said, "", ""));
    assert(saidToSession(db, "s1", "", said), "said once, and not again");
    assert(!saidToSession(db, "s2", "", said), "another session has not heard it");
    assert(!saidToSession(db, "s1", "", "sandload: another"), "another refusal is new");
}
