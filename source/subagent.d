/// A subagent runs on the model the models block picks, at that model's own
/// effort setting.
///
/// "the same rules for ritual agents should apply to subagents, they should cohere"
///
/// A session starts a subagent with the Agent tool, and a call that names no
/// model starts it on the session's own, at the session's effort. What the
/// call's input becomes is made here; the handler answers with it.
module subagent;

/// What an Agent call's input became.
struct Set {
    /// How much of the buffer it is.
    size_t len;
    /// The input was an object ground read to its end, and what it became fit.
    bool fit;
    /// What it became is not what the call asked for.
    bool changed;
    /// The call is a fork, which runs on its session's model whatever it is told.
    bool fork;
}

private enum NONE = size_t.max;

private size_t skipWs(const(char)[] s, size_t i) {
    while (i < s.length && (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t')) i++;
    return i;
}

// The index after the string that opens at i, or NONE when it never closes.
private size_t afterString(const(char)[] s, size_t i) {
    i++;
    while (i < s.length) {
        if (s[i] == '\\') { i += 2; continue; }
        if (s[i] == '"') return i + 1;
        i++;
    }
    return NONE;
}

// The index after the value that starts at i, or NONE when it does not end.
private size_t afterValue(const(char)[] s, size_t i) {
    if (i >= s.length) return NONE;
    if (s[i] == '"') return afterString(s, i);
    if (s[i] == '{' || s[i] == '[') {
        size_t depth = 0;
        while (i < s.length) {
            auto c = s[i];
            if (c == '"') {
                i = afterString(s, i);
                if (i == NONE) return NONE;
                continue;
            }
            if (c == '{' || c == '[') depth++;
            else if (c == '}' || c == ']') {
                depth--;
                if (depth == 0) return i + 1;
            }
            i++;
        }
        return NONE;
    }
    auto start = i;
    while (i < s.length && s[i] != ',' && s[i] != '}' && s[i] != ' '
           && s[i] != '\n' && s[i] != '\r' && s[i] != '\t') i++;
    return i > start ? i : NONE;
}

// Whether a value is the string wanted, and nothing else.
private bool isString(const(char)[] val, const(char)[] want) {
    return val.length == want.length + 2 && val[0] == '"' && val[$ - 1] == '"'
        && val[1 .. $ - 1] == want;
}

/// The input of an Agent call with its model set to the one picked and no
/// effort of its own, written into dest: how hard the model thinks is that
/// model's setting, as it is for a ritual's agent. Only the call's own keys
/// are read: a prompt that quotes one is text.
Set agentInput(const(char)[] region, const(char)[] model, char[] dest) {
    Set none;
    size_t n = 0;
    bool full = false;
    void putc(char c) { if (n < dest.length) dest[n++] = c; else full = true; }
    void put(const(char)[] t) { foreach (c; t) putc(c); }

    auto i = skipWs(region, 0);
    if (i >= region.length || region[i] != '{') return none;
    i++;
    putc('{');

    bool first = true;
    size_t models = 0, efforts = 0;
    bool modelIs = false;
    bool fork = false;

    while (true) {
        i = skipWs(region, i);
        if (i >= region.length) return none;
        if (region[i] == '}') { i++; break; }
        if (region[i] == ',') { i++; continue; }
        if (region[i] != '"') return none;

        auto keyStart = i;
        auto keyEnd = afterString(region, i);
        if (keyEnd == NONE) return none;
        auto key = region[keyStart + 1 .. keyEnd - 1];

        i = skipWs(region, keyEnd);
        if (i >= region.length || region[i] != ':') return none;
        auto valStart = skipWs(region, i + 1);
        auto valEnd = afterValue(region, valStart);
        if (valEnd == NONE) return none;
        auto val = region[valStart .. valEnd];
        i = valEnd;

        if (key == "model") {
            models++;
            modelIs = isString(val, model);
            continue;
        }
        if (key == "effort") {
            efforts++;
            continue;
        }
        if (key == "subagent_type" && isString(val, "fork")) fork = true;

        if (!first) putc(',');
        first = false;
        put(region[keyStart .. valEnd]);
    }
    if (skipWs(region, i) != region.length) return none;

    if (!first) putc(',');
    put(`"model":"`);
    foreach (c; model) {
        if (c == '"' || c == '\\') putc('\\');
        putc(c);
    }
    put(`"}`);
    if (full) return none;

    Set r;
    r.len = n;
    r.fit = true;
    r.fork = fork;
    // A key named twice is read by its last, so only one that is the one
    // picked is the call already being what was picked.
    r.changed = !(models == 1 && modelIs) || efforts > 0;
    return r;
}

/// Where a session keeps its notes of the subagents it started: beside its
/// transcript, under the transcript's name without its .jsonl. Empty for a
/// path that is no transcript, and for one that does not fit.
const(char)[] subagentsDir(const(char)[] transcript, char[] dest) {
    enum ext = ".jsonl";
    enum tail = "/subagents";
    if (transcript.length <= ext.length || transcript[$ - ext.length .. $] != ext) return dest[0 .. 0];
    auto stem = transcript[0 .. $ - ext.length];
    if (stem.length + tail.length >= dest.length) return dest[0 .. 0];
    size_t n = 0;
    foreach (c; stem) dest[n++] = c;
    foreach (c; tail) dest[n++] = c;
    return dest[0 .. n];
}

// The string a note holds under a key, or empty when it holds none there.
private const(char)[] noted(const(char)[] meta, string key, char[] buf) {
    import parse : extractJsonString;
    auto v = extractJsonString(meta, key, &buf[0], buf.length);
    return v is null ? buf[0 .. 0] : v;
}

/// A subagent whose call named no model was started on its session's own, and
/// the note of it holds no model.
bool namedNoModel(const(char)[] meta) {
    char[128] buf = 0;
    return noted(meta, `"model"`, buf[]).length == 0;
}

/// Whether a note is the one of the agent a message is sent to: by its id,
/// which the note's file is named after, or by its name.
bool isAgent(const(char)[] file, const(char)[] meta, const(char)[] to) {
    enum head = "agent-";
    enum ext = ".meta.json";
    if (to.length == 0) return false;
    if (file.length <= head.length + ext.length) return false;
    if (file[0 .. head.length] != head || file[$ - ext.length .. $] != ext) return false;
    if (file[head.length .. $ - ext.length] == to) return true;
    char[512] buf = 0;
    return noted(meta, `"description"`, buf[]) == to;
}
