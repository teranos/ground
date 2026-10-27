module parity;

// "the way i expect ground parity to work is run ground parity and have a real live picture of what is going on based on the versions it has access to, the versions it has no access to stay in the sqlite until ran again with a correct binary"

import core.stdc.stdio : stdout, stderr, fputs, fwrite;
import hooks : HookEvent;
import parse : Reads;
import std.meta : AliasSeq;
static import parse, code.prompt;
import db : ZBuf;
static import parse;

enum BOOK_COMMAND = q"EOS
# what ground covers of each pinned agent's hook contract, per event and version,
# and what ground code covers of the pinned ACP schema, per method:
ground_parity
# one event's keys per version, covered and missing:
ground_parity PostToolUse
# one ACP method's, read and written by ground code:
ground_parity session/prompt
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
    version (AArch64) { enum claudePlatform = "darwin-arm64"; enum codexTarget = "aarch64-apple-darwin"; enum agyTarget = "mac_arm64"; }
    else { enum claudePlatform = "darwin-x64"; enum codexTarget = "x86_64-apple-darwin"; enum agyTarget = "mac_x64"; }
} else {
    version (AArch64) { enum claudePlatform = "linux-arm64"; enum codexTarget = "aarch64-unknown-linux-musl"; enum agyTarget = "linux_arm64_musl"; }
    else { enum claudePlatform = "linux-x64"; enum codexTarget = "x86_64-unknown-linux-musl"; enum agyTarget = "linux_x64_musl"; }
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

// The most pins a build holds, every agent and spec version together.
enum maxPins = 16;

struct PinSet { Pin[maxPins] items; size_t count; }

PinSet readPins()(string flake) {
    PinSet found;
    foreach (i; 0 .. flake.length) {
        string agent;
        if (startsAt(flake, i, `claude "`)) agent = "claude";
        else if (startsAt(flake, i, `codex "`)) agent = "codex";
        else if (startsAt(flake, i, `agy "`)) agent = "agy";
        else if (startsAt(flake, i, `acp "`)) agent = "acp";
        else if (startsAt(flake, i, `mcp "`)) agent = "mcp";
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
        else if (agent == "acp" || agent == "mcp") sha = hexAfter(block, "schema");
        else {
            // codex and agy pin each target's tarball and the binary it unpacks to.
            auto t = assigned(block, agent == "codex" ? codexTarget : agyTarget, " = {");
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

// The keys on lines this many spaces deep, from pos until the object closes,
// one level being step spaces.
private void keysAtIndent(const(char)[] doc, size_t pos, size_t indent, ref Keys keys, size_t step = 2) {
    size_t i = pos;
    while (i < doc.length) {
        auto nl = indexIn(doc, "\n", i);
        if (nl < 0) return;
        size_t j = cast(size_t) nl + 1;
        size_t spaces = 0;
        while (j < doc.length && doc[j] == ' ') { spaces++; j++; }
        if (j >= doc.length) return;
        if (spaces + step == indent && doc[j] == '}') return;
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

// --- mcp: one JSON Schema document per version, four spaces a level ---

// A definition, from its opening line to the brace that closes it, or null.
// Definitions sit eight spaces deep, under $defs or, before 2025-11-25, definitions.
private const(char)[] mcpDef(const(char)[] text, const(char)[] name) {
    char[160] nb;
    auto open = indexIn(text, joined(nb, "\n        \"", name, "\": {"));
    if (open < 0) return null;
    auto close = indexIn(text, "\n        }", cast(size_t) open + 1);
    if (close < 0) return null;
    return text[cast(size_t) open .. cast(size_t) close];
}

// The method a definition is, its properties.method.const, or null.
private const(char)[] mcpMethodOf(const(char)[] def) {
    enum at = "\n                \"method\": {";
    auto m = indexIn(def, at);
    if (m < 0) return null;
    auto end = indexIn(def, "\n                }", cast(size_t) m + 1);
    enum c = "\"const\": \"";
    auto k = indexIn(def, c, cast(size_t) m);
    if (k < 0 || (end >= 0 && k > end)) return null;
    auto from = cast(size_t) k + c.length;
    auto to = indexIn(def, `"`, from);
    return to < 0 ? null : def[from .. cast(size_t) to];
}

// The name the reference at pos points to: #/$defs/Name or #/definitions/Name.
private const(char)[] mcpRefAt(const(char)[] doc, size_t pos) {
    auto to = indexIn(doc, `"`, pos);
    if (to < 0) return null;
    auto path = doc[pos .. cast(size_t) to];
    auto slash = lastIndexIn(path, "/");
    return slash < 0 ? null : path[cast(size_t) slash + 1 .. $];
}

enum mcpRef = "\"$ref\": \"";

// A definition's top-level properties.
private void mcpProps(const(char)[] def, ref Keys keys) {
    enum props = "\n            \"properties\": {";
    auto p = indexIn(def, props);
    if (p >= 0) keysAtIndent(def, cast(size_t) p + props.length, 16, keys, 4);
}

// A message's params: written in its own properties, or a reference to the
// definition that holds them.
private void mcpParams(const(char)[] text, const(char)[] def, ref Keys keys) {
    enum at = "\n                \"params\": {";
    auto p = indexIn(def, at);
    if (p < 0) return;
    auto end = indexIn(def, "\n                }", cast(size_t) p + 1);
    auto block = def[cast(size_t) p .. end < 0 ? def.length : cast(size_t) end];
    auto r = indexIn(block, mcpRef);
    if (r >= 0) {
        mcpProps(mcpDef(text, mcpRefAt(block, cast(size_t) r + mcpRef.length)), keys);
        return;
    }
    enum props = "\n                    \"properties\": {";
    auto q = indexIn(block, props);
    if (q >= 0) keysAtIndent(block, cast(size_t) q + props.length, 24, keys, 4);
}

// The unions that say who sends what. libmcp is the client: what it sends it
// writes, and what the server sends it reads; a request's result is written by
// whoever answers it.
private static immutable string[2][4] mcpUnions = [
    ["ClientRequest", "client"], ["ServerRequest", "server"],
    ["ClientNotification", "client"], ["ServerNotification", "server"],
];

// One method's keys from libmcp's side, every union that names it.
bool mcpSpec(const(char)[] text, const(char)[] method, ref Keys input, ref Keys output) {
    bool found = false;
    foreach (ref u; mcpUnions) {
        auto union_ = mcpDef(text, u[0]);
        if (union_ is null) continue;
        bool clientSends = u[1] == "client";
        bool request = endsWith(u[0], "Request");
        size_t from = 0;
        while (true) {
            auto r = indexIn(union_, mcpRef, from);
            if (r < 0) break;
            from = cast(size_t) r + mcpRef.length;
            auto name = mcpRefAt(union_, from);
            auto def = mcpDef(text, name);
            if (def is null || mcpMethodOf(def) != method) continue;
            found = true;
            mcpParams(text, def, clientSends ? output : input);
            if (!request || !endsWith(name, "Request")) continue;
            char[160] rb;
            mcpProps(mcpDef(text, joined(rb, name[0 .. $ - "Request".length], "Result", "")), clientSends ? input : output);
        }
    }
    return found;
}

SpecKeys mcpKeys()(string text, string method) {
    SpecKeys k;
    mcpSpec(text, method, k.input, k.output);
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

// --- agy: hooks.proto's descriptor, compiled into the Go binary ---

// A protobuf varint from i on, leaving i past it.
private bool varint(const(char)[] m, ref size_t i, ref ulong v) {
    v = 0;
    for (uint shift = 0; i < m.length && shift < 64; shift += 7) {
        auto b = cast(ubyte) m[i++];
        v |= cast(ulong)(b & 0x7f) << shift;
        if (b < 0x80) return true;
    }
    return false;
}

// The field at i: its number and, when it is length-delimited, its bytes.
// False on bytes that are no field.
private bool nextField(const(char)[] m, ref size_t i, ref ulong number, ref bool delimited, ref const(char)[] bytes) {
    ulong tag, n;
    if (!varint(m, i, tag)) return false;
    number = tag >> 3;
    delimited = (tag & 7) == 2;
    switch (tag & 7) {
        case 0: return varint(m, i, n);
        case 1: i += 8; return i <= m.length;
        case 5: i += 4; return i <= m.length;
        case 2:
            if (!varint(m, i, n) || n > m.length - i) return false;
            bytes = m[i .. i + cast(size_t) n];
            i += cast(size_t) n;
            return true;
        default: return false;
    }
}

// The descriptor's package declaration, its field 2. Its messages follow it.
ptrdiff_t agyAnchor(const(char)[] text) { return indexIn(text, "\x12\x0cexa.hooks_pb"); }

// A message of the file is its field 4. The message's name is its own field 1,
// each of its fields is its field 2, and a field's JSON name is that field's 10.
bool agyMessage(const(char)[] text, size_t anchor, const(char)[] name, ref Keys keys) {
    size_t i = anchor;
    ulong number;
    bool delimited;
    const(char)[] m;
    while (i < text.length) {
        if (!nextField(text, i, number, delimited, m)) return false;
        if (number == 12) return false; // syntax, the file's last field
        if (number != 4 || !delimited) continue;
        size_t j = 0;
        const(char)[] own;
        if (!nextField(m, j, number, delimited, own) || number != 1 || own != name) continue;
        while (j < m.length) {
            const(char)[] field;
            if (!nextField(m, j, number, delimited, field)) return false;
            if (number != 2 || !delimited) continue;
            size_t k = 0;
            const(char)[] json;
            while (k < field.length) {
                if (!nextField(field, k, number, delimited, json)) return false;
                if (number == 10 && delimited) keys.add(json);
            }
        }
        return true;
    }
    return false;
}

Keys agyKeys()(string text, string name) {
    Keys k;
    auto a = agyAnchor(text);
    if (a >= 0) agyMessage(text, cast(size_t) a, name, k);
    return k;
}

// agy's hooks.json names the events; hooks.proto names what each sends and reads back.
private static immutable string[3][6] agyEvents = [
    ["SessionStart", "SessionStartHookArgs", "SessionStartHookResult"],
    ["PreToolUse", "PreToolHookArgs", "PreToolHookResult"],
    ["PostToolUse", "PostToolHookArgs", "PostToolHookResult"],
    ["PreInvocation", "PreInvocationHookArgs", "PreInvocationHookResult"],
    ["PostInvocation", "PostInvocationHookArgs", "PostInvocationHookResult"],
    ["Stop", "StopHookArgs", "StopHookResult"],
];

// --- ground's side, read out of its own source at compile time ---

private enum mainSource = import("source/hookrun.d");

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

// The key a function is marked as reading, or null: parse.d's extractors, and
// ground code's helpers that read a request for the branch that calls them.
private string readKeyOf()(string name) {
    static foreach (mod; AliasSeq!(parse, code.prompt)) {
        static foreach (m; __traits(allMembers, mod)) {
            static if (__traits(compiles, __traits(getAttributes, __traits(getMember, mod, m)))) {
                static foreach (a; __traits(getAttributes, __traits(getMember, mod, m))) {
                    static if (is(typeof(a) == Reads)) {
                        if (name == m) return a.key;
                    }
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
// libmcp's sides count a called function's keys too, so they run longer.
alias GroundKeys = KeysOf!2048;

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
            if (j < text.length && text[j] == '(') {
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
// whole: every line builds the message, as a function sending one does.
GroundKeys writesIn()(string text, bool whole = false) {
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
        if (!emits && !whole) continue;
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

// The keys of a JSON object, its own and not its values'.
GroundKeys jsonKeys()(const(char)[] json) {
    GroundKeys keys;
    int depth = 0;
    for (size_t i = 0; i < json.length; i++) {
        char c = json[i];
        if (c == '"') {
            size_t j = i + 1;
            while (j < json.length && json[j] != '"') j += json[j] == '\\' ? 2 : 1;
            if (j >= json.length) break;
            size_t k = j + 1;
            while (k < json.length && json[k] == ' ') k++;
            if (depth == 1 && k < json.length && json[k] == ':') keys.add(json[i + 1 .. j]);
            i = j;
        }
        else if (c == '{' || c == '[') depth++;
        else if (c == '}' || c == ']') depth--;
    }
    return keys;
}

// agy is answered by agy.d, which reads the same of every event and answers each its own.
private enum agySource = import("source/agy.d");

private GroundSide[agyEvents.length] buildAgySides()() {
    import agy : answerOf;
    GroundSide[agyEvents.length] sides;
    foreach (i, ref e; agyEvents) sides[i] = GroundSide(e[0], readsIn(agySource), jsonKeys(answerOf(e[0])));
    return sides;
}

private static immutable GroundSide[agyEvents.length] agySides = buildAgySides();
private static immutable GroundSide agyUnknown = GroundSide(null, readsIn(agySource), GroundKeys.init);

// An event ground dispatches nowhere still has what run() reads first. codex
// runs the handlers Claude Code does.
ref immutable(GroundSide) sideOf(const(char)[] agent, const(char)[] event) {
    if (agent == "agy") {
        foreach (ref s; agySides) if (s.event == event) return s;
        return agyUnknown;
    }
    foreach (ref s; groundSides) if (s.event == event) return s;
    return unknownSide;
}

// Ground code is the agent an ACP client talks to. A method's side is its block
// in code/acp.d, the whole branch that tests for it, early returns and all; a
// method with no block reads and writes nothing.
private enum codeSource = import("source/code/acp.d");

private struct CodeSides { GroundSide[32] items; size_t count; }

// Where the branch opening after `from` closes. A brace in a string, a
// character or a comment is not one.
private size_t branchEnd()(string src, size_t from) {
    auto open = indexIn(src, "{", from);
    if (open < 0) return src.length;
    int depth = 0;
    char quote = 0;
    for (size_t i = cast(size_t) open; i < src.length; i++) {
        char c = src[i];
        if (quote) {
            if (quote != '`' && c == '\\') { i++; continue; }
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
            while (i < src.length && src[i] != '\n') i++;
            continue;
        }
        if (c == '"' || c == '`' || c == '\'') quote = c;
        else if (c == '{') depth++;
        else if (c == '}' && --depth == 0) return i + 1;
    }
    return src.length;
}

// The function a method ground code sends is written in: the top-level
// declaration around its "method", to the brace that closes it. null when
// nothing sends it.
string sentBlock()(string src, string method) {
    enum sent = `"method":"`;
    ptrdiff_t at = -1;
    for (auto f = indexIn(src, sent); f >= 0; f = indexIn(src, sent, cast(size_t) f + 1)) {
        auto n = cast(size_t) f + sent.length;
        if (startsAt(src, n, method) && startsAt(src, n + method.length, `"`)) { at = f; break; }
    }
    if (at < 0) return null;
    size_t start = cast(size_t) at;
    while (start > 0) {
        auto lineStart = start;
        while (lineStart > 0 && src[lineStart - 1] != '\n') lineStart--;
        auto c = src[lineStart];
        if (c != ' ' && c != '\t' && c != '\n' && c != '/' && c != '}') { start = lineStart; break; }
        if (lineStart == 0) return null;
        start = lineStart - 1;
    }
    return src[start .. branchEnd(src, start)];
}

private CodeSides buildCodeSides()() {
    CodeSides cs;
    enum key = `method == "`;
    size_t from = 0;
    while (true) {
        auto at = indexIn(codeSource, key, from);
        if (at < 0) break;
        auto nameFrom = cast(size_t) at + key.length;
        auto nameEnd = indexIn(codeSource, `"`, nameFrom);
        assert(nameEnd >= 0, "code/acp.d tests a method it does not close");
        from = cast(size_t) nameEnd;
        auto block = codeSource[cast(size_t) at .. branchEnd(codeSource, cast(size_t) at)];
        assert(cs.count < cs.items.length, "code/acp.d handles more methods than parity holds");
        auto side = GroundSide(codeSource[nameFrom .. cast(size_t) nameEnd], readsIn(block), writesIn(block));
        libacpKeys(block, side);
        helperKeys(block, side);
        cs.items[cs.count++] = side;
    }
    // A method sent to the client has no branch: what ground code writes is
    // the message its sending function builds.
    enum sent = `"method":"`;
    from = 0;
    while (true) {
        auto at = indexIn(codeSource, sent, from);
        if (at < 0) break;
        auto nameFrom = cast(size_t) at + sent.length;
        auto nameEnd = indexIn(codeSource, `"`, nameFrom);
        assert(nameEnd >= 0, "code/acp.d sends a method it does not close");
        from = cast(size_t) nameEnd;
        auto name = codeSource[nameFrom .. cast(size_t) nameEnd];
        bool seen = false;
        foreach (ref s; cs.items[0 .. cs.count]) if (s.event == name) seen = true;
        if (seen) continue;
        auto block = sentBlock(codeSource, name);
        assert(cs.count < cs.items.length, "code/acp.d handles more methods than parity holds");
        cs.items[cs.count++] = GroundSide(name, readsIn(block), writesIn(block, true));
    }
    return cs;
}

// --- acp: the part of a method ground code reads and writes through libacp ---

// The library as ground links it, kept in this repository at libacp/.
private static immutable string[4] libacpSources = [
    import("libacp/src/acp.c"), import("libacp/src/initialize.c"), import("libacp/src/session.c"),
    import("libacp/src/modes.c"),
];

private LibFns libacpFns()() {
    LibFns all;
    foreach (i, s; libacpSources) {
        auto fns = cFunctions(s);
        foreach (f; fns.items[0 .. fns.count]) {
            assert(all.count < all.items.length, "libacp has more functions than parity holds");
            all.items[all.count++] = LibFn(i, f);
        }
    }
    return all;
}

// Every libacp function a block calls, and one level of the library's own it calls in turn.
private void libacpKeys()(const(char)[] block, ref GroundSide side) {
    auto lib = libacpFns();
    foreach (f; lib.items[0 .. lib.count]) {
        if (named(block, f.fn.name) < 0) continue;
        auto body_ = libacpSources[f.src][f.fn.from .. f.fn.to];
        cKeys(body_, acpReader, side);
        foreach (g; lib.items[0 .. lib.count])
            if (g.fn.name != f.fn.name && named(body_, g.fn.name) >= 0)
                cKeys(libacpSources[g.src][g.fn.from .. g.fn.to], acpReader, side);
    }
}

// ground code's own helpers a block calls, one level: libacp read through them counts for the block.
private void helperKeys()(const(char)[] block, ref GroundSide side) {
    size_t from = 0;
    while (true) {
        auto at = indexIn(codeSource, "\nprivate ", from);
        if (at < 0) return;
        from = cast(size_t) at + 1;
        auto paren = indexIn(codeSource, "(", from), eol = indexIn(codeSource, "\n", from);
        if (paren < 0 || paren > eol) continue;
        size_t b = cast(size_t) paren;
        while (b > from && isIdent(codeSource[b - 1])) b--;
        auto name = codeSource[b .. cast(size_t) paren];
        if (name.length == 0 || named(block, name) < 0) continue;
        auto close = indexIn(codeSource, "\n}\n", from);
        assert(close >= 0, "code/acp.d has a helper it does not close");
        libacpKeys(codeSource[from .. cast(size_t) close], side);
    }
}

private static immutable CodeSides codeSides = buildCodeSides();
private static immutable GroundSide codeSide = GroundSide(null, GroundKeys.init, GroundKeys.init);

// --- mcp: libmcp's side, read out of its C at compile time ---

// The library as ground links it, kept in this repository at libmcp/.
private static immutable string[6] libmcpSources = [
    import("libmcp/src/mcp.c"), import("libmcp/src/protocol.c"), import("libmcp/src/http.c"),
    import("libmcp/src/stdio.c"), import("libmcp/src/schema.c"), import("libmcp/src/json.c"),
];

// Past a string, a character or a comment that starts at i, or i itself.
private size_t pastC(const(char)[] s, size_t i) {
    if (s[i] == '"' || s[i] == '\'') {
        auto q = s[i];
        for (size_t j = i + 1; j < s.length; j++) {
            if (s[j] == '\\') { j++; continue; }
            if (s[j] == q) return j + 1;
        }
        return s.length;
    }
    if (s[i] == '/' && i + 1 < s.length && s[i + 1] == '/') {
        auto nl = indexIn(s, "\n", i);
        return nl < 0 ? s.length : cast(size_t) nl;
    }
    if (s[i] == '/' && i + 1 < s.length && s[i + 1] == '*') {
        auto e = indexIn(s, "*/", i + 2);
        return e < 0 ? s.length : cast(size_t) e + 2;
    }
    return i;
}

// Past the bracket that closes the one opening at i.
private size_t pastClose(const(char)[] s, size_t i) {
    int depth = 0;
    while (i < s.length) {
        auto j = pastC(s, i);
        if (j != i) { i = j; continue; }
        if (s[i] == '(' || s[i] == '{' || s[i] == '[') depth++;
        else if ((s[i] == ')' || s[i] == '}' || s[i] == ']') && --depth == 0) return i + 1;
        i++;
    }
    return s.length;
}

private struct CFn { const(char)[] name; size_t from, to; }
private struct CFns { CFn[256] items; size_t count; }

// Every function body at the top of a source: a brace after a parameter list.
private CFns cFunctions()(const(char)[] s) {
    CFns fns;
    size_t i = 0;
    while (i < s.length) {
        auto j = pastC(s, i);
        if (j != i) { i = j; continue; }
        if (s[i] != '{') { i++; continue; }
        size_t k = i;
        while (k > 0 && (s[k - 1] == ' ' || s[k - 1] == '\n')) k--;
        auto close = pastClose(s, i);
        if (k > 0 && s[k - 1] == ')') {
            int depth = 0;
            size_t p = k;
            while (p > 0) {
                p--;
                if (s[p] == ')') depth++;
                else if (s[p] == '(' && --depth == 0) break;
            }
            size_t e = p;
            while (e > 0 && s[e - 1] == ' ') e--;
            size_t b = e;
            while (b > 0 && isIdent(s[b - 1])) b--;
            assert(fns.count < fns.items.length, "a libmcp source has more functions than parity holds");
            fns.items[fns.count++] = CFn(s[b .. e], i, close);
        }
        i = close;
    }
    return fns;
}

private struct CArgs { const(char)[][24] items; size_t count; }

// The arguments of the call whose parenthesis opens at i, at its top level.
private CArgs cArgs()(const(char)[] s, size_t i) {
    CArgs args;
    auto end = pastClose(s, i) - 1;
    size_t start = i + 1, j = i + 1;
    int depth = 0;
    while (j < end) {
        auto k = pastC(s, j);
        if (k != j) { j = k; continue; }
        if (s[j] == '(' || s[j] == '{' || s[j] == '[') depth++;
        else if (s[j] == ')' || s[j] == '}' || s[j] == ']') depth--;
        else if (s[j] == ',' && depth == 0 && args.count < args.items.length) {
            args.items[args.count++] = s[start .. j];
            start = j + 1;
        }
        j++;
    }
    if (args.count < args.items.length) args.items[args.count++] = s[start .. end];
    return args;
}

private const(char)[] trimmed(const(char)[] a) {
    size_t b = 0, e = a.length;
    while (b < e && (a[b] == ' ' || a[b] == '\n')) b++;
    while (e > b && (a[e - 1] == ' ' || a[e - 1] == '\n')) e--;
    return a[b .. e];
}

// The text of a string literal argument, or null.
private const(char)[] literalOf(const(char)[] a) {
    a = trimmed(a);
    return a.length >= 2 && a[0] == '"' && a[$ - 1] == '"' ? a[1 .. $ - 1] : null;
}

// Where an identifier is named on its own, from `from`, or -1.
private ptrdiff_t named(const(char)[] s, const(char)[] ident, size_t from = 0) {
    while (true) {
        auto at = indexIn(s, ident, from);
        if (at < 0) return -1;
        auto a = cast(size_t) at, e = a + ident.length;
        if ((a == 0 || !isIdent(s[a - 1])) && (e >= s.length || !isIdent(s[e]))) return at;
        from = e;
    }
}

// Every literal in the second argument of each call to fn in a region: a
// ternary between two keys reads either.
private void keyArgs(const(char)[] region, const(char)[] fn, ref GroundKeys keys) {
    size_t from = 0;
    while (true) {
        auto at = named(region, fn, from);
        if (at < 0) return;
        from = cast(size_t) at + fn.length;
        if (from >= region.length || region[from] != '(') continue;
        auto args = cArgs(region, from);
        if (args.count >= 2) literalsIn(args.items[1], keys);
    }
}

// The one way a C library's side is read: json-c's own calls, and the wrappers
// the library reads and writes a key through, the key their second argument.
private struct CReader { string[] reads; string[] writes; }
private static immutable CReader mcpReader = CReader(["mcp_field", "mcp_has"], ["mcp_add"]);
private static immutable CReader acpReader = CReader(["acp_field", "acp_offered", "acp_flag", "acp_string"], []);

private void cKeys()(const(char)[] region, const CReader reader, ref GroundSide side) {
    keyArgs(region, "json_object_object_get_ex", side.reads);
    foreach (fn; reader.reads) keyArgs(region, fn, side.reads);
    keyArgs(region, "json_object_object_add", side.writes);
    foreach (fn; reader.writes) keyArgs(region, fn, side.writes);
}

// Every string literal in an argument: `v ? "cursor" : NULL` passes cursor.
private void literalsIn(const(char)[] a, ref GroundKeys keys) {
    size_t i = 0;
    while (i < a.length) {
        if (a[i] != '"') { i++; continue; }
        auto end = pastC(a, i);
        if (end - i >= 2) keys.add(a[i + 1 .. end - 1]);
        i = end;
    }
}

// The library's functions, found once.
private struct LibFn { size_t src; CFn fn; }
private struct LibFns { LibFn[512] items; size_t count; }

private LibFns libmcpFns()() {
    LibFns all;
    foreach (i, s; libmcpSources) {
        auto fns = cFunctions(s);
        foreach (f; fns.items[0 .. fns.count]) {
            assert(all.count < all.items.length, "libmcp has more functions than parity holds");
            all.items[all.count++] = LibFn(i, f);
        }
    }
    return all;
}

// What a block reads and writes: its own calls, the names in the function it
// sits in that a read was kept in, and one level of the library's own functions
// it calls.
private void gather(const(LibFn)[] lib, const(char)[] src, CFn fn, const(char)[] region, ref GroundSide side) {
    cKeys(region, mcpReader, side);
    auto body_ = src[fn.from .. fn.to];
    enum kept = "= mcp_field(";
    size_t from = 0;
    while (true) {
        auto at = indexIn(body_, kept, from);
        if (at < 0) break;
        from = cast(size_t) at + kept.length;
        size_t e = cast(size_t) at;
        while (e > 0 && body_[e - 1] == ' ') e--;
        size_t b = e;
        while (b > 0 && isIdent(body_[b - 1])) b--;
        auto args = cArgs(body_, from - 1);
        auto key = args.count >= 2 ? literalOf(args.items[1]) : null;
        if (key !is null && b < e && named(region, body_[b .. e]) >= 0) side.reads.add(key);
    }
    foreach (ref l; lib) {
        if (l.fn.name == fn.name) continue;
        auto c = named(region, l.fn.name);
        if (c < 0 || cast(size_t) c + l.fn.name.length >= region.length
            || region[cast(size_t) c + l.fn.name.length] != '(') continue;
        cKeys(libmcpSources[l.src][l.fn.from .. l.fn.to], mcpReader, side);
    }
}

// The statement a position sits in: back to the last ; { or } outside brackets.
private size_t statementStart(const(char)[] s, size_t from, size_t floor) {
    size_t i = from;
    int depth = 0;
    while (i > floor) {
        i--;
        if (s[i] == ')') depth++;
        else if (s[i] == '(') { if (depth > 0) depth--; }
        else if (depth == 0 && (s[i] == ';' || s[i] == '{' || s[i] == '}')) return i + 1;
    }
    return floor;
}

// An if from its condition to the end of what it governs.
private size_t ifEnd(const(char)[] s, size_t cond) {
    auto i = pastClose(s, cond);
    while (i < s.length && (s[i] == ' ' || s[i] == '\n')) i++;
    if (i < s.length && s[i] == '{') return pastClose(s, i);
    int depth = 0;
    while (i < s.length) {
        auto j = pastC(s, i);
        if (j != i) { i = j; continue; }
        if (s[i] == '(' || s[i] == '{') depth++;
        else if (s[i] == ')' || s[i] == '}') depth--;
        else if (s[i] == ';' && depth == 0) return i + 1;
        i++;
    }
    return s.length;
}

// The if a statement is, as the index of its condition's parenthesis, or -1.
private ptrdiff_t ifAt(const(char)[] s, size_t start) {
    auto t = start;
    while (t < s.length && (s[t] == ' ' || s[t] == '\n')) t++;
    if (startsAt(s, t, "else ")) t += 5;
    while (t < s.length && s[t] == ' ') t++;
    if (!startsAt(s, t, "if ")) return -1;
    auto p = indexIn(s, "(", t);
    return p;
}

// One method's side of libmcp: wherever its name is tested, the branch it
// governs or the names the test was kept in; wherever it is sent, the function
// that sends it and the keys passed with it.
GroundSide mcpSide()(const(LibFn)[] lib, string method) {
    GroundSide side;
    side.event = method;
    char[200] qb;
    auto quoted = joined(qb, `"`, method, `"`);
    foreach (si, s; libmcpSources) {
        size_t from = 0;
        while (true) {
            auto at = indexIn(s, quoted, from);
            if (at < 0) break;
            auto pos = cast(size_t) at;
            from = pos + quoted.length;
            CFn fn;
            bool inside = false;
            foreach (ref l; lib) if (l.src == si && l.fn.from < pos && pos < l.fn.to) { fn = l.fn; inside = true; }
            if (!inside) continue;
            // The call the name is an argument of.
            size_t open = pos;
            int depth = 0;
            while (open > fn.from) {
                open--;
                if (s[open] == ')') depth++;
                else if (s[open] == '(') { if (depth == 0) break; depth--; }
            }
            size_t e = open;
            while (e > 0 && s[e - 1] == ' ') e--;
            size_t b = e;
            while (b > 0 && isIdent(s[b - 1])) b--;
            auto callee = s[b .. e];
            if (callee != "strcmp" && callee != "mcp_string_is") {
                gather(lib, s, fn, s[fn.from .. fn.to], side);
                bool past = false;
                auto args = cArgs(s, open);
                foreach (a; args.items[0 .. args.count]) {
                    if (past) literalsIn(a, side.writes);
                    if (literalOf(a) == method) past = true;
                }
                continue;
            }
            auto start = statementStart(s, pos, fn.from);
            auto cond = ifAt(s, start);
            if (cond >= 0 && cast(size_t) cond < pos) {
                gather(lib, s, fn, s[cast(size_t) cond .. ifEnd(s, cast(size_t) cond)], side);
                continue;
            }
            // A test kept in a name: every if in the function that names it.
            size_t d = pos;
            while (d > start && s[d] != '=') d--;
            if (d == start) continue;
            size_t ne = d;
            while (ne > start && (s[ne - 1] == ' ')) ne--;
            size_t nb = ne;
            while (nb > start && isIdent(s[nb - 1])) nb--;
            auto name = s[nb .. ne];
            if (name.length == 0) continue;
            size_t scan = fn.from;
            while (true) {
                auto i = named(s[0 .. fn.to], "if", scan);
                if (i < 0) break;
                scan = cast(size_t) i + 2;
                auto p = indexIn(s, "(", cast(size_t) i);
                if (p < 0 || cast(size_t) p >= fn.to) break;
                auto condEnd = pastClose(s, cast(size_t) p);
                if (named(s[cast(size_t) p .. condEnd], name) >= 0)
                    gather(lib, s, fn, s[cast(size_t) p .. ifEnd(s, cast(size_t) p)], side);
            }
        }
    }
    return side;
}

// Every method libmcp names: each literal that is a protocol method's name.
private bool methodLike(const(char)[] t) {
    if (t == "initialize" || t == "ping") return true;
    bool slash = false;
    foreach (c; t) {
        if (c == '/') slash = true;
        else if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_')) return false;
    }
    return slash && t.length > 2 && t[0] != '/';
}

// What libmcp reads of every message before it tells one method from another,
// as main.d's run() does of every hook event, and what it writes into every
// request it sends or continues.
private GroundSide mcpCommon()(const(LibFn)[] lib) {
    GroundSide common;
    foreach (ref l; lib) {
        auto body_ = libmcpSources[l.src][l.fn.from .. l.fn.to];
        GroundSide read;
        if (l.fn.name == "mcp_dispatch") {
            auto first = indexIn(body_, "strcmp(r->method");
            cKeys(first < 0 ? body_ : body_[0 .. cast(size_t) first], mcpReader, read);
            addAll(common.reads, read.reads.slice());
        } else if (l.fn.name == "build_message" || l.fn.name == "mcp_request_resume") {
            cKeys(body_, mcpReader, read);
            addAll(common.writes, read.writes.slice());
        }
    }
    return common;
}

private void addAll(K)(ref K to, const(char)[] list) {
    size_t s = 0;
    foreach (i; 0 .. list.length + 1)
        if (i == list.length || list[i] == ',') {
            to.add(list[s .. i]);
            s = i + 1;
        }
}

private struct McpSides { GroundSide[64] items; size_t count; }

private McpSides buildMcpSides()() {
    McpSides ms;
    auto libFns = libmcpFns();
    auto lib = libFns.items[0 .. libFns.count];
    auto common = mcpCommon(lib);
    foreach (s; libmcpSources) {
        size_t i = 0;
        while (i < s.length) {
            if (s[i] != '"') {
                auto j = pastC(s, i);
                i = j == i ? i + 1 : j;
                continue;
            }
            auto end = pastC(s, i);
            auto t = s[i + 1 .. end - 1];
            i = end;
            if (!methodLike(t)) continue;
            bool seen = false;
            foreach (ref m; ms.items[0 .. ms.count]) if (m.event == t) seen = true;
            if (seen) continue;
            assert(ms.count < ms.items.length, "libmcp names more methods than parity holds");
            auto side = mcpSide(lib, t);
            addAll(side.reads, common.reads.slice());
            addAll(side.writes, common.writes.slice());
            ms.items[ms.count++] = side;
        }
    }
    return ms;
}

private static immutable McpSides mcpSides = buildMcpSides();

ref immutable(GroundSide) sideFor(const(char)[] agent, const(char)[] event) {
    if (agent == "mcp") {
        foreach (ref s; mcpSides.items[0 .. mcpSides.count]) if (s.event == event) return s;
        return codeSide;
    }
    if (agent != "acp") return sideOf(agent, event);
    foreach (ref s; codeSides.items[0 .. codeSides.count]) if (s.event == event) return s;
    return codeSide;
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

// --- the series: a row a spec a run, a point a harness a run ---

// "is to record how we are doing on parity over time against different specs and also have that plot as a line."
// A harness's total is the mean of its cells. A spec with neither side is no cell.
int total(const(int)[] cells) { return meanOf(cells); }

struct Point { const(char)[] agent; const(char)[] when; int total; }

struct Tex {
    char[16384] buf = 0;
    size_t n;
    void put(const(char)[] s) { foreach (c; s) if (n < buf.length) buf[n++] = c; }
    void putInt(int v) {
        char[12] d;
        int k = 0;
        do { d[k++] = cast(char)('0' + v % 10); v /= 10; } while (v > 0);
        while (k > 0) put(d[--k .. k + 1]);
    }
    const(char)[] text() const return { return buf[0 .. n]; }
}

// "so we give each harness a line for total coverage"
// "and ACP as well separately"
// One line a harness, in the order the harnesses were first measured; x is
// the run, y its total. No run, no plot.
Tex seriesTex(const(Point)[] pts) {
    Tex t;
    if (pts.length == 0) return t;
    t.put("\\begin{tikzpicture}\n"
        ~ "\\begin{axis}[date coordinates in=x, xticklabel={\\day.\\month.}, ymin=0, ymax=100, "
        ~ "ylabel={\\%}, legend pos=north west, width=\\textwidth, height=60mm]\n");
    foreach (i, p; pts) {
        bool seen = false;
        foreach (q; pts[0 .. i]) if (q.agent == p.agent) { seen = true; break; }
        if (seen) continue;
        t.put("\\addplot coordinates {");
        bool first = true;
        foreach (q; pts) {
            if (q.agent != p.agent) continue;
            if (!first) t.put(" ");
            first = false;
            t.put("("); t.put(q.when); t.put(","); t.putInt(percentOf(q.total)); t.put(")");
        }
        t.put("};\n\\addlegendentry{"); t.put(p.agent); t.put("}\n");
    }
    t.put("\\end{axis}\n\\end{tikzpicture}\n");
    return t;
}

// A run's score for one spec is an attestation: ground at this version said,
// of this agent at this release, this total. Appended, never replaced, so the
// series is every run and sky carries each row like any other.
bool attestParity(sqlite3* db, const(char)[] agent, const(char)[] release, const(char)[] sha,
                  int total, const(char)[] ts) {
    import db : versionString, jsonArray1;
    __gshared ZBuf id, subjects, contexts, attrs;
    id.reset();
    id.put("ground:parity:"); id.put(agent); id.put(":"); id.put(release); id.put(":"); id.put(ts);
    id.put(":"); id.put(versionString());
    __gshared ZBuf subject;
    subject.reset(); subject.put("ground:"); subject.put(versionString());
    jsonArray1(subjects, subject.slice());
    __gshared ZBuf context;
    context.reset(); context.put(agent); context.put(":"); context.put(release);
    jsonArray1(contexts, context.slice());
    Tex num;
    num.putInt(total);
    attrs.reset();
    attrs.put(`{"agent":"`); attrs.put(agent); attrs.put(`","release":"`); attrs.put(release);
    attrs.put(`","sha256":"`); attrs.put(sha); attrs.put(`","total":`); attrs.put(num.text()); attrs.put("}");

    enum sql = "INSERT OR IGNORE INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) "
        ~ "VALUES (?1, ?2, '[\"parity\"]', ?3, '[\"ground\"]', ?4, 'ground', ?5)\0";
    sqlite3_stmt* st;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &st, null) != SQLITE_OK) return false;
    bind(st, 1, id.slice());
    bind(st, 2, subjects.slice());
    bind(st, 3, contexts.slice());
    bind(st, 4, ts);
    bind(st, 5, attrs.slice());
    auto ok = sqlite3_step(st) == SQLITE_DONE;
    sqlite3_finalize(st);
    return ok;
}

struct Series {
    char[32][64] agents;
    ubyte[64] agentLen;
    char[16][64] whens;
    int[64] totals;
    size_t count;
    Point at(size_t i) const return {
        return Point(agents[i][0 .. agentLen[i]], whens[i][0 .. 16], totals[i]);
    }
}

// Every run, oldest first: a harness's point is the mean of its specs' totals
// in that run, and the minute it was measured.
Series readSeries(sqlite3* db) {
    Series s;
    enum sql = "SELECT json_extract(attributes, '$.agent'), "
        ~ "substr(timestamp, 1, 10) || ' ' || substr(timestamp, 12, 5), "
        ~ "CAST(round(avg(json_extract(attributes, '$.total'))) AS INTEGER) "
        ~ "FROM attestations WHERE json_extract(predicates, '$[0]') = 'parity' "
        ~ "GROUP BY 1, timestamp ORDER BY timestamp, min(rowid)\0";
    sqlite3_stmt* st;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &st, null) != SQLITE_OK) return s;
    while (sqlite3_step(st) == SQLITE_ROW && s.count < s.totals.length) {
        auto agent = cstr(sqlite3_column_text(st, 0));
        auto when = cstr(sqlite3_column_text(st, 1));
        if (agent.length > s.agents[0].length || when.length != 16) continue;
        foreach (i, c; agent) s.agents[s.count][i] = c;
        s.agentLen[s.count] = cast(ubyte) agent.length;
        foreach (i, c; when) s.whens[s.count][i] = c;
        s.totals[s.count] = cast(int) sqlite3_column_int64(st, 2);
        s.count++;
    }
    sqlite3_finalize(st);
    return s;
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
    else if (pin.agent == "mcp") { add("/.local/lib/ground/mcp/"); add(pin.release); add("/schema.json"); }
    // where agy's installer puts it
    else if (pin.agent == "agy") add("/.local/bin/agy");
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

private void readAgy(const(char)[] text) {
    auto anchor = agyAnchor(text);
    if (anchor < 0) return;
    Keys common;
    if (!agyMessage(text, cast(size_t) anchor, "HookArgsCommon", common)) { unread("HookArgsCommon"); return; }
    foreach (ref e; agyEvents) {
        Keys input = common;
        Keys output;
        if (!agyMessage(text, cast(size_t) anchor, e[1], input)) { unread(e[1]); continue; }
        if (!agyMessage(text, cast(size_t) anchor, e[2], output)) { unread(e[2]); continue; }
        addSpec(e[0], input, output);
    }
}

private void unread(const(char)[] message) {
    say("ground_parity:agy's hooks.proto has no message ");
    say(message);
    say("\n");
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

// Every method a version names, from the unions that say who sends it.
private void readMcp(const(char)[] text) {
    foreach (ref u; mcpUnions) {
        auto union_ = mcpDef(text, u[0]);
        if (union_ is null) continue;
        size_t from = 0;
        while (true) {
            auto r = indexIn(union_, mcpRef, from);
            if (r < 0) break;
            from = cast(size_t) r + mcpRef.length;
            auto method = mcpMethodOf(mcpDef(text, mcpRefAt(union_, from)));
            if (method is null || haveSpec(method)) continue;
            Keys input, output;
            mcpSpec(text, method, input, output);
            addSpec(method, input, output);
        }
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
    else if (pin.agent == "mcp") readMcp(text);
    else if (pin.agent == "agy") readAgy(text);
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

private struct Row { char[64] event = 0; size_t len; int[maxPins] cells = -1; }
private __gshared Row[192] rows;
private __gshared size_t rowCount;
private __gshared long[maxPins] measuredAt;

// The table a pin is set in: the hook harnesses', ACP's or MCP's.
private const(char)[] tableOf(const(char)[] agent) {
    return agent == "acp" || agent == "mcp" ? agent : "hooks";
}

// `ground_parity tex mcp` sets MCP's table alone, for libMCP's section.
private __gshared bool texMcp;

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

// `ground_parity tex` sets the same table for the book: cells parted by &,
// rows ended by \\, and the characters TeX reads as instructions escaped.
private __gshared bool texOut;

private void cell() { put(texOut ? " & " : "| "); }
private void eol() { put(texOut ? " \\\\\n" : "\n"); }

private void putName(const(char)[] s, size_t width) {
    if (!texOut) { putPad(s, width); return; }
    foreach (c; s) {
        if (c == '_' || c == '#' || c == '%' || c == '&' || c == '$' || c == '{' || c == '}') put("\\");
        put((&c)[0 .. 1]);
    }
}

// A release on the page: a dated one, as MCP's are, set as its year over the
// rest, so five versions fit across the page.
private void putRelease(const(char)[] release) {
    auto dash = texOut ? indexIn(release, "-") : -1;
    if (dash < 0) { put(release); return; }
    put("\\shortstack{"); put(release[0 .. cast(size_t) dash]); put("\\\\");
    put(release[cast(size_t) dash + 1 .. $]); put("}");
}

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
    if (texOut) buf[n++] = '\\';
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

private void render(sqlite3* db, const(char)[] only, ref Measured[maxPins] status) {
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

    // "and put acp in a separatae table separate page"
    // One table over the group of pins it is asked for: hooks, acp or mcp.
    void table(const(char)[] group) {
        // An empty group is every table but MCP's, as the terminal shows it.
        bool shown(size_t pi) {
            auto t = tableOf(pins[pi].agent);
            return group.length == 0 ? t != "mcp" : t == group;
        }
        bool any(ref const Row r) {
            foreach (pi; 0 .. pins.length) if (shown(pi) && r.cells[pi] >= 0) return true;
            return false;
        }

        // A row is an event some pinned version names; a member of ground's
        // enum that no agent sends is not one.
        size_t eventWidth = 7;
        foreach (i; 0 .. rowCount)
            if (any(rows[i]) && rows[i].len + 1 > eventWidth) eventWidth = rows[i].len + 1;

        // One agent's mean is the overall: its column is set only beside another's.
        size_t agentsShown = 0;
        for (size_t pi = 0; pi < pins.length;) {
            auto agent = pins[pi].agent;
            if (shown(pi)) agentsShown++;
            while (pi < pins.length && pins[pi].agent == agent) pi++;
        }
        bool several = agentsShown > 1;

        if (texOut) {
            put("\\begin{center}\\small\\begin{tabular}{l|r");
            for (size_t pi = 0; pi < pins.length;) {
                auto agent = pins[pi].agent;
                if (several && shown(pi)) put("|r");
                while (pi < pins.length && pins[pi].agent == agent) { if (shown(pi)) put("|r"); pi++; }
            }
            put("}\n");
        }
        putPad("Event:", eventWidth);
        cell(); put("overall ");
        for (size_t pi = 0; pi < pins.length;) {
            auto agent = pins[pi].agent;
            if (several && shown(pi)) { cell(); put(texOut ? "" : "## "); put(agent); put(" "); }
            while (pi < pins.length && pins[pi].agent == agent) {
                if (shown(pi)) { cell(); putRelease(pins[pi].release); put(" "); }
                pi++;
            }
        }
        eol();
        if (texOut) put("\\hline\n");

        foreach (i; 0 .. rowCount) {
            if (!any(rows[i])) continue;
            int[maxPins] agentMeans = -1;
            size_t agents = 0;
            for (size_t pi = 0; pi < pins.length;) {
                auto agent = pins[pi].agent;
                size_t from = pi;
                while (pi < pins.length && pins[pi].agent == agent) pi++;
                if (shown(from)) agentMeans[agents++] = meanOf(rows[i].cells[from .. pi]);
            }
            char[8] pb;
            putName(rows[i].event[0 .. rows[i].len], eventWidth);
            cell(); putPad(percentText(meanOf(agentMeans[0 .. agents]), pb), 8);
            size_t a = 0;
            for (size_t pi = 0; pi < pins.length;) {
                auto agent = pins[pi].agent;
                if (several && shown(pi)) { cell(); putPad(percentText(agentMeans[a++], pb), agent.length + 4); }
                while (pi < pins.length && pins[pi].agent == agent) {
                    if (shown(pi)) { cell(); putPad(percentText(rows[i].cells[pi], pb), pins[pi].release.length + 1); }
                    pi++;
                }
            }
            eol();
        }
        if (texOut) put("\\end{tabular}\\end{center}\n\n");
    }

    if (only.length == 0 && !texOut) {
        table("");
        put("\n");
        table("mcp");
    }

    if (texMcp) {
        table("mcp");
        return;
    }

    // The book carries no path from this machine, and the series is its own.
    if (texOut) {
        table("hooks");
        auto s = readSeries(db);
        Point[64] pts;
        foreach (i; 0 .. s.count) pts[i] = s.at(i);
        put(seriesTex(pts[0 .. s.count]).text());
        bool anyAcp = false;
        foreach (ref pin; pins) if (pin.agent == "acp") anyAcp = true;
        if (anyAcp) {
            put("\\clearpage\n\\gsection{acp}\n");
            table("acp");
        }
        return;
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
                put(tableOf(pin.agent) != "hooks" ? "no methods read from " : "no hook schemas read from ");
                put(m.path[0 .. m.pathLen]);
                break;
            case Access.absent:
                put(tableOf(pin.agent) != "hooks" ? "no schema at " : "no binary at ");
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
    texOut = only == "tex";
    if (texOut) only = "";
    texMcp = texOut && argc >= 4 && cstr(argv[3]) == "mcp";

    auto db = openDb();
    if (db is null) {
        fputs("ground_parity:the store would not open\n", stderr);
        return 1;
    }

    Measured[maxPins] status;
    int rc = 0;
    // The book reads the store and measures nothing: a build is not a run.
    foreach (pi, ref pin; pins) {
        if (texOut) break;
        status[pi] = measure(pin);
        if (status[pi].access != Access.live) continue;
        bool overflow = specsFull;
        foreach (i; 0 .. specCount) if (specs[i].input.full || specs[i].output.full) overflow = true;
        if (overflow) {
            say("ground_parity:"); say(pin.agent); say(" "); say(pin.release);
            say(" names more than parity holds; nothing stored for it\n");
            status[pi].access = Access.empty;
            rc = 1;
            continue;
        }
        if (!storeSpecs(db, pin.agent, pin.release, status[pi].sha[], cast(long) time(null))) {
            say("ground_parity:the store refused "); say(pin.agent); say(" "); say(pin.release);
            say("'s contract; the stored one stands\n");
            status[pi].access = Access.empty;
            rc = 1;
        }
    }

    render(db, only, status);

    // A whole run is attested, one row a spec, at the minute it was rendered.
    if (!texOut && only.length == 0) {
        import db : formatTimestamp;
        auto ts = formatTimestamp();
        foreach (pi, ref pin; pins) {
            int[192] cells;
            foreach (i; 0 .. rowCount) cells[i] = rows[i].cells[pi];
            auto t = total(cells[0 .. rowCount]);
            if (t < 0) continue;
            if (!attestParity(db, pin.agent, pin.release, pin.sha256, t, ts)) {
                say("ground_parity:the store refused the run's row for "); say(pin.agent); say(" "); say(pin.release); say("\n");
                rc = 1;
            }
        }
    }
    sqlite3_close(db);
    return rc;
}
