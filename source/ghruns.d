module ghruns;

// The GitHub Actions runs list, read without jq.

// A push starts several workflows at once and the API returns them newest
// first. Reading one run reads whichever finished last, so a red lint under a
// green deploy is never seen.

import parse : extractJsonString;

// Where the walk is, and the one run it found there. The three fields are
// slices of shared buffers, valid only until the next call.
struct RunHit {
    bool ok;
    size_t next;
    const(char)[] name;
    const(char)[] conclusion;
    const(char)[] status;
    const(char)[] event;
    long id;
}

// The next object of the workflow_runs array at or after `from`. Objects are
// found by brace depth rather than by key order, because the API is free to
// reorder fields and nests objects inside every run.
RunHit nextRun(const(char)[] json, size_t from) {
    size_t i = from;

    // The array's own opening bracket is skipped on the first call by starting
    // the search at the key, so a run object is the first brace after it.
    if (from == 0) {
        auto at = indexOf(json, `"workflow_runs"`);
        if (at < 0) return RunHit(false, json.length, null, null, null, null, 0);
        i = cast(size_t) at;
    }

    while (i < json.length && json[i] != '{') {
        if (json[i] == ']') return RunHit(false, json.length, null, null, null, null, 0);
        i++;
    }
    if (i >= json.length) return RunHit(false, json.length, null, null, null, null, 0);

    size_t depth = 0;
    size_t start = i;
    bool inStr = false;
    while (i < json.length) {
        char c = json[i];
        if (inStr) {
            if (c == '\\') { i += 2; continue; }
            if (c == '"') inStr = false;
            i++;
            continue;
        }
        if (c == '"') { inStr = true; i++; continue; }
        if (c == '{') depth++;
        if (c == '}') {
            depth--;
            if (depth == 0) { i++; break; }
        }
        i++;
    }
    if (depth != 0) return RunHit(false, json.length, null, null, null, null, 0);

    auto obj = json[start .. i];

    __gshared char[256] nameBuf = 0;
    __gshared char[64] conclBuf = 0;
    __gshared char[64] statusBuf = 0;
    __gshared char[64] eventBuf = 0;

    auto name = extractJsonString(obj, `"name"`, &nameBuf[0], nameBuf.length);
    auto concl = extractJsonString(obj, `"conclusion"`, &conclBuf[0], conclBuf.length);
    auto status = extractJsonString(obj, `"status"`, &statusBuf[0], statusBuf.length);
    auto event = extractJsonString(obj, `"event"`, &eventBuf[0], eventBuf.length);

    return RunHit(true, i,
                  name is null ? "" : name,
                  concl is null ? "" : concl,
                  status is null ? "" : status,
                  event is null ? "" : event,
                  jsonNumber(obj, `"id"`));
}

// The run's own id, for asking after its log. extractJsonString cannot read
// it: the value is a bare number and carries no quotes to find it by.
private long jsonNumber(const(char)[] obj, const(char)[] key) {
    auto at = indexOf(obj, key);
    if (at < 0) return 0;

    size_t i = cast(size_t) at + key.length;
    while (i < obj.length && (obj[i] == ':' || obj[i] == ' ')) i++;

    long v = 0;
    bool any = false;
    while (i < obj.length && obj[i] >= '0' && obj[i] <= '9') {
        v = v * 10 + (obj[i] - '0');
        any = true;
        i++;
    }
    return any ? v : 0;
}

private ptrdiff_t indexOf(const(char)[] h, const(char)[] needle) {
    if (needle.length == 0 || needle.length > h.length) return -1;
    foreach (i; 0 .. h.length - needle.length + 1)
        if (h[i .. i + needle.length] == needle) return cast(ptrdiff_t) i;
    return -1;
}

// What the whole list amounts to. `failed` is the answer a person waiting on a
// push actually wants, and it is false only when no workflow reported one.
enum MAX_NAME = 64;
enum MAX_WORD = 32;

// One failing workflow, owning its own text. The cursor hands back slices of
// shared buffers, and a list of those would be one name repeated.
struct FailedRun {
    char[MAX_NAME] nameBuf = 0;
    size_t nameLen;
    char[MAX_WORD] conclBuf = 0;
    size_t conclLen;
    char[MAX_WORD] eventBuf = 0;
    size_t eventLen;
    long id;

    const(char)[] name() const return { return nameBuf[0 .. nameLen]; }
    const(char)[] conclusion() const return { return conclBuf[0 .. conclLen]; }
    const(char)[] event() const return { return eventBuf[0 .. eventLen]; }
}

struct RunVerdict {
    size_t workflows;
    bool running;
    size_t failedCount;
    FailedRun[MAX_WORKFLOWS] failures;
}

// A conclusion nobody would call green. cancelled and timed_out end a run
// without a verdict, and to a reader waiting on one that is a failure.
private bool isRed(const(char)[] c) {
    return c == "failure" || c == "cancelled" || c == "timed_out"
        || c == "startup_failure" || c == "action_required";
}

enum MAX_WORKFLOWS = 32;

// Newest first, so the first sighting of a name is the run that counts and
// every later one is history. Without that an older green buries a new red.
RunVerdict rollupRuns(const(char)[] json) {
    RunVerdict v;

    char[MAX_NAME][MAX_WORKFLOWS] seen;
    size_t[MAX_WORKFLOWS] seenLen;
    size_t seenCount = 0;

    size_t from = 0;
    while (seenCount < MAX_WORKFLOWS) {
        auto r = nextRun(json, from);
        if (!r.ok) break;
        from = r.next;
        if (r.name.length == 0 || r.name.length > MAX_NAME) continue;

        bool already = false;
        foreach (s; 0 .. seenCount)
            if (seen[s][0 .. seenLen[s]] == r.name) { already = true; break; }
        if (already) continue;

        foreach (k, ch; r.name) seen[seenCount][k] = ch;
        seenLen[seenCount] = r.name.length;
        seenCount++;
        v.workflows++;

        if (isRed(r.conclusion)) {
            if (v.failedCount < v.failures.length) {
                auto f = &v.failures[v.failedCount];
                foreach (k, ch; r.name) f.nameBuf[k] = ch;
                f.nameLen = r.name.length;
                if (r.conclusion.length <= MAX_WORD) {
                    foreach (k, ch; r.conclusion) f.conclBuf[k] = ch;
                    f.conclLen = r.conclusion.length;
                }
                if (r.event.length <= MAX_WORD) {
                    foreach (k, ch; r.event) f.eventBuf[k] = ch;
                    f.eventLen = r.event.length;
                }
                f.id = r.id;
                v.failedCount++;
            }
        } else if (r.conclusion.length == 0) {
            v.running = true;
        }
    }

    return v;
}
