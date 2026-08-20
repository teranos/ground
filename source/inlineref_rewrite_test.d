module inlineref_rewrite_test;

// The rewrite itself. Reading a file is passed in, so what replaces an address
// can be tested without one.

import inlineref : inlineRefs, Rewrite;

static immutable string[] files = ["source/hooks.d", "source/deferred.d"];

extern (C) const(char)[] stubRead(const(char)[] path) {
    if (path == "source/hooks.d") return "one\ntwo\nthree\nfour\n";
    if (path == "source/deferred.d") return "alpha\nbravo\n";
    return null;
}

unittest {
    // One line arrives in backticks, because it belongs in the sentence it
    // was written into.
    auto r = inlineRefs("look at hooks.d:2 now", files, &stubRead);
    assert(r.changed == 1);
    assert(r.text == "look at `two` now");
}

unittest {
    // A range cannot sit inside a sentence, so it breaks out into a block.
    auto r = inlineRefs("see hooks.d:2-3 for it", files, &stubRead);
    assert(r.changed == 1);
    assert(r.text == "see \n```d\ntwo\nthree\n```\n for it");
}

unittest {
    // Every reference in the message.
    auto r = inlineRefs("hooks.d:1 and deferred.d:2", files, &stubRead);
    assert(r.changed == 2);
    assert(r.text == "`one` and `bravo`");
}

unittest {
    // Nothing to resolve, nothing to read, or a line past the end: the address
    // stays exactly as written and nothing is claimed to have happened.
    auto a = inlineRefs("nowhere.d:2 stays", files, &stubRead);
    assert(a.changed == 0);
    assert(a.text == "nowhere.d:2 stays");

    auto b = inlineRefs("hooks.d:99 stays", files, &stubRead);
    assert(b.changed == 0);
    assert(b.text == "hooks.d:99 stays");
}

unittest {
    // A message with no reference in it comes back untouched.
    auto r = inlineRefs("nothing to do here", files, &stubRead);
    assert(r.changed == 0);
    assert(r.text == "nothing to do here");
    assert(inlineRefs("", files, &stubRead).changed == 0);
}
