module fingerprint;

// "So, let's say I am not wavering on wanting the rename's be detected by some measure"
//
// A row for a tool's use says the file's path and, on its way to the node, no
// text (stream.d). Ground has the file in hand while the hook runs, and leaves
// on the row what a renamed file is told by afterwards, as two attributes:
//
//     lines:  how many distinct lines the file has, each trimmed, blank ones left out
//     sketch: 128 values, the least of those lines under each of 128 orderings,
//             eight bytes each, the low byte first, in base64 with padding
//
// On a Read that showed the whole file, and on a Write. QNTX-Quotes measures
// two of these against each other, and fingerprint_test.d holds the values
// both agree on.

import zbuf : ZBuf;

// How many orderings a sketch holds the first line of.
enum ORDERINGS = 128;

// The largest file a hook reads for its fingerprint. A larger one gets none.
enum LARGEST = 8 * 1024 * 1024;

private enum ulong FNV_OFFSET = 0xcbf2_9ce4_8422_2325;
private enum ulong FNV_PRIME = 0x0000_0100_0000_01b3;
private enum ulong GOLDEN = 0x9E37_79B9_7F4A_7C15;

// FNV-1a over the bytes, 64 bits.
ulong fnv1a64(const(char)[] bytes) {
    ulong hash = FNV_OFFSET;
    foreach (c; bytes) hash = (hash ^ cast(ubyte) c) * FNV_PRIME;
    return hash;
}

