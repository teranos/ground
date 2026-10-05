module sessionmodel_test;

// A fork, a resume and a clear start with no model in SessionStart's input, so
// the node never learned what ran them; ug knew, from the status line, and
// kept it in session_model, which is not streamed (QNTX #1068, Phase 3).

import sessionmodel : RECORD_MODEL_SQL, ATTEST_MODEL_SQL;
import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, sqlite3_prepare_v2, sqlite3_step,
            sqlite3_finalize, sqlite3_bind_text, sqlite3_bind_int64, sqlite3_column_text,
            sqlite3_column_int64, sqlite3_changes, sqlite3_stmt, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;

private void run(sqlite3* db, string sql, string session, string model, string effort, long at) {
    sqlite3_stmt* s;
    assert(sqlite3_prepare_v2(db, sql.ptr, cast(int) sql.length, &s, null) == SQLITE_OK);
    sqlite3_bind_text(s, 1, session.ptr, cast(int) session.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(s, 2, model.ptr, cast(int) model.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(s, 3, effort.ptr, cast(int) effort.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(s, 4, at);
    sqlite3_step(s);
    sqlite3_finalize(s);
}

private long count(sqlite3* db, string sql) {
    sqlite3_stmt* s;
    assert(sqlite3_prepare_v2(db, sql.ptr, cast(int) sql.length, &s, null) == SQLITE_OK);
    long n = -1;
    if (sqlite3_step(s) == SQLITE_ROW) n = sqlite3_column_int64(s, 0);
    sqlite3_finalize(s);
    return n;
}

// One frame of ug: the model row, and the attestation only when the row was
// new. Checking attestations for a change instead would scan them every frame.
private void frame(sqlite3* db, string session, string model, string effort, long at) {
    run(db, RECORD_MODEL_SQL, session, model, effort, at);
    if (sqlite3_changes(db) == 1) run(db, ATTEST_MODEL_SQL, session, model, effort, at);
}

unittest {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    frame(db, "sess-f", "claude-opus-5-5", "high", 1000);
    enum q = "SELECT count(*) FROM attestations WHERE json_extract(predicates, '$[0]') = 'session:model' "
        ~ "AND json_extract(contexts, '$[0]') = 'session:sess-f' "
        ~ "AND json_extract(attributes, '$.model') = 'claude-opus-5-5' "
        ~ "AND json_extract(attributes, '$.effort') = 'high' AND qntx_at = 0\0";
    assert(count(db, q) == 1, "the node is sent what the session ran on");

    // The same model again writes nothing, and a change is its own row.
    frame(db, "sess-f", "claude-opus-5-5", "high", 1001);
    assert(count(db, "SELECT count(*) FROM attestations WHERE json_extract(predicates, '$[0]') = 'session:model'\0") == 1);
    frame(db, "sess-f", "claude-fable-5-1", "high", 1100);
    assert(count(db, "SELECT count(*) FROM attestations WHERE json_extract(predicates, '$[0]') = 'session:model'\0") == 2);
    sqlite3_close(db);
}
