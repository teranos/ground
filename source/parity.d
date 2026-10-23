module parity;

// "the way i expect ground parity to work is run ground parity and have a real live picture of what is going on based on the versions it has access to, the versions it has no access to stay in the sqlite until ran again with a correct binary"

import core.stdc.stdio : stdout, stderr, fputs, fwrite;
import hooks : HookEvent;
import parse : Reads;
import db : ZBuf;
static import parse;

enum BOOK_COMMAND = q"EOS
# what ground covers of each pinned agent's hook contract, per event and version,
# and what ground code covers of the pinned ACP schema, per method:
ground parity
# one event's keys per version, covered and missing:
ground parity PostToolUse
# one ACP method's, read and written by ground code:
ground parity session/prompt
EOS";

// --- sha256: a binary is the pinned one or it is not measured ---

private static immutable uint[64] K = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

private static immutable uint[8] H0 = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

private uint rotr(uint x, uint n) { return (x >> n) | (x << (32 - n)); }

private void compress(T)(ref uint[8] h, const(T)[] b) {
    uint[64] w;
    foreach (i; 0 .. 16)
        w[i] = (cast(uint) cast(ubyte) b[i * 4] << 24) | (cast(uint) cast(ubyte) b[i * 4 + 1] << 16)
             | (cast(uint) cast(ubyte) b[i * 4 + 2] << 8) | cast(uint) cast(ubyte) b[i * 4 + 3];
    foreach (i; 16 .. 64) {
        uint s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint a = h[0], bb = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    foreach (i; 0 .. 64) {
        uint t1 = hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
        uint t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & bb) ^ (a & c) ^ (bb & c));
        hh = g; g = f; f = e; e = d + t1; d = c; c = bb; bb = a; a = t1 + t2;
    }
    h[0] += a; h[1] += bb; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

void sha256(T)(const(T)[] data, ref char[64] hex) {
    uint[8] h;
    foreach (i; 0 .. 8) h[i] = H0[i]; // CTFE aliases a whole-array copy of an immutable
    size_t full = data.length / 64 * 64;
    for (size_t i = 0; i < full; i += 64) compress(h, data[i .. i + 64]);

    ubyte[128] tail = 0;
    size_t rest = data.length - full;
    foreach (i; 0 .. rest) tail[i] = cast(ubyte) data[full + i];
    tail[rest] = 0x80;
    size_t tlen = rest + 9 <= 64 ? 64 : 128;
    ulong bits = cast(ulong) data.length * 8;
    foreach (i; 0 .. 8) tail[tlen - 1 - i] = cast(ubyte)(bits >> (8 * i));
    compress(h, tail[0 .. 64]);
    if (tlen == 128) compress(h, tail[64 .. 128]);

    enum digits = "0123456789abcdef";
    foreach (i; 0 .. 8)
        foreach (j; 0 .. 8)
            hex[i * 8 + j] = digits[(h[i] >> (28 - 4 * j)) & 0xf];
}

char[64] sha256Hex()(const(char)[] s) {
    char[64] hex;
    sha256(s, hex);
    return hex;
}

// --- the pins, read out of flake.nix, the one place they are written ---

struct Pin { string agent; string release; string sha256; }

version (OSX) {
    version (AArch64) { enum claudePlatform = "darwin-arm64"; enum codexTarget = "aarch64-apple-darwin"; }
    else { enum claudePlatform = "darwin-x64"; enum codexTarget = "x86_64-apple-darwin"; }
} else {
    version (AArch64) { enum claudePlatform = "linux-arm64"; enum codexTarget = "aarch64-unknown-linux-musl"; }
    else { enum claudePlatform = "linux-x64"; enum codexTarget = "x86_64-unknown-linux-musl"; }
}

private bool startsAt(const(char)[] text, size_t at, const(char)[] s) {
    return at + s.length <= text.length && text[at .. at + s.length] == s;
}

// Where a nix attribute of this name is assigned with the opener given, or -1.
private ptrdiff_t assigned()(string text, string key, string opener) {
    size_t from = 0;
    while (true) {
        auto at = indexIn(text, key, from);
        if (at < 0) return -1;
        auto after = cast(size_t) at + key.length;
        if (startsAt(text, after, opener)) return cast(ptrdiff_t) after + opener.length;
        from = after;
    }
}

// The 64 hex characters a nix attribute of this name is set to, or null.
private string hexAfter()(string text, string key) {
    auto from = assigned(text, key, ` = "`);
    if (from < 0 || cast(size_t) from + 64 > text.length) return null;
    return text[cast(size_t) from .. cast(size_t) from + 64];
}

struct PinSet { Pin[8] items; size_t count; }

PinSet readPins()(string flake) {
    PinSet found;
    foreach (i; 0 .. flake.length) {
        string agent;
        if (startsAt(flake, i, `claude "`)) agent = "claude";
        else if (startsAt(flake, i, `codex "`)) agent = "codex";
        else if (startsAt(flake, i, `acp "`)) agent = "acp";
        else continue;
        auto from = i + agent.length + 2;
        auto close = indexIn(flake[from .. $], `"`);
        if (close < 0) continue;
        auto release = flake[from .. from + close];
        // The block closes where its braces balance: a platform's own block is nested in it.
        auto open = indexIn(flake, "{", from + cast(size_t) close);
        if (open < 0) continue;
        size_t end = flake.length;
        int depth = 0;
        foreach (p; cast(size_t) open .. flake.length) {
            if (flake[p] == '{') depth++;
            else if (flake[p] == '}' && --depth == 0) { end = p + 1; break; }
        }
        auto block = flake[from .. end];
        string sha;
        if (agent == "claude") sha = hexAfter(block, claudePlatform);
        else if (agent == "acp") sha = hexAfter(block, "schema");
        else {
            auto t = assigned(block, codexTarget, " = {");
            if (t >= 0) sha = hexAfter(block[cast(size_t) t .. $], "binary");
        }
        if (sha !is null && found.count < found.items.length) found.items[found.count++] = Pin(agent, release, sha);
    }
    return found;
}

