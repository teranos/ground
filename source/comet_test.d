module comet_test;

// "i want a coment per project essentially"

import comet : cometPathInto, handOff, digestOf, land, Landed;

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

// A repository's comet sits under ground's home, by owner and repo.
unittest {
    char[512] buf;
    auto p = cometPathInto("/home/x", "abcd-nl/grove", buf[]);
    assert(p == "/home/x/.local/share/ground/comets/abcd-nl/grove/ground", p);

    // No origin is no comet, never a path made of nothing.
    assert(cometPathInto("/home/x", "", buf[]).length == 0);
}

// The comet is given the hook's input whole, and its exit code is ground's.
unittest {
    import core.stdc.stdio : fopen, fputs, fclose;
    import exec : chmod;
    import core.sys.posix.stdlib : mkdtemp;

    char[64] dir = "/tmp/ground-comet-XXXXXX\0";
    assert(mkdtemp(dir.ptr) !is null);
    size_t n = 0;
    while (dir[n] != 0) n++;

    // A stand-in comet: it writes what it was given beside itself, and answers 3.
    char[128] script = 0;
    foreach (i, c; dir[0 .. n]) script[i] = c;
    foreach (i, c; "/comet") script[n + i] = c;
    auto f = fopen(script.ptr, "w");
    assert(f !is null);
    fputs("#!/bin/sh\ncat > \"$0.got\"\ntest \"$GROUND_COMET\" = 1 || exit 9\nexit 3\n", f);
    fclose(f);
    assert(chmod(script.ptr, 493) == 0); // 0755

    auto code = handOff(script[0 .. n + 6], `{"hook_event_name":"Stop"}`);
    assert(code == 3, "the comet's exit code is ground's, and the comet knows it is one");

    char[128] got = 0;
    foreach (i, c; script[0 .. n + 6]) got[i] = c;
    foreach (i, c; ".got") got[n + 6 + i] = c;
    auto g = fopen(got.ptr, "r");
    assert(g !is null);
    char[64] read = 0;
    import core.stdc.stdio : fread;
    auto len = fread(read.ptr, 1, read.length, g);
    fclose(g);
    assert(read[0 .. len] == `{"hook_event_name":"Stop"}`);
}
