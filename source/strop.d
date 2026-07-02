module strop;

// Value-shape validator on an extracted Bash flag value. Fifth Control field
// alongside arg/omit/omitLine/clamp — the first pure validator (the others
// rewrite the command; strop denies on shape mismatch).
//
// stropDispatch: extract value for `flag`, run matchStrop, deny with computed
// message on miss. Match is anchored at pos 0; trailing content is allowed.
//
// Sequences (max 4) are tried in declaration order — first sequence that
// consumes a valid prefix wins → allow. All fail → deny.
//
// Primitives: literal, letters(min..max) [A-Z only], digits(min..max),
// oneof([...]), any(max: N — stops at '\n').
//
// Runtime: strop matches append to results.matches independent of
// checkAllCommands' single-winner-per-segment selection, so they co-fire
// with amendment and fallback controls.

import lexer : skipWS, skipLine, expect, readWord, readValue;

struct MatchResult {
    bool ok;
    size_t consumed;
}

enum PartKind {
    Literal,
    Letters,
    Digits,
    Any,
    Oneof,
}

enum MAX_ONEOF_WORDS = 8;
enum MAX_PARTS = 8;
enum MAX_SEQUENCES = 32;
enum MAX_STROP_POOL = 16; // Max strop-using controls across the whole config.

struct Part {
    PartKind kind;
    size_t min;
    size_t max;
    string literal;
    string[MAX_ONEOF_WORDS] words;
    ubyte wordCount;
}

struct Sequence {
    Part[MAX_PARTS] parts;
    ubyte partCount;
    const(Part)[] items() const return { return parts[0 .. partCount]; }
}

struct Strop {
    string flag;
    Sequence[MAX_SEQUENCES] sequences;
    ubyte sequenceCount;
}

MatchResult matchLiteral(string literal, string input, size_t pos) {
    if (pos + literal.length > input.length) return MatchResult(false, 0);
    if (input[pos .. pos + literal.length] != literal) return MatchResult(false, 0);
    return MatchResult(true, literal.length);
}

MatchResult matchLetters(size_t min, size_t max, string input, size_t pos) {
    size_t count = 0;
    while (pos + count < input.length && count < max) {
        char c = input[pos + count];
        if (c < 'A' || c > 'Z') break;
        count++;
    }
    if (count < min) return MatchResult(false, 0);
    return MatchResult(true, count);
}

MatchResult matchDigits(size_t min, size_t max, string input, size_t pos) {
    size_t count = 0;
    while (pos + count < input.length && count < max) {
        char c = input[pos + count];
        if (c < '0' || c > '9') break;
        count++;
    }
    if (count < min) return MatchResult(false, 0);
    return MatchResult(true, count);
}

MatchResult matchOneof(const(string)[] words, string input, size_t pos) {
    foreach (w; words) {
        auto r = matchLiteral(w, input, pos);
        if (r.ok) return r;
    }
    return MatchResult(false, 0);
}

// matchAny consumes up to `max` chars from pos until end-of-line (\n) or end of input.
// Succeeds iff the run does not exceed `max`.
MatchResult matchAny(size_t max, string input, size_t pos) {
    size_t count = 0;
    while (pos + count < input.length) {
        char c = input[pos + count];
        if (c == '\n') break;
        count++;
    }
    if (count > max) return MatchResult(false, 0);
    return MatchResult(true, count);
}

MatchResult matchSequence(const Part[] parts, string input, size_t pos) {
    size_t cursor = pos;
    foreach (p; parts) {
        MatchResult r;
        final switch (p.kind) {
            case PartKind.Literal:
                r = matchLiteral(p.literal, input, cursor);
                break;
            case PartKind.Letters:
                r = matchLetters(p.min, p.max, input, cursor);
                break;
            case PartKind.Digits:
                r = matchDigits(p.min, p.max, input, cursor);
                break;
            case PartKind.Any:
                r = matchAny(p.max, input, cursor);
                break;
            case PartKind.Oneof:
                r = matchOneof(p.words[0 .. p.wordCount], input, cursor);
                break;
        }
        if (!r.ok) return MatchResult(false, 0);
        cursor += r.consumed;
    }
    return MatchResult(true, cursor - pos);
}

