module queued;

// "fix that, the corpus should have what i typed"

// A message typed while a turn is running fires no hook, so ground never saw
// it. The transcript holds it as an attachment, and that record is the only
// place a human's own words land when no event carried them.

import parse : extractJsonString;
import matcher : contains;

// The prompt on this line, when the line is a queued command a person typed.
// Null for everything else, including the queue's own bookkeeping, which
// repeats the same words as it accepts and drains them.
const(char)[] humanQueuedPrompt(const(char)[] line) {
    if (!contains(line, `"type":"queued_command"`)) return null;
    if (!contains(line, `"origin":{"kind":"human"}`)) return null;

    __gshared char[8192] buf = 0;
    return extractJsonString(line, `"prompt"`, &buf[0], buf.length);
}

// The moment the message was typed, as the transcript records it. It is what
// makes one queued prompt distinguishable from another typed in the same
// second, and it is stable across every re-read of the same file.
const(char)[] humanQueuedStamp(const(char)[] line) {
    if (!contains(line, `"type":"queued_command"`)) return null;
    if (!contains(line, `"origin":{"kind":"human"}`)) return null;

    __gshared char[64] buf = 0;
    return extractJsonString(line, `"timestamp"`, &buf[0], buf.length);
}

// Not UserPromptSubmit. No hook fired for these, and an attestation that named
// one would claim an event ground never saw. Consumers ask for both.
enum QUEUED_PREDICATE = "QueuedPromptSubmit";

// Where the walk is, and what it found there. The prompt is a slice of one
// shared buffer, so it is only valid until the next call.
struct QueuedHit {
    bool ok;
    size_t next;
    const(char)[] prompt;
    const(char)[] stamp;
}

// The next typed prompt at or after `from`. A transcript is one object per
// line and only grows, so a cursor reads it without holding it.
QueuedHit nextQueuedPrompt(const(char)[] content, size_t from) {
    size_t i = from;
    while (i < content.length) {
        size_t e = i;
        while (e < content.length && content[e] != '\n') e++;

        auto found = humanQueuedPrompt(content[i .. e]);
        auto after = e < content.length ? e + 1 : e;
        if (found !is null)
            return QueuedHit(true, after, found, humanQueuedStamp(content[i .. e]));
        i = after;
    }
    return QueuedHit(false, content.length, null, null);
}

import db : sqlite3;

// Every typed prompt in `content` that the store does not already hold, put
// where a reader of the corpus will find it. Returns how many were added.
size_t ingestQueued(sqlite3* db, const(char)[] content, const(char)[] sessionId,
                    const(char)[] cwd) {
    if (db is null || sessionId.length == 0) return 0;

    import zbuf : ZBuf;
    __gshared ZBuf ctx;
    ctx.reset();
    ctx.put("session:");
    ctx.put(sessionId);

    size_t added = 0;
    size_t from = 0;
    while (true) {
        auto hit = nextQueuedPrompt(content, from);
        if (!hit.ok) break;
        from = hit.next;
        if (hit.prompt.length == 0) continue;
        if (hit.stamp.length == 0) continue;
        if (alreadyStored(db, ctx.slice(), hit.prompt)) continue;
        if (attestPrompt(db, cwd, sessionId, hit.prompt, hit.stamp)) added++;
    }
    return added;
}

// The same bytes are read again every time the transcript is walked, and a
// window counting the last three messages would read one prompt as three.
private bool alreadyStored(sqlite3* db, const(char)[] ctx, const(char)[] prompt) {
    import db : sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_step,
                sqlite3_finalize, sqlite3_stmt, SQLITE_OK, SQLITE_ROW,
                SQLITE_TRANSIENT;

    enum sql = "SELECT 1 FROM attestations WHERE "
        ~ "json_extract(predicates, '$[0]') = 'QueuedPromptSubmit' AND "
        ~ "json_extract(contexts, '$[0]') = ?1 AND "
        ~ "json_extract(attributes, '$.prompt') = ?2 LIMIT 1\0";

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return true;
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
