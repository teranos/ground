module comet_test;

// "i want a coment per project essentially"

import comet : cometPathInto, cometUrlInto, digestOf, land, Landed, PLATFORM, SAND_FILE;

// The digest is read from the node's answer, and nothing that is not 64 hex characters is one.
unittest {
    enum d = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    assert(digestOf(`{"digest":"` ~ d ~ `"}`) == d);
    assert(digestOf(`{"digest":"nope"}`).length == 0);
    assert(digestOf(`{"error":"no comet"}`).length == 0);
    assert(digestOf(`{"digest":"` ~ d[0 .. 63] ~ `X"}`).length == 0);
}

// A node that does not answer is a landing that failed, and says why; no origin asks nothing.
unittest {
    auto down = land("http://127.0.0.1:1", "t", "/tmp", "abcd-nl/grove");
    assert(down.what == Landed.failed);
    assert(down.why().length > 0);
    assert(land("http://127.0.0.1:1", "t", "/tmp", "").what == Landed.none);
}

// A repository's comet sits under ground's home, by owner and repo: the sand, as make sand names it.
unittest {
    char[512] buf;
    auto p = cometPathInto("/home/x", "abcd-nl/grove", buf[]);
    assert(p == "/home/x/.local/share/ground/comets/abcd-nl/grove/" ~ SAND_FILE, p);

    // No origin is no comet, never a path made of nothing.
    assert(cometPathInto("/home/x", "", buf[]).length == 0);
}

// The node is asked for the sand of this platform and of this engine's ABI.
unittest {
    import sand.view : SAND_ABI;
    import zbuf : ZBuf;
    ZBuf want;
    want.put("https://n/comet/abcd-nl/grove/");
    want.put(PLATFORM);
    want.put("/");
    want.putUint(SAND_ABI);
    ZBuf url;
    cometUrlInto(url, "https://n", "abcd-nl/grove");
    assert(url.slice() == want.slice(), url.slice());
}

// "thats problematic seeing how sand chamges are normal"
// A node that keeps no comet for this engine's ABI, while one is held here,
// says why in its own words: the comet held here is the one every event
// refuses. With none held, the repository has no comet and nothing is said.
unittest {
    import comet : notKept, Landing;
    import sand.view : SAND_ABI;
    import zbuf : ZBuf;
    import matcher : indexOf;
    enum node = `{"error":"no comet of abcd-nl/grove is kept: abcd-nl/grove/aarch64-darwin is kept for engine ABI 2, built from ground's main"}`;

    Landing held;
    notKept(held, "abcd-nl/grove", true, node, false, "");
    assert(held.what == Landed.failed);
    ZBuf abi;
    abi.putUint(SAND_ABI);
    assert(indexOf(held.why(), "abcd-nl/grove") >= 0, held.why());
    assert(indexOf(held.why(), abi.slice()) >= 0, held.why());
    assert(indexOf(held.why(), node) >= 0, held.why());

    Landing none;
    notKept(none, "abcd-nl/grove", false, node, false, "");
    assert(none.what == Landed.none);
    assert(none.why().length == 0);

    // An answer larger than ground reads is said to be, not handed over as nothing.
    Landing long_;
    notKept(long_, "abcd-nl/grove", true, "", true, "");
    assert(long_.what == Landed.failed);
    assert(indexOf(long_.why(), "the node's answer was larger than the ") >= 0, long_.why());

    // A 404 whose answer did not arrive whole is said as the transfer that broke, not as what came.
    Landing cut;
    notKept(cut, "abcd-nl/grove", true, `{"error":"no com`, false, "Transferred a partial file");
    assert(cut.what == Landed.failed);
    assert(indexOf(cut.why(), "did not arrive whole: Transferred a partial file") >= 0, cut.why());
    assert(indexOf(cut.why(), `{"error":"no com`) < 0, cut.why());
}
