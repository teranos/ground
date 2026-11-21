module queued;

// BOOK_GLOSSARY **Queued prompt**: A message typed while a turn was running, which fired no hook and is read from the transcript instead.

// "fix that, the corpus should have what i typed"

// A message typed while a turn is running fires no hook, so ground never saw
// it. The transcript holds it as an attachment, and that record is the only
// place a human's own words land when no event carried them.

import db : sqlite3;

// Not UserPromptSubmit. No hook fired for these, and an attestation that named
// one would claim an event ground never saw. Consumers ask for both.
enum QUEUED_PREDICATE = "QueuedPromptSubmit";

// "where the principle is we get all of it."
// The typed prompts among the lines of `path` kept past byte `from`
// (transcript.d), each attested once. Only a human's own typing: the queue's
// bookkeeping repeats the same words as it accepts and drains them, and a
// hook's queued command was not typed. Returns how many were added.
enum QUEUED_FROM_SQL = "WITH v AS MATERIALIZED (SELECT json_extract(attributes, '$.end') AS e, "
    ~ "json_extract(attributes, '$.line') AS line FROM attestations "
    ~ "WHERE json_extract(predicates, '$[0]') = 'transcript:line' AND json_extract(attributes, '$.path') = ?1 "
    ~ "AND json_extract(attributes, '$.end') > ?2), "
    ~ "w AS MATERIALIZED (SELECT e, line FROM v WHERE instr(line, '\"queued_command\"') > 0 AND json_valid(line)) "
    ~ "SELECT json_extract(line, '$.attachment.prompt'), "
    ~ "COALESCE(json_extract(line, '$.attachment.timestamp'), json_extract(line, '$.timestamp')), "
    ~ "json_extract(line, '$.cwd') FROM w "
    ~ "WHERE json_extract(line, '$.attachment.type') = 'queued_command' "
    ~ "AND json_extract(line, '$.attachment.origin.kind') = 'human' ORDER BY e\0";

size_t queuedFrom(sqlite3* db, const(char)[] path, long from, const(char)[] sessionId,
                  const(char)[] cwd) {
    import db : sqlite3_stmt, sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_bind_int64,
                sqlite3_step, sqlite3_finalize, sqlite3_column_text, SQLITE_OK, SQLITE_ROW,
                SQLITE_TRANSIENT;
    import zbuf : ZBuf;
    if (db is null || sessionId.length == 0) return 0;

    __gshared ZBuf ctx;
    ctx.reset();
    ctx.put("session:");
    ctx.put(sessionId);

    sqlite3_stmt* s;
    if (sqlite3_prepare_v2(db, QUEUED_FROM_SQL.ptr, -1, &s, null) != SQLITE_OK) return 0;
    sqlite3_bind_text(s, 1, path.ptr, cast(int) path.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(s, 2, from);

    const(char)[] str(int col) {
        auto p = sqlite3_column_text(s, col);
        if (p is null) return null;
        size_t n = 0;
        while (p[n]) n++;
        return p[0 .. n];
    }

    size_t added = 0;
    while (sqlite3_step(s) == SQLITE_ROW) {
        auto prompt = str(0);
        auto stamp = str(1);
        // Where the line says the session stood; a sweep is handed none.
        auto where = str(2);
        if (prompt.length == 0 || stamp.length == 0) continue;
        if (alreadyStored(db, ctx.slice(), prompt)) continue;
        if (attestPrompt(db, where.length > 0 ? where : cwd, sessionId, prompt, stamp)) added++;
    }
    sqlite3_finalize(s);
    return added;
}

enum ALREADY_STORED_SQL = "SELECT 1 FROM attestations WHERE "
    ~ "json_extract(predicates, '$[0]') = 'QueuedPromptSubmit' AND "
    ~ "json_extract(contexts, '$[0]') = ?1 AND "
    ~ "json_extract(attributes, '$.prompt') = ?2 LIMIT 1\0";

// The same bytes are read again every time the transcript is walked, and a
// window counting the last three messages would read one prompt as three.
private bool alreadyStored(sqlite3* db, const(char)[] ctx, const(char)[] prompt) {
    import db : sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_step,
                sqlite3_finalize, sqlite3_stmt, SQLITE_OK, SQLITE_ROW,
                SQLITE_TRANSIENT;

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, ALREADY_STORED_SQL.ptr, -1, &stmt, null) != SQLITE_OK) return true;
    sqlite3_bind_text(stmt, 1, ctx.ptr, cast(int) ctx.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, prompt.ptr, cast(int) prompt.length, SQLITE_TRANSIENT);
    bool found = sqlite3_step(stmt) == SQLITE_ROW;
    sqlite3_finalize(stmt);
    return found;
}

// Stored under the same key a UserPromptSubmit row uses for its text, so a
// consumer reads one shape whichever way the words arrived.

// The transcript's own stamp is passed as the attestation's time, which puts
// it in the id. attestEvent keys on the second and the pid, and two prompts
// typed in one second from one process collapsed to a single row.

// The pid is zero because no hook process produced this. Nothing forked, and
// naming one would be a claim about an invocation that never happened.
private bool attestPrompt(sqlite3* db, const(char)[] cwd, const(char)[] sessionId,
                          const(char)[] prompt, const(char)[] stamp) {
    import db : attestEventAt;
    import provenance : jsonEscapeInto;
    import zbuf : ZBuf;

    __gshared char[16384] esc;
    auto n = jsonEscapeInto(prompt, esc[]);
    if (n < 0) return false;

    __gshared ZBuf payload;
    payload.reset();
    payload.put(`{"prompt":"`);
    payload.put(cast(const(char)[]) esc[0 .. n]);
    payload.put(`"}`);

    attestEventAt(db, QUEUED_PREDICATE, cwd, sessionId, payload.slice(), stamp, 0);
    return true;
}
