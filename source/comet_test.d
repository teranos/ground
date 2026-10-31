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
    import sandview : SAND_ABI;
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
