module queued_test;

// "fix that, the corpus should have what i typed"

// A message typed while a turn is running fires no hook, so ground never saw
// it. The transcript did, and every line of it is kept (transcript.d). The
// typed prompt is a query over those lines.

import queued : queuedFrom, QUEUED_PREDICATE;
import transcript : keepLines;
import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK,
            sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_stmt,
            sqlite3_column_int64, SQLITE_ROW;

private sqlite3* memDb() {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    return db;
}

private long counted(sqlite3* db, const(char)* q) {
    sqlite3_stmt* s;
    if (sqlite3_prepare_v2(db, q, -1, &s, null) != SQLITE_OK) return -1;
    long n = -1;
    if (sqlite3_step(s) == SQLITE_ROW) n = sqlite3_column_int64(s, 0);
    sqlite3_finalize(s);
    return n;
}

enum transcript =
    `{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-19T00:42:08.852Z","content":"also"}` ~ "\n"
    ~ `{"parentUuid":"25e7","attachment":{"type":"queued_command","prompt":"also","origin":{"kind":"human"},"timestamp":"2026-08-19T00:42:08.852Z"},"type":"attachment","uuid":"7633","timestamp":"2026-08-19T00:42:08.852Z"}` ~ "\n"
    ~ `{"message":{"role":"assistant","content":[{"type":"text","text":"prompt"}]},"type":"assistant"}` ~ "\n"
    ~ `not json at all` ~ "\n"
    ~ `{"attachment":{"type":"queued_command","prompt":"run the thing","origin":{"kind":"hook"},"timestamp":"2026-08-19T00:42:08.900Z"},"type":"attachment"}` ~ "\n"
    ~ `{"type":"queue-operation","operation":"remove","timestamp":"2026-08-19T00:42:10.053Z","content":"also"}` ~ "\n"
    ~ `{"attachment":{"type":"queued_command","prompt":"btw","origin":{"kind":"human"},"timestamp":"2026-08-19T00:42:08.907Z"},"type":"attachment"}` ~ "\n";

enum P = "/t/queued.jsonl";

unittest {
    auto db = memDb();
    assert(keepLines(db, P, "sess-1", transcript, 0).ok);
    // Only a human's own typing; the queue's bookkeeping repeats the same words
    // as it accepts and drains them, and a hook's queued command is not typed.
    assert(queuedFrom(db, P, 0, "sess-1", "/tmp") == 2);

    enum both = "SELECT count(*) FROM attestations "
        ~ "WHERE json_extract(predicates,'$[0]') = 'QueuedPromptSubmit'\0";
    assert(counted(db, both.ptr) == 2);

    enum one = "SELECT count(*) FROM attestations "
        ~ "WHERE json_extract(attributes,'$.prompt') = 'btw'\0";
    assert(counted(db, one.ptr) == 1, "the prompt is stored where a reader looks for it");

    enum scoped = "SELECT count(*) FROM attestations WHERE json_extract(predicates,'$[0]') = 'QueuedPromptSubmit' "
        ~ "AND json_extract(contexts,'$[0]') = 'session:sess-1'\0";
    assert(counted(db, scoped.ptr) == 2, "an approval belongs to the session that gave it");

    enum stamped = "SELECT count(*) FROM attestations "
        ~ "WHERE json_extract(predicates,'$[0]') = 'QueuedPromptSubmit' AND timestamp LIKE '2026-08-19T00:42:08%'\0";
    assert(counted(db, stamped.ptr) == 2, "at the moment it was typed");
    sqlite3_close(db);
}

unittest {
    // Two walks over the same lines keep each typed prompt once: a window
    // counting the last three messages would read one of them as three.
    auto db = memDb();
    assert(keepLines(db, P, "sess-2", transcript, 0).ok);
    assert(queuedFrom(db, P, 0, "sess-2", "/tmp") == 2);
    assert(queuedFrom(db, P, 0, "sess-2", "/tmp") == 0);
    sqlite3_close(db);
}

unittest {
    // Asked from where a walk began, only the lines it added are read.
    auto db = memDb();
    assert(keepLines(db, P, "sess-3", transcript, 0).ok);
    assert(queuedFrom(db, P, transcript.length, "sess-3", "/tmp") == 0);
    sqlite3_close(db);
}

unittest {
    // The name is what every consumer queries on, so it is stated once.
    assert(QUEUED_PREDICATE == "QueuedPromptSubmit");
}

// 「[Opus 5.5] Each queued prompt in a transcript's tail was looked up by reading every one」
// 「[Opus 5.5] this session had stored: 7 lookups over 434 rows took 49ms of every prompt.」
unittest {
    import queued : ALREADY_STORED_SQL;
    import db : sqlite3_column_text;
    import matcher : contains;
    auto db = memDb();
    enum plan = "EXPLAIN QUERY PLAN " ~ ALREADY_STORED_SQL;
    sqlite3_stmt* s;
    assert(sqlite3_prepare_v2(db, plan.ptr, -1, &s, null) == SQLITE_OK);
    bool byPrompt;
    while (sqlite3_step(s) == SQLITE_ROW) {
        auto d = sqlite3_column_text(s, 3);
        size_t n = 0;
        while (d[n] != 0) n++;
        if (contains(d[0 .. n], "idx_attestations_queued_prompt")) byPrompt = true;
    }
    sqlite3_finalize(s);
    sqlite3_close(db);
    assert(byPrompt, "the lookup finds the prompt in an index, not by reading the session's rows");
}
