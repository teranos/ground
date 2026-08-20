module inlineref_resolve_test;

// Turning what was written into a path that exists. wind already walked every
// declared project and put its files in the binary, so this is a lookup.

import inlineref : resolvePath;

static immutable string[] files = [
    "source/deferred.d",
    "source/ghruns.d",
    "source/ritual/run.d",
    "README.md",
];

unittest {
    assert(resolvePath("deferred.d", files) == "source/deferred.d");
    assert(resolvePath("ghruns.d", files) == "source/ghruns.d");
    assert(resolvePath("README.md", files) == "README.md");
}

unittest {
    // Written with as much of the path as the writer felt like giving.
    assert(resolvePath("source/deferred.d", files) == "source/deferred.d");
    assert(resolvePath("ritual/run.d", files) == "source/ritual/run.d");
}

unittest {
    // A name that is only a tail of another name is not that file.
    static immutable string[] tricky = ["source/xdeferred.d"];
    assert(resolvePath("deferred.d", tricky) is null);
}

unittest {
    // Two files of the same name resolve to neither. Inlining the wrong file
    // is worse than leaving the address where it was.
    static immutable string[] twins = ["a/run.d", "b/run.d"];
    assert(resolvePath("run.d", twins) is null);

    // Enough path to tell them apart resolves again.
    assert(resolvePath("a/run.d", twins) == "a/run.d");
}

unittest {
    assert(resolvePath("nothing.d", files) is null);
    assert(resolvePath("", files) is null);
    assert(resolvePath("deferred.d", []) is null);
}
