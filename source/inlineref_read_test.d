module inlineref_read_test;

// The only piece that touches disk. It runs from the repo root under make
// test, so it reads real files of this project rather than a fixture.

import inlineref : readProjectFile;
import matcher : contains;

unittest {
    auto c = readProjectFile(".", "source/inlineref.d");
    assert(c !is null);
    assert(contains(c, "module inlineref;"));
}

unittest {
    // A file the project does not have reads as nothing, not as empty.
    assert(readProjectFile(".", "source/there-is-no-such-file.d") is null);
    assert(readProjectFile(".", "") is null);
}

unittest {
    // A path longer than the buffer that holds it is refused rather than cut,
    // because a truncated path names a different file.
    char[5000] long_ = 'a';
    assert(readProjectFile(".", long_[]) is null);
}
