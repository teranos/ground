module provenance;

// A quoted span is a claim about who said something. This module finds the
// claims; checking them against what the user typed is the caller's job.

struct Span {
    bool ok;
    size_t start;   // first char inside the quotes
    size_t end;     // one past the last char inside the quotes
}

// Find the next quoted span at or after `from`. An unpaired quote is not a
// span: it closes nothing, so it claims nothing.
Span nextQuotedSpan(const(char)[] s, size_t from) {
    size_t i = from;
    while (i < s.length && s[i] != '"') i++;
    if (i >= s.length) return Span(false, 0, 0);

    size_t start = i + 1;
    size_t j = start;
    while (j < s.length && s[j] != '"') j++;
    if (j >= s.length) return Span(false, 0, 0);

    return Span(true, start, j);
}

// Index of the first entry that sits earlier in the record than the one before
// it, or -1. Equal is not out of order: one prompt can say two things.
ptrdiff_t firstOutOfOrder(const(long)[] said) {
    foreach (i; 1 .. said.length)
        if (said[i] < said[i - 1]) return cast(ptrdiff_t) i;
    return -1;
}

unittest {
    // Spans carry the position of the prompt that said them. Document order
    // has to agree with said order.
    long[3] rising = [1, 2, 3];
    assert(firstOutOfOrder(rising[]) == -1);

    long[2] swapped = [3, 1];
    assert(firstOutOfOrder(swapped[]) == 1);

    // Names the first span that breaks the run, not the last.
    long[4] late = [1, 5, 2, 9];
    assert(firstOutOfOrder(late[]) == 2);

    // The same prompt said twice over is not out of order.
    long[3] equal = [4, 4, 4];
    assert(firstOutOfOrder(equal[]) == -1);

    long[0] none;
    assert(firstOutOfOrder(none[]) == -1);
}

// Attestation attributes are stored as JSON, where a backslash and a quote mark
// each take two characters there and one here. A span compared raw against that
// text cannot match if it carries either, so a sourced quote reads as unsourced.
ptrdiff_t jsonEscapeInto(const(char)[] s, char[] dst) {
    size_t o = 0;
    foreach (c; s) {
        if (c == '\\' || c == '"') {
            if (o + 2 > dst.length) return -1;
            dst[o++] = '\\';
            dst[o++] = c;
        } else {
            if (o + 1 > dst.length) return -1;
            dst[o++] = c;
        }
    }
    return cast(ptrdiff_t) o;
}

unittest {
    char[32] buf;

    // Ordinary text is itself.
    auto n = jsonEscapeInto("plain", buf[]);
    assert(n == 5 && buf[0 .. 5] == "plain");

    // The two characters JSON spends twice.
    n = jsonEscapeInto(`a\|b`, buf[]);
    assert(n == 5 && buf[0 .. 5] == `a\\|b`);

    n = jsonEscapeInto(`say "hi"`, buf[]);
    assert(n == 10 && buf[0 .. 10] == `say \"hi\"`);

    // Nothing to say is said in nothing.
    assert(jsonEscapeInto("", buf[]) == 0);

    // A span too long to encode is not truncated into a different span.
    char[3] tiny;
    assert(jsonEscapeInto("abcd", tiny[]) == -1);
    assert(jsonEscapeInto(`\\`, tiny[]) == -1);
}

private bool isWs(char c) {
    return c == ' ' || c == '\t' || c == '\r';
}

// True when the span's own two lines carry nothing but the quote. A comment
// marker is where the line begins, so it is the one prefix that is not company.
bool standsAlone(const(char)[] s, Span sp) {
    size_t open = sp.start - 1;
    size_t lineStart = open;
    while (lineStart > 0 && s[lineStart - 1] != '\n') lineStart--;

    size_t b = lineStart;
    size_t e = open;
    while (b < e && isWs(s[b])) b++;
    while (e > b && isWs(s[e - 1])) e--;
    auto prefix = s[b .. e];
    if (prefix.length != 0 && prefix != "#" && prefix != "//") return false;

    size_t j = sp.end + 1;
    while (j < s.length && s[j] != '\n') {
        if (!isWs(s[j])) return false;
        j++;
    }
    return true;
}

unittest {
    // A quote owns its line. Whitespace around it is not company.
    assert(standsAlone(`"a"`, Span(true, 1, 2)));
    assert(standsAlone(`   "a"   `, Span(true, 4, 5)));

    // Commentary on either side is what this refuses.
    assert(!standsAlone(`x "a"`, Span(true, 3, 4)));
    assert(!standsAlone(`"a" x`, Span(true, 1, 2)));

    // In a comment the line begins after the marker.
    assert(standsAlone(`# "a"`, Span(true, 3, 4)));
    assert(standsAlone(`// "a"`, Span(true, 4, 5)));
    assert(!standsAlone(`# x "a"`, Span(true, 5, 6)));

    // The span crosses newlines; only its two edges are the line question.
    assert(standsAlone("\"a\nb\"", Span(true, 1, 4)));
    assert(!standsAlone("pre \"a\nb\"", Span(true, 5, 8)));
    assert(!standsAlone("\"a\nb\" post", Span(true, 1, 4)));
}

unittest {
    // Nothing to claim.
    assert(!nextQuotedSpan("no quotes here", 0).ok);

    // One span, and the offsets are the interior, not the quotes.
    auto one = nextQuotedSpan(`say "hello" now`, 0);
    assert(one.ok);
    assert(one.start == 5);
    assert(one.end == 10);

    // Walking continues past the closing quote.
    auto two = nextQuotedSpan(`"a" and "b"`, 0);
    assert(two.ok && two.start == 1 && two.end == 2);
    auto three = nextQuotedSpan(`"a" and "b"`, two.end + 1);
    assert(three.ok && three.start == 9 && three.end == 10);

    // A span crosses newlines, because a quote is free to.
    auto multi = nextQuotedSpan("\"a\nb\" tail", 0);
    assert(multi.ok && multi.start == 1 && multi.end == 4);

    // An unpaired quote claims nothing and is out of scope.
    assert(!nextQuotedSpan(`"never closed`, 0).ok);

    // An empty span is still a claim, and it is one nothing can source.
    auto empty = nextQuotedSpan(`""`, 0);
    assert(empty.ok && empty.start == 1 && empty.end == 1);
}
