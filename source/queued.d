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

// Where the walk is, and what it found there. The prompt is a slice of one
// shared buffer, so it is only valid until the next call.
struct QueuedHit {
    bool ok;
    size_t next;
    const(char)[] prompt;
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
        if (found !is null) return QueuedHit(true, after, found);
        i = after;
    }
    return QueuedHit(false, content.length, null);
}
