module collected;

// "for knowing what is incoming"
// "and also what is outbound,"
//
// What agents said to an agent waits at the node until it is delivered or a
// person releases it (QNTX server/collected.go). mycelia keeps the node's
// answer under ~/.local/state/ug/collected; this reads it for the session it
// runs in, by the DID of the session's own key.

import zbuf : ZBuf;

enum BOOK_COMMAND = q"EOS
# what waits for this session, and what it said that waits for another, as mycelia kept them:
ground collected
EOS";

// How old an answer may be before mycelia is taken to have stopped asking: as
// ground_tmux takes it (ug/mycelia.d SILENT).
enum SILENT = 60;

// What is kept for did, said into out_: 0 when it is the node's answer, 1 when
// it is what kept mycelia from one.
int collectedFor(const(char)[] kept, const(char)[] did, long now, ref ZBuf out_) {
    import libjsonc : json_object, json_type, json_object_get_type, json_object_array_length,
        json_object_array_get_idx, json_object_get_string, json_object_get_string_len,
        json_object_put, jsonField, parseJson;

    out_.reset();
    long at = 0;
    size_t i = 0;
    while (i < kept.length && kept[i] >= '0' && kept[i] <= '9') at = at * 10 + (kept[i++] - '0');
    if (i == 0 || i >= kept.length || kept[i] != '\n') {
        out_.put("mycelia has kept nothing: it has not asked the node\n");
        return 1;
    }
    auto answer = kept[i + 1 .. $];
    if (now - at > SILENT) {
        out_.put("mycelia last asked the node ");
        out_.putUint(cast(ulong)(now - at));
        out_.put("s ago: what it kept is not current\n");
        return 1;
    }
    auto o = parseJson(answer);
    scope (exit) json_object_put(o);
    auto all = jsonField(o, "collected");
    if (json_object_get_type(all) != json_type.array) {
        out_.put("mycelia could not ask the node: ");
        out_.put(answer);
        out_.put("\n");
        return 1;
    }

    static const(char)[] text(json_object* v) {
        if (json_object_get_type(v) != json_type.string_) return null;
        return json_object_get_string(v)[0 .. cast(size_t) json_object_get_string_len(v)];
    }

    auto n = json_object_array_length(all);

    // "i want both incomign and outgoing"
    // Both are said every time; one with nothing in it says so.
    bool waits = false;

    // What waits for did.
    foreach (k; 0 .. n) {
        auto one = json_object_array_get_idx(all, k);
        if (text(jsonField(one, "did")) != did) continue;
        auto waiting = jsonField(one, "waiting");
        if (json_object_get_type(waiting) != json_type.array || json_object_array_length(waiting) == 0) continue;
        waits = true;
        out_.put("Waiting for you, due ");
        out_.put(text(jsonField(one, "due")));
        out_.put(":\n");
        foreach (w; 0 .. json_object_array_length(waiting)) {
            auto said = json_object_array_get_idx(waiting, w);
            out_.put("  ");
            out_.put(text(jsonField(said, "from")));
            out_.put(", ");
            out_.put(text(jsonField(said, "at")));
            out_.put(": ");
            out_.put(text(jsonField(said, "says")));
            out_.put("\n");
        }
    }

    if (!waits) out_.put("Waiting for you: nothing\n");

    // What did said that waits for another.
    bool saidHeader = false;
    foreach (k; 0 .. n) {
        auto one = json_object_array_get_idx(all, k);
        auto waiting = jsonField(one, "waiting");
        if (json_object_get_type(waiting) != json_type.array) continue;
        foreach (w; 0 .. json_object_array_length(waiting)) {
            auto said = json_object_array_get_idx(waiting, w);
            if (text(jsonField(said, "from_did")) != did) continue;
            if (!saidHeader) { out_.put("You said, waiting:\n"); saidHeader = true; }
            out_.put("  to ");
            out_.put(text(jsonField(one, "to")));
            out_.put(", due ");
            out_.put(text(jsonField(one, "due")));
            out_.put(": ");
            out_.put(text(jsonField(said, "says")));
            out_.put("\n");
        }
    }

    if (!saidHeader) out_.put("You said, waiting: nothing\n");
    return 0;
}

// ground collected: what mycelia kept, for the session this runs in.
int handleCollected() {
    import core.stdc.stdio : stdout, stderr, fputs, fopen, fread, fclose;
    import core.stdc.stdlib : getenv;
    import core.stdc.time : time;
    import naming : sessionKeyFile;
    import signed : keptKey, putDID;

    auto sid = getenv("CLAUDE_CODE_SESSION_ID\0".ptr);
    if (sid is null) {
        fputs("ground collected: CLAUDE_CODE_SESSION_ID is not set, so this is no session's\n", stderr);
        return 1;
    }
    size_t sn = 0;
    while (sid[sn] != 0) sn++;
    auto key = keptKey(sessionKeyFile(sid[0 .. sn]));
    if (!key.held) {
        fputs("ground collected: this session has no key of its own, so no DID to read for: ground name gives it one\n", stderr);
        return 1;
    }
    __gshared ZBuf did;
    did.reset();
    putDID(did, key.public_[]);

    auto home = getenv("HOME\0".ptr);
    if (home is null) {
        fputs("ground collected: HOME names no home to read what mycelia kept from\n", stderr);
        return 1;
    }
    size_t hn = 0;
    while (home[hn] != 0) hn++;
    __gshared ZBuf path;
    path.reset();
    path.put(home[0 .. hn]);
    path.put("/.local/state/ug/collected");

    __gshared char[262144 + 32] kept;
    size_t got = 0;
    auto f = fopen(path.ptr(), "rb");
    if (f !is null) {
        got = fread(kept.ptr, 1, kept.length, f);
        fclose(f);
    }

    __gshared ZBuf said;
    auto rc = collectedFor(kept[0 .. got], did.slice(), cast(long) time(null), said);
    if (rc != 0) fputs("ground collected: ", stderr);
    fputs(said.ptr(), rc == 0 ? stdout : stderr);
    return rc;
}