private static immutable PinSet pinSet = readPins(import("flake.nix"));
const(Pin)[] pins() { return pinSet.items[0 .. pinSet.count]; }
static assert(pinSet.count > 0, "flake.nix pins no agent for this platform");

// --- key lists: comma-joined, in the order they were met ---

alias Keys = KeysOf!4096;

struct KeysOf(size_t capacity) {
    char[capacity] data = 0;
    size_t len;
    bool full; // a key that did not fit; said, never dropped in silence

    void add(const(char)[] k) {
        if (k.length == 0 || has(k)) return;
        if (len + k.length + 1 >= data.length) { full = true; return; }
        if (len > 0) data[len++] = ',';
        foreach (c; k) data[len++] = c;
    }
    bool has(const(char)[] k) const { return listHas(data[0 .. len], k); }
    const(char)[] slice() const return { return data[0 .. len]; }
}

bool listHas(const(char)[] list, const(char)[] k) {
    size_t s = 0;
    foreach (i; 0 .. list.length + 1)
        if (i == list.length || list[i] == ',') {
            if (list[s .. i] == k) return true;
            s = i + 1;
        }
    return false;
}

int countOf(const(char)[] list) {
    if (list.length == 0) return 0;
    int n = 1;
    foreach (c; list) if (c == ',') n++;
    return n;
}

// How many of spec's keys ground has.
int covered(const(char)[] spec, const(char)[] ground) {
    if (spec.length == 0) return 0;
    int n = 0;
    size_t s = 0;
    foreach (i; 0 .. spec.length + 1)
        if (i == spec.length || spec[i] == ',') {
            if (listHas(ground, spec[s .. i])) n++;
            s = i + 1;
        }
    return n;
}

// --- finding things in a binary of a quarter gigabyte ---

extern (C) void* memmem(const(void)* hay, size_t hayLen, const(void)* needle, size_t needleLen);

ptrdiff_t indexIn(const(char)[] hay, const(char)[] needle, size_t from = 0) {
    if (needle.length == 0 || from > hay.length || needle.length > hay.length - from) return -1;
    if (__ctfe) {
        foreach (i; from .. hay.length - needle.length + 1)
            if (hay[i .. i + needle.length] == needle) return i;
        return -1;
    }
    auto p = memmem(hay.ptr + from, hay.length - from, needle.ptr, needle.length);
    return p is null ? -1 : cast(const(char)*) p - hay.ptr;
}

private ptrdiff_t lastIndexIn(const(char)[] hay, const(char)[] needle) {
    if (needle.length > hay.length) return -1;
    for (size_t i = hay.length - needle.length + 1; i-- > 0;)
        if (hay[i .. i + needle.length] == needle) return i;
    return -1;
}