MatchResult matchStrop(const Strop s, string input) {
    foreach (i; 0 .. s.sequenceCount) {
        auto r = matchSequence(s.sequences[i].items, input, 0);
        if (r.ok) return r;
    }
    return MatchResult(false, 0);
}

// --- Builders (CTFE-safe) ---

Part letters(size_t min, size_t max) {
    Part p; p.kind = PartKind.Letters; p.min = min; p.max = max; return p;
}

Part digits(size_t min, size_t max) {
    Part p; p.kind = PartKind.Digits; p.min = min; p.max = max; return p;
}

Part literal(string s) {
    Part p; p.kind = PartKind.Literal; p.literal = s; return p;
}

Part any(size_t max) {
    Part p; p.kind = PartKind.Any; p.max = max; return p;
}

Part oneof(const(string)[] words) {
    Part p; p.kind = PartKind.Oneof;
    size_t n = words.length > MAX_ONEOF_WORDS ? MAX_ONEOF_WORDS : words.length;
    foreach (i; 0 .. n) p.words[i] = words[i];
    p.wordCount = cast(ubyte) n;
    return p;
}

Sequence sequence(const(Part)[] parts) {
    Sequence s;
    size_t n = parts.length > MAX_PARTS ? MAX_PARTS : parts.length;
    foreach (i; 0 .. n) s.parts[i] = parts[i];
    s.partCount = cast(ubyte) n;
    return s;
}

Strop strop(const(Sequence)[] seqs) {
    Strop s;
    size_t n = seqs.length > MAX_SEQUENCES ? MAX_SEQUENCES : seqs.length;
    foreach (i; 0 .. n) s.sequences[i] = seqs[i];
    s.sequenceCount = cast(ubyte) n;
    return s;
}

// Parse a strop block. Caller has consumed 'strop {'. We read until '}'.
Strop parseStropBlock(ref string input, ref size_t pos) {
    Strop s;
    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }
        if (input[pos] == '}') { pos++; return s; }

        auto key = readWord(input, pos);
        skipWS(input, pos);

        if (key == "sequence") {
            expect(input, pos, '[');
            Sequence seq = parseSequenceBody(input, pos);
            assert(s.sequenceCount < MAX_SEQUENCES, "Strop sequence overflow");
            s.sequences[s.sequenceCount++] = seq;
            continue;
        }

        expect(input, pos, ':');
        skipWS(input, pos);
        auto val = readValue(input, pos);

        switch (key) {
            case "flag": s.flag = val; break;
            default: assert(0, "Unknown strop field");
        }
    }
    assert(0, "Unterminated strop block");
}

// Parse a sequence body. Caller has consumed '['. We read parts until ']'.
Sequence parseSequenceBody(ref string input, ref size_t pos) {
    Sequence seq;
    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == ']') { pos++; return seq; }
        if (input[pos] == '#') { skipLine(input, pos); continue; }

        Part p = parsePart(input, pos);
        assert(seq.partCount < MAX_PARTS, "Sequence part overflow");
        seq.parts[seq.partCount++] = p;
    }
    assert(0, "Unterminated sequence body");
}

// Parse a single part like letters(1..2), digits(1..3), literal("..."), any(max: N), oneof([...]).
Part parsePart(ref string input, ref size_t pos) {
    // read name up to '('
    size_t nameStart = pos;
    while (pos < input.length && input[pos] != '(') pos++;
    string name = input[nameStart .. pos];
    expect(input, pos, '(');
    skipWS(input, pos);

    Part p;
    switch (name) {
        case "letters": {
            size_t lo = parseUint(input, pos);
            expectRangeDots(input, pos);
            size_t hi = parseUint(input, pos);
            p = letters(lo, hi);
            break;
        }
        case "digits": {
            size_t lo = parseUint(input, pos);
            expectRangeDots(input, pos);
            size_t hi = parseUint(input, pos);
            p = digits(lo, hi);
            break;
        }
        case "literal": {
            string val = readValue(input, pos);
            p = literal(val);
            break;
        }
        case "any": {
            // any(max: N)
            auto argKey = readWord(input, pos);
            assert(argKey == "max", "any expects max:");
            skipWS(input, pos);
            expect(input, pos, ':');
            skipWS(input, pos);
            size_t m = parseUint(input, pos);
            p = any(m);
            break;
        }
        case "oneof": {
            // oneof([WORD, WORD, ...])
            expect(input, pos, '[');
            string[MAX_ONEOF_WORDS] words;
            ubyte n = 0;
            while (pos < input.length) {
                skipWS(input, pos);
                if (pos < input.length && input[pos] == ']') { pos++; break; }
                size_t wStart = pos;
                while (pos < input.length && input[pos] != ',' && input[pos] != ']'
                        && input[pos] != ' ' && input[pos] != '\t'
                        && input[pos] != '\n' && input[pos] != '\r') pos++;
                assert(n < MAX_ONEOF_WORDS, "oneof word overflow");
                words[n++] = input[wStart .. pos];
                skipWS(input, pos);
                if (pos < input.length && input[pos] == ',') pos++;
            }
            p.kind = PartKind.Oneof;
            foreach (i; 0 .. n) p.words[i] = words[i];
            p.wordCount = n;
            break;
        }
        default:
            assert(0, "Unknown part kind");
    }

    skipWS(input, pos);
    expect(input, pos, ')');
    return p;
}

