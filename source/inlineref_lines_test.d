module inlineref_lines_test;

// Taking the referenced lines out of a file's text. Lines are counted from one,
// the way every editor and every error message counts them.

import inlineref : sliceLines;

enum src = "alpha\nbravo\ncharlie\ndelta\necho\n";

unittest {
    assert(sliceLines(src, 1, 1) == "alpha");
    assert(sliceLines(src, 3, 3) == "charlie");
    assert(sliceLines(src, 5, 5) == "echo");
}

unittest {
    // A range comes back whole, with the newlines between them kept.
    assert(sliceLines(src, 2, 4) == "bravo\ncharlie\ndelta");
}

unittest {
    // Past the end names nothing rather than handing back what is there.
    assert(sliceLines(src, 6, 6) is null);
    assert(sliceLines(src, 4, 9) is null);
    assert(sliceLines(src, 0, 1) is null, "there is no line zero");
    assert(sliceLines(src, 3, 2) is null, "a range that runs backwards is not one");
    assert(sliceLines("", 1, 1) is null);
}

unittest {
    // A file whose last line has no newline after it still has that line.
    enum noTrailer = "one\ntwo";
    assert(sliceLines(noTrailer, 2, 2) == "two");
    assert(sliceLines(noTrailer, 1, 2) == "one\ntwo");
}