private bool isIdent(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

private const(char)[] joined(char[] buf, const(char)[] a, const(char)[] b, const(char)[] c) {
    size_t n = 0;
    foreach (ch; a) if (n < buf.length) buf[n++] = ch;
    foreach (ch; b) if (n < buf.length) buf[n++] = ch;
    foreach (ch; c) if (n < buf.length) buf[n++] = ch;
    return buf[0 .. n];
}

// codex names its schema files in kebab case; ground's events are PascalCase.
const(char)[] pascalInto(const(char)[] kebab, char[] buf) {
    size_t n = 0;
    bool up = true;
    foreach (c; kebab) {
        if (c == '-') { up = true; continue; }
        if (n < buf.length) buf[n++] = up && c >= 'a' && c <= 'z' ? cast(char)(c - 32) : c;
        up = false;
    }
    return buf[0 .. n];
}

Keys pascalOf()(string kebab) {
    char[64] buf;
    Keys k;
    k.add(pascalInto(kebab, buf));
    return k;
}

// --- codex: JSON Schema documents, pretty-printed two spaces deep ---

// The keys on lines this many spaces deep, from pos until the object closes.
private void keysAtIndent(const(char)[] doc, size_t pos, size_t indent, ref Keys keys) {
    size_t i = pos;
    while (i < doc.length) {
        auto nl = indexIn(doc, "\n", i);
        if (nl < 0) return;
        size_t j = cast(size_t) nl + 1;
        size_t spaces = 0;
        while (j < doc.length && doc[j] == ' ') { spaces++; j++; }
        if (j >= doc.length) return;
        if (spaces + 2 == indent && doc[j] == '}') return;
        if (spaces == indent && doc[j] == '"') {
            auto close = indexIn(doc, `"`, j + 1);
            if (close < 0) return;
            keys.add(doc[j + 1 .. cast(size_t) close]);
        }
        i = j;
    }
}

// One codex schema's keys: its top-level properties and, where it has one,
// the properties of the hookSpecificOutput definition it refers to.
bool codexSchema(const(char)[] text, const(char)[] title, ref Keys keys) {
    char[160] nb;
    auto at = indexIn(text, joined(nb, `"title": "`, title, `"`));
    if (at < 0) return false;
    auto start = lastIndexIn(text[0 .. cast(size_t) at], `"$schema"`);
    if (start < 0) return false;
    auto doc = text[cast(size_t) start .. cast(size_t) at];

    enum props = "\n  \"properties\": {";
    auto p = indexIn(doc, props);
    if (p < 0) return true;
    keysAtIndent(doc, cast(size_t) p + props.length, 4, keys);

    if (!keys.has("hookSpecificOutput")) return true;
    auto hp = indexIn(doc, "\n    \"hookSpecificOutput\": {", cast(size_t) p);
    if (hp < 0) return true;
    enum refTo = "#/definitions/";
    auto r = indexIn(doc, refTo, cast(size_t) hp);
    if (r < 0) return true;
    auto nameFrom = cast(size_t) r + refTo.length;
    auto nameEnd = indexIn(doc, `"`, nameFrom);
    if (nameEnd < 0) return true;
    char[160] db;
    auto d = indexIn(doc, joined(db, "\n    \"", doc[nameFrom .. cast(size_t) nameEnd], "\": {"));
    if (d < 0) return true;
    enum defProps = "\n      \"properties\": {";
    auto dp = indexIn(doc, defProps, cast(size_t) d);
    if (dp < 0) return true;
    keysAtIndent(doc, cast(size_t) dp + defProps.length, 8, keys);
    return true;
}

Keys codexKeys()(string text, string title) {
    Keys k;
    codexSchema(text, title, k);
    return k;
}

// --- acp: one JSON Schema document, its definitions four spaces deep ---

enum acpMethodKey = "\n      \"x-method\": \"";

private bool endsWith(const(char)[] s, const(char)[] tail) {
    return s.length >= tail.length && s[$ - tail.length .. $] == tail;
}

// One method's keys from ground code's side, as a hook's are from ground's: in
// is what it reads, out is what it writes. Every definition naming the method
// gives its top-level properties to a side. A request or notification the
// agent handles is read and its response written; one the client handles is
// the other way round. Either peer may send a protocol method, so it is both.
bool acpSpec(const(char)[] text, const(char)[] method, ref Keys input, ref Keys output) {
    char[160] nb;
    auto needle = joined(nb, acpMethodKey, method, `"`);
    bool found = false;
    size_t from = 0;
    while (true) {
        auto at = indexIn(text, needle, from);
        if (at < 0) return found;
        from = cast(size_t) at + needle.length;
        auto start = lastIndexIn(text[0 .. cast(size_t) at], "\n    \"");
        auto end = indexIn(text, "\n    }", cast(size_t) at);
        if (start < 0 || end < 0) continue;
        auto nameFrom = cast(size_t) start + 6;
        auto nameEnd = indexIn(text, `"`, nameFrom);
        if (nameEnd < 0) continue;
        auto name = text[nameFrom .. cast(size_t) nameEnd];
        auto def = text[cast(size_t) start .. cast(size_t) end];

        enum sideKey = "\n      \"x-side\": \"";
        auto s = indexIn(def, sideKey);
        if (s < 0) continue;
        auto sideFrom = cast(size_t) s + sideKey.length;
        auto sideEnd = indexIn(def, `"`, sideFrom);
        if (sideEnd < 0) continue;
        auto side = def[sideFrom .. cast(size_t) sideEnd];
        found = true;

        bool sent = !endsWith(name, "Response");
        bool reads = side == "protocol" || (side == "agent") == sent;
        bool writes = side == "protocol" || !reads;
        enum props = "\n      \"properties\": {";
        auto p = indexIn(def, props);
        if (p < 0) continue;
        if (reads) keysAtIndent(def, cast(size_t) p + props.length, 8, input);
        if (writes) keysAtIndent(def, cast(size_t) p + props.length, 8, output);
    }
}

struct SpecKeys { Keys input; Keys output; }

SpecKeys acpKeys()(string text, string method) {
    SpecKeys k;
    acpSpec(text, method, k.input, k.output);
    return k;
}

// --- claude: zod objects in minified JS ---

// The keys of the object whose body runs from here, one brace deep. A string
// is skipped whole: a describe() holds colons and braces of its own.
private void objectKeys(const(char)[] text, size_t from, ref Keys keys) {
    int depth = 1, nest = 0;
    char quote = 0;
    size_t tok = size_t.max;
    auto limit = from + 262144 < text.length ? from + 262144 : text.length;
    for (size_t i = from; i < limit && depth > 0; i++) {
        char c = text[i];
        if (quote) {
            if (c == '\\') { i++; continue; }
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' || c == '\'' || c == '`') { quote = c; tok = size_t.max; }
        else if (c == '(' || c == '[' || c == '{') { if (c == '{') depth++; nest++; tok = size_t.max; }
        else if (c == ')' || c == ']' || c == '}') { if (c == '}') depth--; nest--; tok = size_t.max; }
        else if (c == ':' && depth == 1 && nest == 0 && tok != size_t.max) { keys.add(text[tok .. i]); tok = size_t.max; }
        else if (isIdent(c)) { if (tok == size_t.max) tok = i; }
        else tok = size_t.max;
    }
}

// The minifier names zod's helpers anew in each build, so an object is found by
// its keys alone: past a call, whatever the callee is called.
private ptrdiff_t afterCall(const(char)[] text, size_t i) {
    size_t j = i;
    while (j < text.length && isIdent(text[j])) j++;
    if (j == i || !startsAt(text, j, "()")) return -1;
    return cast(ptrdiff_t) j + 2;
}

// The body of the first object opening with `{first:x()` then `then`, from `from` on.
private ptrdiff_t openedBy(const(char)[] text, const(char)[] first, const(char)[] then, size_t from) {
    while (true) {
        auto at = indexIn(text, first, from);
        if (at < 0) return -1;
        auto p = afterCall(text, cast(size_t) at + first.length);
        if (p >= 0 && startsAt(text, cast(size_t) p, then)) return at + 1;
        from = cast(size_t) at + 1;
    }
}

// The name a `key:x("Name")` gives at `at`, or null.
private const(char)[] namedAt(const(char)[] text, size_t at, const(char)[] key) {
    size_t i = at + key.length;
    while (i < text.length && isIdent(text[i])) i++;
    if (!startsAt(text, i, `("`)) return null;
    auto from = i + 2;
    size_t end = from;
    while (end < text.length && end - from <= 64 && isIdent(text[end])) end++;
    if (end == from || !startsAt(text, end, `")`)) return null;
    return text[from .. end];
}

private ptrdiff_t findNamed(const(char)[] text, const(char)[] key, const(char)[] name, size_t from) {
    while (true) {
        auto at = indexIn(text, key, from);
        if (at < 0) return -1;
        if (namedAt(text, cast(size_t) at, key) == name) return at;
        from = cast(size_t) at + 1;
    }
}

// The base every event's input extends. The event objects and their
// hookSpecificOutput objects follow it, so every search starts here.
ptrdiff_t claudeAnchor(const(char)[] text) {
    auto p = openedBy(text, "{session_id:", ",transcript_path:", 0);
    while (p >= 0) {
        auto t = afterCall(text, cast(size_t) p + "session_id:".length);
        auto c = t < 0 ? -1 : afterCall(text, cast(size_t) t + ",transcript_path:".length);
        if (c >= 0 && startsAt(text, cast(size_t) c, ",cwd:")) return p;
        p = openedBy(text, "{session_id:", ",transcript_path:", cast(size_t) p);
    }
    return -1;
}

bool claudeInput(const(char)[] text, size_t anchor, const(char)[] event, ref Keys keys) {
    objectKeys(text, anchor, keys);
    auto e = findNamed(text, "hook_event_name:", event, anchor);
    if (e < 0) return false;
    objectKeys(text, cast(size_t) e, keys);
    return true;
}

bool claudeOutput(const(char)[] text, size_t anchor, const(char)[] event, ref Keys keys) {
    auto b = openedBy(text, "{continue:", ".optional(),suppressOutput:", anchor);
    if (b < 0) return false;
    objectKeys(text, cast(size_t) b, keys);
    auto e = findNamed(text, "hookEventName:", event, anchor);
    if (e >= 0) objectKeys(text, cast(size_t) e, keys);
    return true;
}

Keys claudeInputKeys()(string text, string event) {
    Keys k;
    auto a = claudeAnchor(text);
    if (a >= 0) claudeInput(text, cast(size_t) a, event, k);
    return k;
}

Keys claudeOutputKeys()(string text, string event) {
    Keys k;
    auto a = claudeAnchor(text);
    if (a >= 0) claudeOutput(text, cast(size_t) a, event, k);
    return k;
}

// --- ground's side, read out of its own source at compile time ---

private enum mainSource = import("source/main.d");

private string between()(string text, string from, string to) {
    auto s = indexIn(text, from);
    if (s < 0) return null;
    auto e = indexIn(text, to, cast(size_t) s);
    return e < 0 ? null : text[cast(size_t) s .. cast(size_t) e];
}

// What run() reads before it tells one event from another.
private enum commonRegion = between(mainSource, "int run(", "outEventName = eventName;");
static assert(commonRegion.length > 0, "main.d's run() no longer reads the event name where parity looks for it");

private string eventBlock()(string event) {
    auto key = "event == HookEvent." ~ event ~ ")";
    auto s = indexIn(mainSource, key);
    if (s < 0) return null;
    auto from = cast(size_t) s + key.length;
    auto e = indexIn(mainSource, "if (event == HookEvent.", from);
    return e < 0 ? mainSource[cast(size_t) s .. $] : mainSource[cast(size_t) s .. cast(size_t) e];
}

// The module main.d hands this event to, named by its import of the handler.
private string handlerOf()(string block) {
    auto h = indexIn(block, " : handle");
    if (h < 0) return null;
    auto imp = lastIndexIn(block[0 .. cast(size_t) h], "import ");
    return imp < 0 ? null : block[cast(size_t) imp + 7 .. cast(size_t) h];
}

private template handlerSource(string event) {
    private enum mod = handlerOf(eventBlock(event));
    static if (mod.length > 0) enum handlerSource = import("source/" ~ mod ~ ".d");
    else enum handlerSource = "";
}

// The key an extractor in parse.d is marked as reading, or null.
private string readKeyOf()(string name) {
    static foreach (m; __traits(allMembers, parse)) {
        static if (__traits(compiles, __traits(getAttributes, __traits(getMember, parse, m)))) {
            static foreach (a; __traits(getAttributes, __traits(getMember, parse, m))) {
                static if (is(typeof(a) == Reads)) {
                    if (name == m) return a.key;
                }
            }
        }
    }
    return null;
}

private bool commentLine()(string text, size_t lineStart) {
    size_t i = lineStart;
    while (i < text.length && (text[i] == ' ' || text[i] == '\t')) i++;
    return startsAt(text, i, "//");
}

// Reads: a call to a marked extractor, or a key handed to extractBool or
// extractJsonString as a backtick literal of its own.
alias GroundKeys = KeysOf!512;

GroundKeys readsIn()(string text) {
    GroundKeys keys;
    bool skip = commentLine(text, 0);
    for (size_t i = 0; i < text.length; i++) {
        char c = text[i];
        if (c == '\n') { skip = commentLine(text, i + 1); continue; }
        if (skip) continue;
        if (c == '`' && i + 1 < text.length && text[i + 1] == '"') {
            size_t j = i + 2;
            while (j < text.length && isIdent(text[j])) j++;
            if (j > i + 2 && startsAt(text, j, "\"`")) keys.add(text[i + 2 .. j]);
            continue;
        }
        if (isIdent(c) && (i == 0 || !isIdent(text[i - 1]))) {
            size_t j = i;
            while (j < text.length && isIdent(text[j])) j++;
            auto name = text[i .. j];
            if (j < text.length && text[j] == '(' && (startsAt(name, 0, "extract") || name == "toolResponseRegion")) {
                auto k = readKeyOf(name);
                if (k !is null) keys.add(k);
            }
            i = j - 1;
        }
    }
    return keys;
}

// Writes: the keys of the JSON a handler puts on stdout, directly or through
// a bare put() building its answer. A buffer's own put() writes an attestation.
GroundKeys writesIn()(string text) {
    GroundKeys keys;
    size_t lineStart = 0;
    foreach (i; 0 .. text.length + 1) {
        if (i < text.length && text[i] != '\n') continue;
        auto line = text[lineStart .. i];
        auto start = lineStart;
        lineStart = i + 1;
        if (commentLine(text, start)) continue;
        auto bare = indexIn(line, "put(");
        bool emits = indexIn(line, "stdout") >= 0 || (bare >= 0 && (bare == 0 || line[cast(size_t) bare - 1] != '.'));
        if (!emits) continue;
        foreach (q; 0 .. line.length) {
            if (line[q] != '"') continue;
            size_t j = q + 1;
            while (j < line.length && isIdent(line[j])) j++;
            if (j == q + 1) continue;
            size_t k = j;
            if (k < line.length && line[k] == '\\') k++;
            if (startsAt(line, k, "\":")) keys.add(line[q + 1 .. j]);
        }
    }
    return keys;
}

enum commonReads = readsIn(commonRegion);
enum groundReads(string event) = readsIn(commonRegion ~ "\n" ~ eventBlock(event) ~ "\n" ~ handlerSource!event);
enum groundWrites(string event) = writesIn(handlerSource!event);

struct GroundSide { string event; GroundKeys reads; GroundKeys writes; }

private enum eventCount = __traits(allMembers, HookEvent).length;

private GroundSide[eventCount] buildSides()() {
    GroundSide[eventCount] sides;
    static foreach (i, m; __traits(allMembers, HookEvent)) {
        sides[i] = GroundSide(m, groundReads!m, groundWrites!m);
        assert(!sides[i].reads.full && !sides[i].writes.full, "a ground key list outgrew its buffer: " ~ m);
    }
    return sides;
}

private static immutable GroundSide[eventCount] groundSides = buildSides();
private static immutable GroundSide unknownSide = GroundSide(null, commonReads, GroundKeys.init);

// An event ground dispatches nowhere still has what run() reads first.
ref immutable(GroundSide) sideOf(const(char)[] event) {
    foreach (ref s; groundSides) if (s.event == event) return s;
    return unknownSide;
}

// Ground code is the agent an ACP client talks to. It has no source yet, so it
// reads and writes none of what the protocol names.
private static immutable GroundSide codeSide = GroundSide(null, GroundKeys.init, GroundKeys.init);

ref immutable(GroundSide) sideFor(const(char)[] agent, const(char)[] event) {
    if (agent == "acp") return codeSide;
    return sideOf(event);
}

// --- the score ---

// "in is 50% and out is 50%"
// Per mille, rounded half up. A side the spec does not have weighs nothing; a
// spec with neither side is no cell.
int score(int inCov, int inTotal, int outCov, int outTotal) {
    if (inTotal == 0 && outTotal == 0) return -1;
    if (outTotal == 0) return (inCov * 2000 + inTotal) / (2 * inTotal);
    if (inTotal == 0) return (outCov * 2000 + outTotal) / (2 * outTotal);
    long num = cast(long)(inCov * outTotal + outCov * inTotal) * 500;
    long den = cast(long) inTotal * outTotal;
    return cast(int)((num * 2 + den) / (2 * den));
}

int percentOf(int perMille) { return (perMille + 5) / 10; }

private int meanOf(const(int)[] cells) {
    long sum = 0;
    int n = 0;
    foreach (c; cells) if (c >= 0) { sum += c; n++; }
    if (n == 0) return -1;
    return cast(int)((sum * 2 + n) / (2 * n));
}

// --- reading a pinned binary ---

import core.sys.posix.sys.mman : mmap, munmap, PROT_READ, MAP_PRIVATE, MAP_FAILED;
import core.sys.posix.fcntl : open, O_RDONLY;
import core.sys.posix.unistd : close;
import core.sys.posix.sys.stat : fstat, stat_t;

enum Access { absent, mismatch, live, empty }

struct Measured {
    Access access;
    char[64] sha = 0;
    char[1024] path = 0;
    size_t pathLen;
}

private void pathOf(ref const Pin pin, ref Measured m) {
    import db : getenv;
    auto home = getenv("HOME\0".ptr);
    size_t hl = 0;
    if (home !is null) while (home[hl] != 0) hl++;
    size_t n = 0;
    void add(const(char)[] s) { foreach (c; s) if (n + 1 < m.path.length) m.path[n++] = c; }
    if (home !is null) add(home[0 .. hl]);
    if (pin.agent == "claude") { add("/.local/share/claude/versions/"); add(pin.release); }
    // make install links the pinned schemas here from the store.
    else if (pin.agent == "acp") { add("/.local/lib/ground/acp/"); add(pin.release); add("/schema.json"); }
    else add("/.codex/packages/standalone/current/bin/codex");
    m.path[n] = 0;
    m.pathLen = n;
}

private struct Spec { char[64] event = 0; size_t eventLen; Keys input; Keys output; }
private __gshared Spec[64] specs;
private __gshared size_t specCount;
private __gshared bool specsFull;

private void addSpec(const(char)[] event, ref Keys input, ref Keys output) {
    if (specCount >= specs.length || event.length > specs[0].event.length) { specsFull = true; return; }
    auto s = &specs[specCount++];
    s.eventLen = event.length;
    foreach (i, c; event) s.event[i] = c; // a slice copy calls druntime
    s.input = input;
    s.output = output;
}

private void readClaude(const(char)[] text) {
    auto anchor = claudeAnchor(text);
    if (anchor < 0) return;
    enum key = "hook_event_name:";
    size_t from = cast(size_t) anchor;
    while (true) {
        auto at = indexIn(text, key, from);
        if (at < 0) break;
        from = cast(size_t) at + key.length;
        auto event = namedAt(text, cast(size_t) at, key);
        if (event is null) continue;
        Keys input, output;
        claudeInput(text, cast(size_t) anchor, event, input);
        claudeOutput(text, cast(size_t) anchor, event, output);
        addSpec(event, input, output);
    }
}

private void readCodex(const(char)[] text) {
    enum needle = `"title": "`;
    enum inSuffix = ".command.input";
    size_t from = 0;
    while (true) {
        auto at = indexIn(text, needle, from);
        if (at < 0) break;
        auto nameFrom = cast(size_t) at + needle.length;
        auto nameEnd = indexIn(text, `"`, nameFrom);
        if (nameEnd < 0) break;
        from = cast(size_t) nameEnd;
        auto title = text[nameFrom .. cast(size_t) nameEnd];
        if (title.length <= inSuffix.length || title[$ - inSuffix.length .. $] != inSuffix) continue;
        auto kebab = title[0 .. $ - inSuffix.length];
        char[160] ob;
        char[64] pb;
        Keys input, output;
        codexSchema(text, title, input);
        codexSchema(text, joined(ob, kebab, ".command.output", ""), output);
        addSpec(pascalInto(kebab, pb), input, output);
    }
}

private bool haveSpec(const(char)[] event) {
    foreach (i; 0 .. specCount)
        if (specs[i].event[0 .. specs[i].eventLen] == event) return true;
    return false;
}

private void readAcp(const(char)[] text) {
    size_t from = 0;
    while (true) {
        auto at = indexIn(text, acpMethodKey, from);
        if (at < 0) break;
        auto nameFrom = cast(size_t) at + acpMethodKey.length;
        auto nameEnd = indexIn(text, `"`, nameFrom);
        if (nameEnd < 0) break;
        from = cast(size_t) nameEnd;
        auto method = text[nameFrom .. cast(size_t) nameEnd];
        if (haveSpec(method)) continue;
        Keys input, output;
        acpSpec(text, method, input, output);
        addSpec(method, input, output);
    }
}

private Measured measure(ref const Pin pin) {
    Measured m;
    specCount = 0;
    specsFull = false;
    pathOf(pin, m);
    auto fd = open(m.path.ptr, O_RDONLY);
    if (fd < 0) return m;
    scope (exit) close(fd);
    stat_t st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) return m;
    auto size = cast(size_t) st.st_size;
    auto mem = mmap(null, size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (mem == MAP_FAILED) return m;
    scope (exit) munmap(mem, size);
    auto text = (cast(const(char)*) mem)[0 .. size];

    sha256(text, m.sha);
    if (m.sha[] != pin.sha256) { m.access = Access.mismatch; return m; }
    if (pin.agent == "claude") readClaude(text);
    else if (pin.agent == "acp") readAcp(text);
    else readCodex(text);
    m.access = specCount > 0 ? Access.live : Access.empty;
    return m;
}

// --- the store ---

import db : sqlite3, sqlite3_stmt, sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_bind_int64,
    sqlite3_step, sqlite3_finalize, sqlite3_exec, sqlite3_column_text, sqlite3_column_int64,
    SQLITE_OK, SQLITE_ROW, SQLITE_DONE, SQLITE_TRANSIENT;

private void bind(sqlite3_stmt* st, int idx, const(char)[] s) {
    sqlite3_bind_text(st, idx, s.ptr, cast(int) s.length, SQLITE_TRANSIENT);
}

// A live read replaces what the store held for that version, whole or not at all.
bool storeSpecs(sqlite3* db, const(char)[] agent, const(char)[] release, const(char)[] sha, long now) {
    if (sqlite3_exec(db, "BEGIN IMMEDIATE\0".ptr, null, null, null) != SQLITE_OK) return false;
    bool ok = false;
    sqlite3_stmt* del;
    if (sqlite3_prepare_v2(db, "DELETE FROM parity_spec WHERE agent = ?1 AND release = ?2\0".ptr, -1, &del, null) == SQLITE_OK) {
        bind(del, 1, agent);
        bind(del, 2, release);
        ok = sqlite3_step(del) == SQLITE_DONE;
        sqlite3_finalize(del);
    }
    foreach (i; 0 .. specCount) {
        if (!ok) break;
        sqlite3_stmt* ins;
        enum sql = "INSERT INTO parity_spec (agent, release, sha256, event, input, output, measured_at) "
            ~ "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)\0";
        if (sqlite3_prepare_v2(db, sql.ptr, -1, &ins, null) != SQLITE_OK) { ok = false; break; }
        bind(ins, 1, agent);
        bind(ins, 2, release);
        bind(ins, 3, sha);
        bind(ins, 4, specs[i].event[0 .. specs[i].eventLen]);
        bind(ins, 5, specs[i].input.slice());
        bind(ins, 6, specs[i].output.slice());
        sqlite3_bind_int64(ins, 7, now);
        ok = sqlite3_step(ins) == SQLITE_DONE;
        sqlite3_finalize(ins);
    }
    sqlite3_exec(db, ok ? "COMMIT\0".ptr : "ROLLBACK\0".ptr, null, null, null);
    return ok;
}

unittest {
    import db : sqlite3_open, sqlite3_close, applySchema;
    sqlite3* db;
    assert(sqlite3_open(":memory:", &db) == SQLITE_OK);
    assert(applySchema(db));

    Keys input, output;
    input.add("cwd");
    input.add("tool_name");
    output.add("decision");
    specCount = 0;
    addSpec("PostToolUse", input, output);
    assert(storeSpecs(db, "codex", "0.163.0", "aa", 100));

    // A second live read replaces the first whole: one event read, one row kept.
    specCount = 0;
    addSpec("Stop", input, output);
    assert(storeSpecs(db, "codex", "0.163.0", "bb", 200));

    sqlite3_stmt* st;
    assert(sqlite3_prepare_v2(db, "SELECT event, input, output, sha256, measured_at FROM parity_spec\0".ptr, -1, &st, null) == SQLITE_OK);
    assert(sqlite3_step(st) == SQLITE_ROW);
    assert(cstr(sqlite3_column_text(st, 0)) == "Stop");
    assert(cstr(sqlite3_column_text(st, 1)) == "cwd,tool_name");
    assert(cstr(sqlite3_column_text(st, 2)) == "decision");
    assert(cstr(sqlite3_column_text(st, 3)) == "bb");
    assert(sqlite3_column_int64(st, 4) == 200);
    assert(sqlite3_step(st) == SQLITE_DONE);
    sqlite3_finalize(st);
    sqlite3_close(db);
    specCount = 0;
}

private const(char)[] cstr(const(char)* p) {
    if (p is null) return "";
    size_t n = 0;
    while (p[n] != 0) n++;
    return p[0 .. n];
}

// --- the table ---

private struct Row { char[64] event = 0; size_t len; int[8] cells = -1; }
private __gshared Row[96] rows;
private __gshared size_t rowCount;
private __gshared long[8] measuredAt;

private Row* rowFor(const(char)[] event) {
    foreach (i; 0 .. rowCount)
        if (rows[i].event[0 .. rows[i].len] == event) return &rows[i];
    if (rowCount >= rows.length || event.length > rows[0].event.length) return null;
    auto r = &rows[rowCount++];
    r.len = event.length;
    foreach (i, c; event) r.event[i] = c;
    foreach (ref c; r.cells) c = -1;
    return r;
}

private void put(const(char)[] s) { fwrite(s.ptr, 1, s.length, stdout); }

private void putPad(const(char)[] s, size_t width) {
    put(s);
    foreach (_; s.length .. width) put(" ");
}

private const(char)[] percentText(int perMille, ref char[8] buf) {
    if (perMille < 0) return "";
    auto p = percentOf(perMille);
    size_t n = 0;
    if (p >= 100) buf[n++] = cast(char)('0' + p / 100);
    if (p >= 10) buf[n++] = cast(char)('0' + (p / 10) % 10);
    buf[n++] = cast(char)('0' + p % 10);
    buf[n++] = '%';
    return buf[0 .. n];
}

private void putList(const(char)[] spec, const(char)[] ground, bool want) {
    bool first = true;
    size_t s = 0;
    foreach (i; 0 .. spec.length + 1)
        if (i == spec.length || spec[i] == ',') {
            auto k = spec[s .. i];
            s = i + 1;
            if (k.length == 0 || listHas(ground, k) != want) continue;
            put(first ? "" : ",");
            put(k);
            first = false;
        }
    if (first) put("-");
}

private void putTime(long t) {
    import core.stdc.time : gmtime, time_t;
    time_t tt = cast(time_t) t;
    auto tm = gmtime(&tt);
    if (tm is null) return;
    char[16] b;
    void two(int v, size_t at) { b[at] = cast(char)('0' + v / 10 % 10); b[at + 1] = cast(char)('0' + v % 10); }
    int y = tm.tm_year + 1900;
    two(y / 100, 0); two(y % 100, 2); b[4] = '-'; two(tm.tm_mon + 1, 5); b[7] = '-'; two(tm.tm_mday, 8);
    b[10] = ' '; two(tm.tm_hour, 11); b[13] = ':'; two(tm.tm_min, 14);
    put(b[0 .. 16]);
    put(" UTC");
}

private void putFraction(int cov, int total) {
    char[24] nb;
    size_t n = 0;
    void num(int v) {
        char[12] d;
        int k = 0;
        do { d[k++] = cast(char)('0' + v % 10); v /= 10; } while (v > 0);
        while (k > 0) nb[n++] = d[--k];
    }
    num(cov);
    nb[n++] = '/';
    num(total);
    putPad(nb[0 .. n], 7);
}

private void putEventKeys(const(char)[] label, int cov, int total, const(char)[] spec, const(char)[] ground) {
    put(label);
    putFraction(cov, total);
    put("covered: ");
    putList(spec, ground, true);
    put("  missing: ");
    putList(spec, ground, false);
    put("\n");
}

private bool anyCell(ref const Row r) {
    foreach (pi; 0 .. pins.length) if (r.cells[pi] >= 0) return true;
    return false;
}

private void render(sqlite3* db, const(char)[] only, ref Measured[8] status) {
    rowCount = 0;
    static foreach (m; __traits(allMembers, HookEvent)) rowFor(m);

    foreach (pi, ref pin; pins) {
        measuredAt[pi] = 0;
        sqlite3_stmt* st;
        enum sql = "SELECT event, input, output, measured_at FROM parity_spec WHERE agent = ?1 AND release = ?2\0";
        if (sqlite3_prepare_v2(db, sql.ptr, -1, &st, null) != SQLITE_OK) continue;
        bind(st, 1, pin.agent);
        bind(st, 2, pin.release);
        while (sqlite3_step(st) == SQLITE_ROW) {
            auto event = cstr(sqlite3_column_text(st, 0));
            auto input = cstr(sqlite3_column_text(st, 1));
            auto output = cstr(sqlite3_column_text(st, 2));
            measuredAt[pi] = sqlite3_column_int64(st, 3);
            auto reads = sideFor(pin.agent, event).reads.slice();
            auto writes = sideFor(pin.agent, event).writes.slice();
            int ic = covered(input, reads), it = countOf(input);
            int oc = covered(output, writes), ot = countOf(output);
            auto cell = score(ic, it, oc, ot);
            if (only.length > 0) {
                if (event != only) continue;
                char[8] pb;
                put(pin.agent); put(" "); put(pin.release); put("  "); put(event); put("  ");
                put(percentText(cell, pb)); put("\n");
                putEventKeys("  in   ", ic, it, input, reads);
                putEventKeys("  out  ", oc, ot, output, writes);
                continue;
            }
            auto r = rowFor(event);
            if (r !is null) r.cells[pi] = cell;
        }
        sqlite3_finalize(st);
    }

    if (only.length == 0) {
        // A row is an event some pinned version names; a member of ground's
        // enum that no agent sends is not one.
        size_t eventWidth = 7;
        foreach (i; 0 .. rowCount)
            if (anyCell(rows[i]) && rows[i].len + 1 > eventWidth) eventWidth = rows[i].len + 1;

        putPad("Event:", eventWidth);
        put("| overall ");
        for (size_t pi = 0; pi < pins.length;) {
            auto agent = pins[pi].agent;
            put("| ## "); put(agent); put(" ");
            while (pi < pins.length && pins[pi].agent == agent) { put("| "); put(pins[pi].release); put(" "); pi++; }
        }
        put("\n");

        foreach (i; 0 .. rowCount) {
            if (!anyCell(rows[i])) continue;
            int[8] agentMeans = -1;
            size_t agents = 0;
            for (size_t pi = 0; pi < pins.length;) {
                auto agent = pins[pi].agent;
                size_t from = pi;
                while (pi < pins.length && pins[pi].agent == agent) pi++;
                agentMeans[agents++] = meanOf(rows[i].cells[from .. pi]);
            }
            char[8] pb;
            putPad(rows[i].event[0 .. rows[i].len], eventWidth);
            put("| "); putPad(percentText(meanOf(agentMeans[0 .. agents]), pb), 8);
            size_t a = 0;
            for (size_t pi = 0; pi < pins.length;) {
                auto agent = pins[pi].agent;
                put("| "); putPad(percentText(agentMeans[a++], pb), agent.length + 4);
                while (pi < pins.length && pins[pi].agent == agent) {
                    put("| "); putPad(percentText(rows[i].cells[pi], pb), pins[pi].release.length + 1);
                    pi++;
                }
            }
            put("\n");
        }
    }

    put("\n");
    foreach (pi, ref pin; pins) {
        auto m = &status[pi];
        put(pin.agent); put(" "); put(pin.release); put("  ");
        if (m.access == Access.live) put("live    ");
        else put(measuredAt[pi] > 0 ? "stored  " : "never   ");
        final switch (m.access) {
            case Access.live: put(m.path[0 .. m.pathLen]); break;
            case Access.mismatch:
                put(m.path[0 .. m.pathLen]); put(" is "); put(m.sha[0 .. 12]);
                put(", pinned "); put(pin.sha256[0 .. 12]);
                break;
            case Access.empty:
                put(pin.agent == "acp" ? "no methods read from " : "no hook schemas read from ");
                put(m.path[0 .. m.pathLen]);
                break;
            case Access.absent:
                put(pin.agent == "acp" ? "no schema at " : "no binary at ");
                put(m.path[0 .. m.pathLen]);
                break;
        }
        if (m.access != Access.live && measuredAt[pi] > 0) { put(", measured "); putTime(measuredAt[pi]); }
        put("\n");
    }
}

private void say(const(char)[] s) { fwrite(s.ptr, 1, s.length, stderr); }

int handleParity(int argc, const(char)** argv) {
    import db : openDb, sqlite3_close;
    import core.stdc.time : time;

    const(char)[] only;
    if (argc >= 3) only = cstr(argv[2]);

    auto db = openDb();
    if (db is null) {
        fputs("ground parity: the store would not open\n", stderr);
        return 1;
    }

    Measured[8] status;
    int rc = 0;
    foreach (pi, ref pin; pins) {
        status[pi] = measure(pin);
        if (status[pi].access != Access.live) continue;
        bool overflow = specsFull;
        foreach (i; 0 .. specCount) if (specs[i].input.full || specs[i].output.full) overflow = true;
        if (overflow) {
            say("ground parity: "); say(pin.agent); say(" "); say(pin.release);
            say(" names more than parity holds; nothing stored for it\n");
            status[pi].access = Access.empty;
            rc = 1;
            continue;
        }
        if (!storeSpecs(db, pin.agent, pin.release, status[pi].sha[], cast(long) time(null))) {
            say("ground parity: the store refused "); say(pin.agent); say(" "); say(pin.release);
            say("'s contract; the stored one stands\n");
            status[pi].access = Access.empty;
            rc = 1;
        }
    }

    render(db, only, status);
    sqlite3_close(db);
    return rc;
}
