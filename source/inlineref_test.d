module inlineref_test;

// Finding the references. What replaces them is a separate piece.

import inlineref : nextFileLineRef;

unittest {
    enum text = "see deferred.d:419 for it";
    auto r = nextFileLineRef(text, 0);
    assert(r.ok);
    assert(r.path == "deferred.d");
    assert(r.first == 419);
    assert(r.last == 419);
    assert(text[r.start .. r.end] == "deferred.d:419");
}

unittest {
    enum text = "source/ritual/run.d:211";
    auto r = nextFileLineRef(text, 0);
    assert(r.ok);
    assert(r.path == "source/ritual/run.d");
    assert(r.first == 211);
}

unittest {
    // A range names both ends, and the whole of it is what gets replaced.
    enum text = "control_handlers.d:919-927";
    auto r = nextFileLineRef(text, 0);
    assert(r.ok);
    assert(r.first == 919);
    assert(r.last == 927);
    assert(text[r.start .. r.end] == "control_handlers.d:919-927");
}

unittest {
    // A host and a port is not a file and a line.
    assert(!nextFileLineRef("https://api.github.com:443/x", 0).ok);
    assert(!nextFileLineRef("http://localhost:8770", 0).ok);
}

unittest {
    // Neither is a clock, nor a filename standing on its own.
    assert(!nextFileLineRef("at 12:34 today", 0).ok);
    assert(!nextFileLineRef("read README.md first", 0).ok);
    assert(!nextFileLineRef("", 0).ok);
}

unittest {
    // Every reference in a message, not the first one only.
    enum text = "both deferred.d:419 and ghruns.d:12 are wrong";
    auto a = nextFileLineRef(text, 0);
    assert(a.ok && a.first == 419);
    auto b = nextFileLineRef(text, a.end);
    assert(b.ok && b.path == "ghruns.d" && b.first == 12);
    assert(!nextFileLineRef(text, b.end).ok);
}

unittest {
    // Backticks are how these usually arrive, and they are not part of the path.
    enum text = "at `deferred.d:419` there";
    auto r = nextFileLineRef(text, 0);
    assert(r.ok);
    assert(r.path == "deferred.d");
    assert(text[r.start .. r.end] == "deferred.d:419");
}
