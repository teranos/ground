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
    ~ `{"attachment":{"type":"queued_command","prompt":"also","origin":{"kind":"human"}},"type":"attachment"}` ~ "\n"
    ~ `{"message":{"role":"assistant"},"type":"assistant"}` ~ "\n"
    ~ `{"attachment":{"type":"queued_command","prompt":"btw","origin":{"kind":"human"}},"type":"attachment"}` ~ "\n";

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
