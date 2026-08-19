module queued_test;

// "fix that, the corpus should have what i typed"

// A message typed while a turn is running fires no hook, so ground never saw
// it. The transcript did. This reads the one record in it that carries a
// human's own words.

import queued : humanQueuedPrompt;

enum queuedLine = `{"parentUuid":"25e7","isSidechain":false,"attachment":{"type":"queued_command","prompt":"lets do the following","source_uuid":"ab37","commandMode":"prompt","origin":{"kind":"human"},"timestamp":"2026-08-19T00:42:08.852Z"},"type":"attachment","uuid":"7633","timestamp":"2026-08-19T00:42:08.852Z"}`;

unittest {
    assert(humanQueuedPrompt(queuedLine) == "lets do the following");
}

unittest {
    // The queue writes the same words twice more as it accepts and drains them.
    // Counting those would attest one typed line three times.
    enum enqueue = `{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-19T00:42:08.852Z","sessionId":"95ce","content":"lets do the following"}`;
    enum remove = `{"type":"queue-operation","operation":"remove","timestamp":"2026-08-19T00:42:10.053Z","sessionId":"95ce","content":"lets do the following"}`;
    assert(humanQueuedPrompt(enqueue) is null);
    assert(humanQueuedPrompt(remove) is null);
}

unittest {
    // Only a human's own typing is what the corpus is missing.
    enum machine = `{"attachment":{"type":"queued_command","prompt":"run the thing","origin":{"kind":"hook"}},"type":"attachment"}`;
    assert(humanQueuedPrompt(machine) is null);
}

unittest {
    enum assistant = `{"message":{"role":"assistant","content":[{"type":"text","text":"prompt"}]},"type":"assistant"}`;
    assert(humanQueuedPrompt(assistant) is null);

    assert(humanQueuedPrompt("") is null);
    assert(humanQueuedPrompt("not json at all") is null);
}

// A transcript is one JSON object per line and grows without bound, so the
// walk is a cursor rather than a list. The prompt lives in a shared buffer:
// read it before asking for the next one.

import queued : nextQueuedPrompt;

enum transcript =
    `{"type":"queue-operation","operation":"enqueue","content":"also"}` ~ "\n"
    ~ `{"attachment":{"type":"queued_command","prompt":"also","origin":{"kind":"human"},"timestamp":"2026-08-19T00:42:08.852Z"},"type":"attachment"}` ~ "\n"
    ~ `{"message":{"role":"assistant"},"type":"assistant"}` ~ "\n"
    ~ `{"attachment":{"type":"queued_command","prompt":"btw","origin":{"kind":"human"},"timestamp":"2026-08-19T00:42:08.907Z"},"type":"attachment"}` ~ "\n";

unittest {
    auto first = nextQueuedPrompt(transcript, 0);
    assert(first.ok);
    assert(first.prompt == "also");

    auto second = nextQueuedPrompt(transcript, first.next);
    assert(second.ok);
    assert(second.prompt == "btw");

    auto done = nextQueuedPrompt(transcript, second.next);
    assert(!done.ok);
}

// What the walk finds has to land in the store, or the corpus still answers
// from prompts alone and every gate reading it is blind to half of what was
// said.

import queued : ingestQueued, QUEUED_PREDICATE;
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

unittest {
    auto db = memDb();
    assert(ingestQueued(db, transcript, "sess-1", "/tmp") == 2);

    enum both = "SELECT count(*) FROM attestations "
        ~ "WHERE json_extract(predicates,'$[0]') = 'QueuedPromptSubmit'\0";
    assert(counted(db, both.ptr) == 2);

    enum one = "SELECT count(*) FROM attestations "
        ~ "WHERE json_extract(attributes,'$.prompt') = 'btw'\0";
    assert(counted(db, one.ptr) == 1, "the prompt is stored where a reader looks for it");

    enum scoped = "SELECT count(*) FROM attestations "
        ~ "WHERE json_extract(contexts,'$[0]') = 'session:sess-1'\0";
    assert(counted(db, scoped.ptr) == 2, "an approval belongs to the session that gave it");

    sqlite3_close(db);
}

unittest {
    auto db = memDb();
    // Ingesting the same bytes twice would double every word you typed, and a
    // window counting the last three messages would read one of them as three.
    assert(ingestQueued(db, transcript, "sess-2", "/tmp") == 2);
    assert(ingestQueued(db, transcript, "sess-2", "/tmp") == 0);

    enum n = "SELECT count(*) FROM attestations "
        ~ "WHERE json_extract(predicates,'$[0]') = 'QueuedPromptSubmit'\0";
    assert(counted(db, n.ptr) == 2);
    sqlite3_close(db);
}

unittest {
    // The name is what every consumer queries on, so it is stated once.
    assert(QUEUED_PREDICATE == "QueuedPromptSubmit");
}

unittest {
    // A transcript ground has already read to the end of yields nothing, and a
    // final line with no newline after it is still a line.
    assert(!nextQueuedPrompt("", 0).ok);
    assert(!nextQueuedPrompt(transcript, transcript.length).ok);

    enum unterminated = `{"attachment":{"type":"queued_command","prompt":"tail","origin":{"kind":"human"}},"type":"attachment"}`;
    auto hit = nextQueuedPrompt(unterminated, 0);
    assert(hit.ok);
    assert(hit.prompt == "tail");
    assert(hit.next == unterminated.length);
}
