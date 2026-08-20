module inlineref_lang_test;

// A fence without a language is plain text on screen. The extension is already
// the tag, so there is no table to keep and nothing to leave out of it.

import inlineref : fenceTag, inlineRefs;

unittest {
    assert(fenceTag("source/hooks.d") == "d");
    assert(fenceTag("src/execution.rs") == "rs");
    assert(fenceTag("engine.cpp") == "cpp");
    assert(fenceTag("src/collet.cr") == "cr");
    assert(fenceTag("hooks/hook.py") == "py");
    assert(fenceTag("app.tsx") == "tsx");
    assert(fenceTag("am.toml") == "toml");
}

unittest {
    // Nothing to tag with is a plain fence rather than a wrong one.
    assert(fenceTag("README") == "");
    assert(fenceTag("") == "");
    assert(fenceTag("a/b.c/noext") == "");
}

static immutable string[] files = ["source/hooks.d"];

extern (C) const(char)[] stubReadForTag(const(char)[] path) {
    if (path == "source/hooks.d") return "one\ntwo\nthree\nfour\n";
    return null;
}

unittest {
    // The tag is on the opening fence, where a renderer looks for it.
    auto r = inlineRefs("see hooks.d:2-3 for it", files, &stubReadForTag);
    assert(r.changed == 1);
    assert(r.text == "see \n```d\ntwo\nthree\n```\n for it");
}
