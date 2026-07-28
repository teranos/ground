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
    Letters,   // A-Z
    Lower,     // a-z
    Digits,
    Any,     // rest of line, bounded from the cursor
    Line,    // rest of line, bounded across the WHOLE line
    Oneof,
    Newline,  // exactly one '\n' — unspellable as a literal, pbt has no escapes
    End,      // zero-width, matches only at end of input
    Repeat,   // marker: the next `bodyLen` parts repeat min..max times
    NotAhead, // marker: succeeds iff the next `bodyLen` parts do NOT match here
}

enum MAX_ONEOF_WORDS = 8;
enum MAX_PARTS = 64;   // markers and their bodies share this budget
enum MAX_SEQUENCES = 32;
enum MAX_STROP_POOL = 16; // Max strop-using controls across the whole config.

struct WordList {
    string[MAX_ONEOF_WORDS] words;
    ubyte count;
}

struct Part {
    PartKind kind;
    size_t min;
    size_t max;
    string literal;
    // oneof only: 1-based index into the owning Strop's wordPool, 0 = none.
    //
    // These eight strings used to live inline in every Part — 128 of its ~180
    // bytes — carried by every part of every sequence of every strop in the
    // pool, almost none of which are oneof. That is CTFE memory, which is the
    // axis bench.fish shows kills the build: MAX_PARTS=64 died with SIGKILL.
    ubyte wordsIdx;
    // Repeat only: how many of the parts FOLLOWING this one form the body.
    // Keeping the body inline in the same flat array avoids a recursive Part
    // — which cannot exist in a fixed-size CTFE struct — and makes the body a
    // plain slice. Nesting then costs nothing: a Repeat inside a body is just
    // another marker, handled by the same recursive call over that slice.
    ubyte bodyLen;
}

struct Sequence {
    Part[MAX_PARTS] parts;
    ubyte partCount;
    const(Part)[] items() const return { return parts[0 .. partCount]; }
}

enum MAX_ONEOF_LISTS = 8;