// Read an unsigned integer starting at pos.
size_t parseUint(ref string input, ref size_t pos) {
    size_t start = pos;
    while (pos < input.length && input[pos] >= '0' && input[pos] <= '9') pos++;
    assert(pos > start, "Expected digit");
    size_t result = 0;
    foreach (i; start .. pos) result = result * 10 + (input[i] - '0');
    return result;
}

// Consume '..'.
void expectRangeDots(ref string input, ref size_t pos) {
    expect(input, pos, '.');
    expect(input, pos, '.');
}

// --- Runtime dispatch (pure, TDD-driven) ---

enum MSG_BUF = 512;

struct StropDispatchResult {
    bool deny;
    char[MSG_BUF] msgBuf;
    ushort msgLen;
    string msg() const {
        return cast(string) msgBuf[0 .. msgLen];
    }
}

private void appendMsg(ref StropDispatchResult r, string s) {
    foreach (c; s) {
        if (r.msgLen >= r.msgBuf.length) break;
        r.msgBuf[r.msgLen++] = c;
    }
}

StropDispatchResult stropDispatch(const Strop s, string command) {
    StropDispatchResult res;
    auto ex = extractFlag(command, s.flag);
    if (!ex.ok) {
        res.deny = true;
        appendMsg(res, "commit message flag ");
        appendMsg(res, s.flag);
        appendMsg(res, " not found on cmd");
        return res;
    }
    auto r = matchStrop(s, ex.value);
    if (!r.ok) {
        res.deny = true;
        appendMsg(res, "commit message shape mismatch: `");
        appendMsg(res, ex.value);
        appendMsg(res, "`");
        return res;
    }
    return res; // deny=false, msg empty
}

struct ExtractResult {
    bool ok;
    string value;
}

// Extract the value passed to `flag` in `cmd`.
// Handles: flag "value", flag 'value', flag value.
// Returns ok=false if flag isn't in cmd.
ExtractResult extractFlag(string cmd, string flag) {
    // Find flag preceded by space or at start, followed by space.
    size_t i = 0;
    while (i + flag.length <= cmd.length) {
        bool atBoundary = (i == 0) || (cmd[i - 1] == ' ');
        if (atBoundary && cmd[i .. i + flag.length] == flag) {
            size_t after = i + flag.length;
            if (after == cmd.length) return ExtractResult(false, "");
            if (cmd[after] == ' ') {
                // skip spaces
                size_t valStart = after + 1;
                while (valStart < cmd.length && cmd[valStart] == ' ') valStart++;
                if (valStart == cmd.length) return ExtractResult(false, "");
                char q = cmd[valStart];
                if (q == '"' || q == '\'') {
                    size_t end = valStart + 1;
                    while (end < cmd.length && cmd[end] != q) end++;
                    if (end == cmd.length) return ExtractResult(false, "");
                    return ExtractResult(true, cmd[valStart + 1 .. end]);
                }
                size_t end = valStart;
                while (end < cmd.length && cmd[end] != ' ') end++;
                return ExtractResult(true, cmd[valStart .. end]);
            }
        }
        i++;
    }
    return ExtractResult(false, "");
}
