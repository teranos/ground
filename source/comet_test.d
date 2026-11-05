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
// 「[Opus 5.5] A node that keeps no comet for this engine's ABI, while one is held here,」
// 「[Opus 5.5] says why in its own words: the comet held here is the one every event」
// 「[Opus 5.5] refuses. With none held, the repository has no comet and nothing is said.」
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

    // 「[Opus 5.5] An answer larger than ground reads is said to be, not handed over as nothing.」
    Landing long_;
    notKept(long_, "abcd-nl/grove", true, "", true, "");
    assert(long_.what == Landed.failed);
    assert(indexOf(long_.why(), "the node's answer was larger than the ") >= 0, long_.why());

    // 「[Opus 5.5] A 404 whose answer did not arrive whole is said as the transfer that broke, not as what came.」
    Landing cut;
    notKept(cut, "abcd-nl/grove", true, `{"error":"no com`, false, "Transferred a partial file");
    assert(cut.what == Landed.failed);
    assert(indexOf(cut.why(), "did not arrive whole: Transferred a partial file") >= 0, cut.why());
    assert(indexOf(cut.why(), `{"error":"no com`) < 0, cut.why());
}

// "1. the 2nd"
// 「[Opus 5.5] The engine names the ground it was built from when it asks for its comet, so a node that keeps」
// 「[Opus 5.5] none of its ABI builds it from that ground. git describe's commit is the revision; a tag or a」
// 「[Opus 5.5] commit alone is itself; a comet's own engine names the ground it was built from after "comet".」
unittest {
    import comet : groundRevOf;
    assert(groundRevOf("v0.19.1-880-g23a58f7\n") == "23a58f7");
    assert(groundRevOf("v0.19.1\n") == "v0.19.1");
    assert(groundRevOf("23a58f7\n") == "23a58f7");
    assert(groundRevOf("comet a1ac2c0 sbvh-nl/grove@0123456 sbvh-nl/l@89abcde\n") == "a1ac2c0");
    assert(groundRevOf("") == "");
    assert(groundRevOf("\n") == "");
    assert(groundRevOf("a b\n") == "");
    assert(groundRevOf("v1&x=y\n") == "");
}

// 「[Opus 5.5] The ask for the digest carries that revision; with none, the ask is the digest alone.」
unittest {
    import comet : cometAskInto;
    import zbuf : ZBuf;
    ZBuf base;
    cometUrlInto(base, "https://n", "abcd-nl/grove");
    ZBuf want;
    want.put(base.slice());
    want.put("?digest&ground=23a58f7");
    ZBuf url;
    cometAskInto(url, "https://n", "abcd-nl/grove", "v0.19.1-880-g23a58f7\n", "");
    assert(url.slice() == want.slice(), url.slice());

    ZBuf bare;
    bare.put(base.slice());
    bare.put("?digest");
    cometAskInto(url, "https://n", "abcd-nl/grove", "", "");
    assert(url.slice() == bare.slice(), url.slice());

    // 「[Opus 5.5] The commit wind stamped beside the version is the one named: a tag that only looks like」
    // 「[Opus 5.5] describe's suffix, or one with a slash in it, is not read for a commit.」
    enum head = "0123456789abcdef0123456789abcdef01234567";
    ZBuf named;
    named.put(base.slice());
    named.put("?digest&ground=" ~ head);
    cometAskInto(url, "https://n", "abcd-nl/grove", "v1.0-gdeadbeef\n", head ~ "\n");
    assert(url.slice() == named.slice(), url.slice());
    cometAskInto(url, "https://n", "abcd-nl/grove", "release/v1.2\n", head ~ "\n");
    assert(url.slice() == named.slice(), url.slice());
    // 「[Opus 5.5] What is no whole commit is not one: the version is read instead.」
    cometAskInto(url, "https://n", "abcd-nl/grove", "v0.19.1-880-g23a58f7\n", "0123\n");
    assert(url.slice() == want.slice(), url.slice());
}