struct Strop {
    string flag;
    Sequence[MAX_SEQUENCES] sequences;
    ubyte sequenceCount;
    WordList[MAX_ONEOF_LISTS] wordPool;
    ubyte wordPoolLen;
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

// a-z. Separate from letters() rather than a case-insensitive flag on it:
// a track marker and its sub-step differ by case and nothing else, so S6a
// must match and S6A must not.
MatchResult matchLower(size_t min, size_t max, string input, size_t pos) {
    size_t count = 0;
    while (pos + count < input.length && count < max) {
        char c = input[pos + count];
        if (c < 'a' || c > 'z') break;
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

// Like any(), but the bound is on the WHOLE line rather than the tail from
// the cursor. Line length is a property of the line; a matcher that has
// already consumed a tag cannot express it with any(), and quietly permits
// tag-length more than it claims to.
//
// Scans back to the previous newline rather than threading a line-start
// through matchSequence — the input is one flag value, so this is cheap and
// keeps the primitive self-contained.
MatchResult matchLine(size_t max, string input, size_t pos) {
    size_t lineStart = pos;
    while (lineStart > 0 && input[lineStart - 1] != '\n') lineStart--;

    size_t end = pos;
    while (end < input.length && input[end] != '\n') end++;

    if (end - lineStart > max) return MatchResult(false, 0);
    return MatchResult(true, end - pos);
}

MatchResult matchSequence(const Part[] parts, string input, size_t pos,
                          const(WordList)[] pool = null) {
    size_t cursor = pos;
    size_t idx = 0;
    while (idx < parts.length) {
        auto p = parts[idx];

        if (p.kind == PartKind.Repeat) {
            // Body is the slice that follows. Recursing over it means a nested
            // Repeat needs no special handling — it is just another marker.
            auto bodyEnd = idx + 1 + p.bodyLen;
            if (bodyEnd > parts.length) return MatchResult(false, 0);
            auto body = parts[idx + 1 .. bodyEnd];

            size_t count = 0;
            while (count < p.max) {
                auto rep = matchSequence(body, input, cursor, pool);
                // Zero-width matches would spin forever; a body that consumes
                // nothing has nothing left to give.
                if (!rep.ok || rep.consumed == 0) break;
                cursor += rep.consumed;
                count++;
            }
            if (count < p.min) return MatchResult(false, 0);
            idx = bodyEnd;
            continue;
        }

        if (p.kind == PartKind.NotAhead) {
            auto bodyEnd = idx + 1 + p.bodyLen;
            if (bodyEnd > parts.length) return MatchResult(false, 0);
            auto guard = matchSequence(parts[idx + 1 .. bodyEnd], input, cursor, pool);
            if (guard.ok) return MatchResult(false, 0);
            idx = bodyEnd;   // consumes nothing — it is a boundary test
            continue;
        }

        MatchResult r;
        final switch (p.kind) {
            case PartKind.Repeat:
            case PartKind.NotAhead:
                assert(0, "handled above");
            case PartKind.Literal:
                r = matchLiteral(p.literal, input, cursor);
                break;
            case PartKind.Letters:
                r = matchLetters(p.min, p.max, input, cursor);
                break;
            case PartKind.Lower:
                r = matchLower(p.min, p.max, input, cursor);
                break;
            case PartKind.Digits:
                r = matchDigits(p.min, p.max, input, cursor);
                break;
            case PartKind.Any:
                r = matchAny(p.max, input, cursor);
                break;
            case PartKind.Line:
                r = matchLine(p.max, input, cursor);
                break;
            case PartKind.Newline:
                r = (cursor < input.length && input[cursor] == '\n')
                    ? MatchResult(true, 1) : MatchResult(false, 0);
                break;
            case PartKind.End:
                r = (cursor == input.length)
                    ? MatchResult(true, 0) : MatchResult(false, 0);
                break;
            case PartKind.Oneof:
                if (p.wordsIdx == 0 || p.wordsIdx > pool.length)
                    return MatchResult(false, 0);
                auto wl = pool[p.wordsIdx - 1];
                r = matchOneof(wl.words[0 .. wl.count], input, cursor);
                break;
        }
        if (!r.ok) return MatchResult(false, 0);
        cursor += r.consumed;
        idx++;
    }
    return MatchResult(true, cursor - pos);
}

unittest {
    // The lowercase sub-step is part of the format, not drift: B3a -> B3b ->
    // B3c is a deliberate run, and S6/S6a, R7/R7a do the same. letters() is
    // A-Z only, so expressing it needed a primitive that did not exist.
    Strop s;
    s.sequenceCount = 1;
    s.sequences[0].partCount = 4;
    s.sequences[0].parts[0] = letters(1, 1);
    s.sequences[0].parts[1] = digits(1, 2);
    s.sequences[0].parts[2] = lower(1, 1);
    s.sequences[0].parts[3] = literal(":");

    assert(matchStrop(s, "S6a: per-branch preview deploys").ok);
    assert(matchStrop(s, "B3c: panic button").ok);
    assert(matchStrop(s, "M2g: atproto login").ok);
    assert(matchStrop(s, "R16a: two-digit track").ok);

    assert(!matchStrop(s, "S6: no sub-step here").ok);
    assert(!matchStrop(s, "S6A: uppercase is not a sub-step").ok);
    assert(!matchStrop(s, "6a: no track letter").ok);
}

unittest {
    // The whole point: any() bounds the TAIL from wherever the cursor sits,
    // line() bounds the LINE. After a tag is consumed they disagree, and the
    // disagreement is the common case — a 12-char tag makes any(max: 80) pass
    // a 92-char line while claiming to enforce 80.
    enum input = "TAG: rest";   // 9 chars, cursor at 5 after "TAG: "

    assert(matchAny(8, input, 5).ok, "tail is 4 chars, any is satisfied");
    assert(!matchLine(8, input, 5).ok, "line is 9 chars, line() is not");

    assert(matchLine(9, input, 5).ok, "exactly at the ceiling passes");
    assert(matchLine(9, input, 5).consumed == 4, "consumes the tail, like any");
}

unittest {
    // Second line measures from its own start, not the buffer's.
    enum input = "first\nsecondline";
    assert(matchLine(10, input, 6).ok, "second line is 10 chars");
    assert(!matchLine(9, input, 6).ok);
}

unittest {
    // Empty line is fine.
    assert(matchLine(80, "\n", 0).ok);
    assert(matchLine(80, "", 0).ok);
}

unittest {
    // repeat is a marker in the SAME flat part array: it carries how many of
    // the parts that follow form its body. No recursive Part, no allocation —
    // the body is just a slice, which is also why nesting comes free.
    Sequence seq;
    seq.parts[0] = repeat(1, 2, 1);
    seq.parts[1] = literal("ab");
    seq.partCount = 2;

    assert(!matchSequence(seq.items, "x", 0).ok, "min 1 not met");
    assert(matchSequence(seq.items, "ab", 0).consumed == 2);
    assert(matchSequence(seq.items, "abab", 0).consumed == 4);
    // Greedy but bounded: the third repetition is left unconsumed, not failed.
    assert(matchSequence(seq.items, "ababab", 0).consumed == 4);
}

unittest {
    // min 0 means the body may be absent entirely, and parts after the repeat
    // still match.
    Sequence seq;
    seq.parts[0] = repeat(0, 3, 1);
    seq.parts[1] = literal("x");
    seq.parts[2] = literal("!");
    seq.partCount = 3;

    assert(matchSequence(seq.items, "!", 0).consumed == 1);
    assert(matchSequence(seq.items, "xxx!", 0).consumed == 4);
    assert(!matchSequence(seq.items, "xxxx!", 0).ok, "4 exceeds max 3");
}

unittest {
    // Multi-part body: repeat(0..2)[ literal("a") literal("b") ]
    Sequence seq;
    seq.parts[0] = repeat(0, 2, 2);
    seq.parts[1] = literal("a");
    seq.parts[2] = literal("b");
    seq.partCount = 3;

    assert(matchSequence(seq.items, "", 0).ok);
    assert(matchSequence(seq.items, "ab", 0).consumed == 2);
    assert(matchSequence(seq.items, "abab", 0).consumed == 4);
    assert(matchSequence(seq.items, "aba", 0).consumed == 2, "partial body not taken");
}

MatchResult matchStrop(const Strop s, string input) {
    foreach (i; 0 .. s.sequenceCount) {
        auto r = matchSequence(s.sequences[i].items, input, 0,
                               s.wordPool[0 .. s.wordPoolLen]);
        if (r.ok) return r;
    }
    return MatchResult(false, 0);
}

// --- Builders (CTFE-safe) ---

Part letters(size_t min, size_t max) {
    Part p; p.kind = PartKind.Letters; p.min = min; p.max = max; return p;
}

Part lower(size_t min, size_t max) {
    Part p; p.kind = PartKind.Lower; p.min = min; p.max = max; return p;
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

Part line(size_t max) {
    Part p; p.kind = PartKind.Line; p.max = max; return p;
}

Part repeat(size_t min, size_t max, ubyte bodyLen) {
    Part p; p.kind = PartKind.Repeat; p.min = min; p.max = max; p.bodyLen = bodyLen; return p;
}

Part newline() {
    Part p; p.kind = PartKind.Newline; return p;
}

// Matching is anchored at position 0 and trailing content is allowed, so
// without this a malformed body is indistinguishable from "the rest of the
// string, which we permit". Enforcing a whole document needs an end anchor.
Part end() {
    Part p; p.kind = PartKind.End; return p;
}

Part notAhead(ubyte bodyLen) {
    Part p; p.kind = PartKind.NotAhead; p.bodyLen = bodyLen; return p;
}

// Words live in the owning Strop's pool, not in the Part.
Part oneof(const(string)[] words, ref Strop owner) {
    Part p; p.kind = PartKind.Oneof;
    assert(owner.wordPoolLen < MAX_ONEOF_LISTS, "oneof list overflow");
    WordList wl;
    size_t n = words.length > MAX_ONEOF_WORDS ? MAX_ONEOF_WORDS : words.length;
    foreach (i; 0 .. n) wl.words[i] = words[i];
    wl.count = cast(ubyte) n;
    owner.wordPool[owner.wordPoolLen] = wl;
    owner.wordPoolLen++;
    p.wordsIdx = owner.wordPoolLen;   // 1-based
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

unittest {
    // notahead consumes nothing and inverts. Without it a greedy repeat over
    // line(max:) cannot stop at a boundary, because line() matches every line
    // — blank separators and subthing tags included.
    string src = `flag: "-m"
      sequence [
        literal("A") newline()
        repeat(0..3)[ notahead[ newline() ] line(max: 80) newline() ]
        newline()
      ]
    }`;
    size_t pos = 0;
    auto s = parseStropBlock(src, pos);

    // Stops at the blank line instead of eating it.
    assert(matchStrop(s, "A\n\n").ok, "zero opening lines");
    assert(matchStrop(s, "A\nb\n\n").ok, "one opening line");
    assert(matchStrop(s, "A\nb\nc\n\n").ok, "two opening lines");
    assert(!matchStrop(s, "A\nb\nc\nd\ne\n\n").ok, "four exceeds the bound");

    // Without the blank terminator the sequence is unsatisfied.
    assert(!matchStrop(s, "A\nb\nc\n").ok);
}

unittest {
    // notahead on a tag shape: continuation lines stop at the next subthing.
    string src = `flag: "-m"
      sequence [
        repeat(0..3)[ notahead[ lower(1..20) literal(":") ] line(max: 80) newline() ]
        lower(1..20) literal(":")
      ]
    }`;
    size_t pos = 0;
    auto s = parseStropBlock(src, pos);

    assert(matchStrop(s, "sub:").ok, "no continuations");
    assert(matchStrop(s, "one\ntwo\nsub:").ok, "stops before the tag");
    assert(!matchStrop(s, "one\ntwo\nthree\nfour\nsub:").ok, "bound still applies");
}

unittest {
    // The full ground grammar, exercised through the parser.
    string src = `flag: "-m"
      sequence [
        letters(1..20)
        repeat(0..3)[ literal("_") letters(0..20) digits(0..4) ]
        literal(": ")
        line(max: 80)
        repeat(0..1)[
          newline()
          repeat(0..2)[ notahead[ newline() ] line(max: 80) newline() ]
          repeat(0..1)[
            newline()
            repeat(0..5)[
              lower(1..20)
              literal(": ")
              line(max: 80)
              newline()
              repeat(0..3)[ notahead[ newline() ] notahead[ lower(1..20) literal(": ") ] line(max: 80) newline() ]
              repeat(0..1)[ newline() ]
            ]
          ]
        ]
        end()
      ]
    }`;
    size_t pos = 0;
    auto s = parseStropBlock(src, pos);

    assert(matchStrop(s, "THING: does a thing").ok, "subject alone");
    assert(matchStrop(s, "THING_1: tagged with a digit").ok);
    assert(matchStrop(s, "THING_ONE: tagged with a word").ok);

    assert(!matchStrop(s, "lowercase: not a THING").ok);
    assert(!matchStrop(s, "THING no colon").ok);

    // end() is what makes the body enforceable rather than "trailing content".
    assert(!matchStrop(s, "THING: x\nbody without a blank separator\n\nrogue").ok);

    enum full =
        "THING: does a thing\n"
        ~ "second opening line\n"
        ~ "\n"
        ~ "first: what it is\n"
        ~ "continuation one\n"
        ~ "\n"
        ~ "second: another\n";
    assert(matchStrop(s, full).ok, "opening block plus two subthings");
}

unittest {
    // Parser round-trip, with a repeat nested inside a repeat body.
    string src = `flag: "-m"
      sequence [ literal("A") repeat(0..2)[ literal("b") repeat(0..3)[ literal("c") ] ] ]
    }`;
    size_t pos = 0;
    auto s = parseStropBlock(src, pos);
    assert(s.sequenceCount == 1);

    assert(matchStrop(s, "A").consumed == 1, "outer repeat may match zero times");
    assert(matchStrop(s, "Ab").consumed == 2, "inner repeat may match zero times");
    assert(matchStrop(s, "Abccc").consumed == 5);
    assert(matchStrop(s, "Abcccbccc").consumed == 9, "two outer iterations");
    assert(matchStrop(s, "Abcccc").consumed == 5, "inner capped at 3");
    assert(!matchStrop(s, "b").ok, "literal A is still required");
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
            Sequence seq = parseSequenceBody(input, pos, s);
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
Sequence parseSequenceBody(ref string input, ref size_t pos, ref Strop owner) {
    Sequence seq;
    fillSequence(input, pos, seq, owner);
    return seq;
}

// Appends parts into `seq` until the matching ']'. Split out from
// parseSequenceBody so repeat can call it for its own body — which is what
// makes nesting work: an inner repeat lands contiguously after the outer
// marker, so the outer bodyLen still counts a single unbroken run.
void fillSequence(ref string input, ref size_t pos, ref Sequence seq, ref Strop owner) {
    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == ']') { pos++; return; }
        if (input[pos] == '#') { skipLine(input, pos); continue; }

        enum notKw = "notahead[";
        if (pos + notKw.length <= input.length && input[pos .. pos + notKw.length] == notKw) {
            pos += notKw.length;
            assert(seq.partCount < MAX_PARTS, "Sequence part overflow");
            auto markerIdx = seq.partCount;
            seq.partCount++;
            auto bodyStart = seq.partCount;
            fillSequence(input, pos, seq, owner);
            auto bodyLen = seq.partCount - bodyStart;
            assert(bodyLen <= ubyte.max, "notahead body too long");
            seq.parts[markerIdx] = notAhead(cast(ubyte) bodyLen);
            continue;
        }

        enum kw = "repeat(";
        if (pos + kw.length <= input.length && input[pos .. pos + kw.length] == kw) {
            pos += kw.length;
            size_t lo = parseUint(input, pos);
            expectRangeDots(input, pos);
            size_t hi = parseUint(input, pos);
            expect(input, pos, ')');
            skipWS(input, pos);
            expect(input, pos, '[');

            assert(seq.partCount < MAX_PARTS, "Sequence part overflow");
            auto markerIdx = seq.partCount;
            seq.partCount++;                       // reserve the marker slot
            auto bodyStart = seq.partCount;
            fillSequence(input, pos, seq, owner);  // consumes through its own ']'
            auto bodyLen = seq.partCount - bodyStart;
            assert(bodyLen <= ubyte.max, "repeat body too long");
            seq.parts[markerIdx] = repeat(lo, hi, cast(ubyte) bodyLen);
            continue;
        }

        Part p = parsePart(input, pos, owner);
        assert(seq.partCount < MAX_PARTS, "Sequence part overflow");
        seq.parts[seq.partCount++] = p;
    }
    assert(0, "Unterminated sequence body");
}

// Parse a single part like letters(1..2), digits(1..3), literal("..."), any(max: N), oneof([...]).
Part parsePart(ref string input, ref size_t pos, ref Strop owner) {
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
        case "lower": {
            size_t lo = parseUint(input, pos);
            expectRangeDots(input, pos);
            size_t hi = parseUint(input, pos);
            p = lower(lo, hi);
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
        case "line": {
            // line(max: N)
            auto argKey = readWord(input, pos);
            assert(argKey == "max", "line expects max:");
            skipWS(input, pos);
            expect(input, pos, ':');
            skipWS(input, pos);
            size_t m = parseUint(input, pos);
            p = line(m);
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
            p = oneof(words[0 .. n], owner);
            break;
        }
        case "end": {
            p = end();
            break;
        }
        case "newline": {
            // pbt strings carry no escapes — readQuotedString returns the input
            // slice directly, so newline() means backslash-n. A
            // line-oriented grammar needs the real character, and a primitive
            // gives it without teaching the lexer to allocate during CTFE.
            p = newline();
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

unittest {
    // The message must name the flag it actually validated. "commit message"
    // was hardcoded for every strop regardless of what was being checked —
    // asserting the domain instead of observing it, the same defect class as
    // errors.d calling a ci-status row an "exec message".
    Strop s;
    s.flag = "--tag";
    s.sequenceCount = 1;
    s.sequences[0].partCount = 1;
    s.sequences[0].parts[0] = Part(PartKind.Digits, 1, 4);

    import matcher : contains;

    auto missing = stropDispatch(s, "git push");
    assert(missing.deny);
    assert(contains(missing.msg, "--tag"), "must name the flag it looked for");
    assert(!contains(missing.msg, "commit message"),
           "must not assert a domain it never checked");
    // A bare "not found" reads as a defect. It is policy: the value cannot be
    // validated when the flag is absent, and unvalidated is not accepted.
    assert(contains(missing.msg, "cannot be checked"),
           "must say why the flag is required, not just that it is missing");

    auto bad = stropDispatch(s, `git push --tag "vX"`);
    assert(bad.deny);
    assert(contains(bad.msg, "--tag"), "must name the flag");
    assert(contains(bad.msg, "vX"), "must quote the value it rejected");
    assert(!contains(bad.msg, "commit message"));
}

StropDispatchResult stropDispatch(const Strop s, string command) {
    StropDispatchResult res;
    auto ex = extractFlag(command, s.flag);
    if (!ex.ok) {
        res.deny = true;
        // "not found" alone reads as a defect in the control. It is policy:
        // the value lives in the command string and nowhere else, so a command
        // that does not pass the flag cannot be validated — and unvalidated is
        // not the same as allowed.
        appendMsg(res, "flag ");
        appendMsg(res, s.flag);
        appendMsg(res, " not found on the command — its value cannot be checked without it, and unchecked is not accepted");
        return res;
    }
    auto r = matchStrop(s, ex.value);
    if (!r.ok) {
        res.deny = true;
        appendMsg(res, "value for ");
        appendMsg(res, s.flag);
        appendMsg(res, " does not match the required shape: `");
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