// splitmix64's one step.
ulong splitmix64(ulong asked) {
    ulong z = asked + GOLDEN;
    z = (z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9;
    z = (z ^ (z >> 27)) * 0x94D0_49BB_1331_11EB;
    return z ^ (z >> 31);
}

struct Fingerprint {
    ulong lines;
    ulong[ORDERINGS] sketch;
}

// How many bytes at the start of text are one space, as Unicode names them
// (White_Space): QNTX-Quotes trims with Rust's str::trim, which takes these
// and no others.
private size_t spaceAt(const(char)[] text) {
    if (text.length == 0) return 0;
    auto a = cast(ubyte) text[0];
    if ((a >= 0x09 && a <= 0x0D) || a == 0x20) return 1;
    if (text.length >= 2 && a == 0xC2) {
        auto b = cast(ubyte) text[1];
        return (b == 0x85 || b == 0xA0) ? 2 : 0;
    }
    if (text.length < 3) return 0;
    auto b = cast(ubyte) text[1];
    auto c = cast(ubyte) text[2];
    // U+1680
    if (a == 0xE1 && b == 0x9A && c == 0x80) return 3;
    // U+2000 to U+200A, U+2028, U+2029, U+202F
    if (a == 0xE2 && b == 0x80 && ((c >= 0x80 && c <= 0x8A) || c == 0xA8 || c == 0xA9 || c == 0xAF)) return 3;
    // U+205F
    if (a == 0xE2 && b == 0x81 && c == 0x9F) return 3;
    // U+3000
    if (a == 0xE3 && b == 0x80 && c == 0x80) return 3;
    return 0;
}

// A line with the spaces at both its ends taken off.
private const(char)[] trimmed(const(char)[] line) {
    while (true) {
        auto n = spaceAt(line);
        if (n == 0) break;
        line = line[n .. $];
    }
    while (line.length > 0) {
        // The space that ends the line begins one, two or three bytes back.
        size_t took = 0;
        foreach (back; 1 .. 4) {
            if (back > line.length) break;
            if (spaceAt(line[$ - back .. $]) == back) { took = back; break; }
        }
        if (took == 0) break;
        line = line[0 .. $ - took];
    }
    return line;
}

extern (C) private int byValue(const(void)* a, const(void)* b) {
    auto x = *cast(const(ulong)*) a, y = *cast(const(ulong)*) b;
    return x < y ? -1 : (x > y ? 1 : 0);
}

// A text's fingerprint. False for a text with no lines, which has none.
bool fingerprintOf(const(char)[] text, ref Fingerprint f) {
    import core.stdc.stdlib : malloc, free, qsort;

    f.lines = 0;
    size_t most = 1;
    foreach (c; text) if (c == '\n') most++;
    auto hashes = cast(ulong*) malloc(most * ulong.sizeof);
    if (hashes is null) {
        import errors : sayQuietly;
        sayQuietly("fingerprint", "a file's fingerprint was not made: no memory for its lines", 0, "", "", "");
        return false;
    }
    scope (exit) free(hashes);

    size_t held = 0, at = 0;
    while (at <= text.length) {
        auto end = at;
        while (end < text.length && text[end] != '\n') end++;
        auto line = trimmed(text[at .. end]);
        if (line.length > 0) hashes[held++] = fnv1a64(line);
        at = end + 1;
    }
    if (held == 0) return false;

    // Each line once.
    qsort(hashes, held, ulong.sizeof, &byValue);
    size_t distinct = 1;
    foreach (i; 1 .. held) {
        if (hashes[i] != hashes[distinct - 1]) hashes[distinct++] = hashes[i];
    }

    foreach (i; 0 .. ORDERINGS) {
        ulong turn = cast(ulong) i * GOLDEN;
        ulong least = ulong.max;
        foreach (hash; hashes[0 .. distinct]) {
            auto under = splitmix64(hash ^ turn);
            if (under < least) least = under;
        }
        f.sketch[i] = least;
    }
    f.lines = distinct;
    return true;
}

// A sketch as it stands on a row.
void putSketch(ref ZBuf out_, ref const Fingerprint f) {
    enum letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    ubyte[ORDERINGS * 8] bytes;
    foreach (i, value; f.sketch) {
        foreach (b; 0 .. 8) bytes[i * 8 + b] = cast(ubyte)(value >> (8 * b));
    }
    size_t at = 0;
    while (at < bytes.length) {
        auto left = bytes.length - at;
        uint word = bytes[at] << 16;
        if (left > 1) word |= bytes[at + 1] << 8;
        if (left > 2) word |= bytes[at + 2];
        char[4] four = [
            letters[(word >> 18) & 63], letters[(word >> 12) & 63],
            left > 1 ? letters[(word >> 6) & 63] : '=', left > 2 ? letters[word & 63] : '=',
        ];
        out_.put(four[]);
        at += 3;
    }
}

// A whole number that is a member of the object opening at text[at], or -1.
private long numberIn(const(char)[] text, size_t at, const(char)[] key) {
    import effort : memberOf;
    auto m = memberOf(text, at, key);
    if (!m.ok || m.valAt >= m.valEnd) return -1;
    long n = 0;
    foreach (c; text[m.valAt .. m.valEnd]) {
        if (c < '0' || c > '9') return -1;
        n = n * 10 + (c - '0');
    }
    return n;
}

// Whether this event's tool had the whole of a file in hand: a Write, or a
// Read that began at the first line and showed as many lines as the file has,
// as the tool itself says of the read. A part of a file is not the file.
private bool hadTheWholeFile(const(char)[] payload) {
    import effort : rootAt, memberOf;
    import parse : extractToolName;
    auto tool = extractToolName(payload);
    if (tool is null) return false;
    if (tool == "Write") return true;
    if (tool != "Read") return false;
    auto root = rootAt(payload);
    if (root >= payload.length) return false;
    auto response = memberOf(payload, root, "tool_response");
    if (!response.ok) return false;
    auto file = memberOf(payload, response.valAt, "file");
    if (!file.ok) return false;
    auto shown = numberIn(payload, file.valAt, "numLines");
    return numberIn(payload, file.valAt, "startLine") == 1 && shown >= 0
        && shown == numberIn(payload, file.valAt, "totalLines");
}

// The text of the file at path, up to LARGEST. Null when it is not there, is
// no file that is read, or is larger.
private const(char)[] textOf(const(char)[] path) {
    import core.stdc.stdio : fopen, fread, fclose, fseek, ftell, SEEK_END, SEEK_SET;
    import core.stdc.stdlib : malloc, free;
    __gshared char* held;
    if (held !is null) { free(held); held = null; }
    if (path.length == 0 || path.length >= 4000) return null;
    char[4096] z = 0;
    foreach (i, c; path) z[i] = c;
    auto f = fopen(&z[0], "r");
    if (f is null) return null;
    scope (exit) fclose(f);
    if (fseek(f, 0, SEEK_END) != 0) return null;
    auto size = ftell(f);
    if (size <= 0 || size > LARGEST || fseek(f, 0, SEEK_SET) != 0) return null;
    held = cast(char*) malloc(size);
    if (held is null) {
        import errors : sayQuietly;
        sayQuietly("fingerprint", "a file's fingerprint was not made: no memory for its text", 0, "", "", path);
        return null;
    }
    auto got = fread(held, 1, size, f);
    return held[0 .. got];
}

// The row's attributes: what the event said, and, where its tool had the
// whole of a file in hand, that file's fingerprint as two members more. What
// is returned is payload itself, or row.
const(char)[] withFingerprint(const(char)[] eventName, const(char)[] payload, ref ZBuf row) {
    import parse : extractFilePath;
    if (__ctfe) return payload;
    if (eventName != "PostToolUse" || payload.length < 2 || !hadTheWholeFile(payload)) return payload;
    auto file = extractFilePath(payload);
    if (file is null) return payload;
    __gshared Fingerprint f;
    if (!fingerprintOf(textOf(file), f)) return payload;
    // Inside the object, before the brace that closes it.
    size_t close = payload.length;
    while (close > 0 && payload[close - 1] != '}') close--;
    if (close == 0) return payload;
    row.reset();
    row.put(payload[0 .. close - 1]);
    row.put(`,"lines":`);
    row.putUint(f.lines);
    row.put(`,"sketch":"`);
    putSketch(row, f);
    row.put(`"}`);
    return row.slice();
}
