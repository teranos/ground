module sandload_test;

// "A comet held for the harness is checked there."

import sand.load : loadSand, acceptSand, holdLanded, SandHeld;
import sand.view : Sand, SAND_ABI;
import controls : sand, holdSand, allScopes;
import sand.builtin : builtinSand;

version (OSX) enum BUILT = "build/libground_sand.dylib\0";
else enum BUILT = "build/libground_sand.so\0";

// make sand's library, loaded, answers with the user's controls on top of the floor the engine holds:
// wind folds controls/ first, then controls/local and each project's, so the floor is where a sand starts.
unittest {
    scope (exit) holdSand(null);
    auto r = loadSand(BUILT.ptr);
    assert(r.what == SandHeld.landed, r.why());
    assert(sand() !is &builtinSand);
    assert(sand().abi == SAND_ABI);
    assert(allScopes.length >= builtinSand.preToolUse.length);
    assert(sand().parsed.ritualCount >= builtinSand.parsed.ritualCount);
}

// make sand says beside the library which engine ABI it was built for, as a node keeps it.
unittest {
    import core.stdc.stdio : fopen, fread, fclose;
    import zbuf : ZBuf;
    auto f = fopen("build/libground_sand.abi", "rb");
    assert(f !is null, "make sand writes build/libground_sand.abi");
    char[32] got = 0;
    auto n = fread(got.ptr, 1, got.length, f);
    fclose(f);
    ZBuf want;
    want.putUint(SAND_ABI);
    want.put("\n");
    assert(got[0 .. n] == want.slice(), got[0 .. n]);
}

// No sand landed is the built-in sand, and nothing to say.
unittest {
    auto r = loadSand("build/no-such-sand\0".ptr);
    assert(r.what == SandHeld.builtin);
    assert(r.why().length == 0);
    assert(sand() is &builtinSand);
}

// A file that is no library is refused, saying what the loader said.
unittest {
    auto r = loadSand("Makefile\0".ptr);
    assert(r.what == SandHeld.refused);
    assert(r.why().length > 0);
    assert(sand() is &builtinSand);
}

// What landed for a repository is the sand held for it; a repository with none holds the built-in sand.
unittest {
    import core.sys.posix.stdlib : mkdtemp;
    import core.stdc.stdio : fopen, fread, fwrite, fclose;
    import errors : mkdir;
    import comet : SAND_FILE;
    scope (exit) holdSand(null);

    char[64] home = "/tmp/ground-sand-XXXXXX\0";
    assert(mkdtemp(home.ptr) !is null);
    size_t n = 0;
    while (home[n] != 0) n++;
    char[256] dir = 0;
    size_t d = 0;
    void add(const(char)[] s) { foreach (c; s) dir[d++] = c; dir[d] = 0; }
    add(home[0 .. n]);
    foreach (part; ["/.local", "/share", "/ground", "/comets", "/abcd-nl", "/grove"]) {
        add(part);
        cast(void) mkdir(dir.ptr, 493);
    }
    add("/");
    add(SAND_FILE);

    auto src = fopen(BUILT.ptr, "rb");
    auto dst = fopen(dir.ptr, "wb");
    assert(src !is null && dst !is null);
    __gshared ubyte[65536] chunk;
    while (true) {
        auto got = fread(chunk.ptr, 1, chunk.length, src);
        if (got == 0) break;
        fwrite(chunk.ptr, 1, got, dst);
    }
    fclose(src);
    fclose(dst);

    auto r = holdLanded(home[0 .. n], "abcd-nl/grove");
    assert(r.what == SandHeld.landed, r.why());
    assert(sand() !is &builtinSand);

    auto none = holdLanded(home[0 .. n], "abcd-nl/elsewhere");
    assert(none.what == SandHeld.builtin);
    assert(sand() is &builtinSand);
}

// "and have settings local to my setup"
// "you dont have to have the comets to use ground"
// With no comet, the sand this machine built for itself is held, wherever the session stands.
unittest {
    import core.sys.posix.stdlib : mkdtemp;
    import core.stdc.stdio : fopen, fread, fwrite, fclose;
    import errors : mkdir;
    import comet : SAND_FILE;
    scope (exit) holdSand(null);

    char[64] home = "/tmp/ground-local-XXXXXX\0";
    assert(mkdtemp(home.ptr) !is null);
    size_t n = 0;
    while (home[n] != 0) n++;
    char[256] dir = 0;
    size_t d = 0;
    void add(const(char)[] s) { foreach (c; s) dir[d++] = c; dir[d] = 0; }
    add(home[0 .. n]);
    foreach (part; ["/.local", "/share", "/ground", "/sand"]) {
        add(part);
        cast(void) mkdir(dir.ptr, 493);
    }
    add("/");
    add(SAND_FILE);

    auto src = fopen(BUILT.ptr, "rb");
    auto dst = fopen(dir.ptr, "wb");
    assert(src !is null && dst !is null);
    __gshared ubyte[65536] piece;
    while (true) {
        auto got = fread(piece.ptr, 1, piece.length, src);
        if (got == 0) break;
        fwrite(piece.ptr, 1, got, dst);
    }
    fclose(src);
    fclose(dst);

    auto r = holdLanded(home[0 .. n], "abcd-nl/no-comet");
    assert(r.what == SandHeld.landed, r.why());
    assert(sand() !is &builtinSand);

    auto bare = holdLanded(home[0 .. n], "");
    assert(bare.what == SandHeld.landed, bare.why());
    assert(sand() !is &builtinSand);
}

// A sand built for another engine is refused, naming both ABIs.
unittest {
    Sand other = builtinSand;
    other.abi = SAND_ABI ^ 1;
    auto r = acceptSand(&other);
    assert(r.what == SandHeld.refused);
    assert(r.why().length > 0);
    assert(sand() is &builtinSand);
}

// Two sands refused are two reasons, each naming the file it is about, and
// what is held in their place: one ran into the other, and neither said which.
unittest {
    import core.sys.posix.stdlib : mkdtemp;
    import core.stdc.stdio : fopen, fputs, fclose;
    import errors : mkdir;
    import comet : SAND_FILE, cometPathInto, localSandPathInto;
    import matcher : indexOf;
    scope (exit) holdSand(null);

    char[64] home = "/tmp/ground-refused-XXXXXX\0";
    assert(mkdtemp(home.ptr) !is null);
    size_t n = 0;
    while (home[n] != 0) n++;
    void dirs(const(char)[] path) {
        char[512] d = 0;
        foreach (i, c; path) {
            if (i > n && c == '/') cast(void) mkdir(d.ptr, 493);
            d[i] = c;
        }
    }
    void notALibrary(const(char)[] path) {
        dirs(path);
        auto f = fopen(path.ptr, "wb");
        assert(f !is null);
        fputs("no library", f);
        fclose(f);
    }
    char[512] localBuf = 0, cometBuf = 0;
    auto local = localSandPathInto(home[0 .. n], localBuf[]);
    auto comet = cometPathInto(home[0 .. n], "abcd-nl/both", cometBuf[]);
    notALibrary(local);
    notALibrary(comet);

    auto r = holdLanded(home[0 .. n], "abcd-nl/both");
    assert(r.what == SandHeld.refused);
    auto why = r.why();
    auto atLocal = indexOf(why, local), atComet = indexOf(why, comet);
    assert(atLocal >= 0 && atComet > atLocal, why);
    assert(indexOf(why[atLocal .. atComet], "; ") >= 0, why);
    assert(indexOf(why, "held: the floor") >= 0, why);
    assert(sand() is &builtinSand);
}

// A comet refused beside a local sand that stands says the local sand is held.
unittest {
    import core.sys.posix.stdlib : mkdtemp;
    import core.stdc.stdio : fopen, fread, fwrite, fputs, fclose;
    import errors : mkdir;
    import comet : cometPathInto, localSandPathInto;
    import matcher : indexOf;
    scope (exit) holdSand(null);

    char[64] home = "/tmp/ground-refused-XXXXXX\0";
    assert(mkdtemp(home.ptr) !is null);
    size_t n = 0;
    while (home[n] != 0) n++;
    void dirs(const(char)[] path) {
        char[512] d = 0;
        foreach (i, c; path) {
            if (i > n && c == '/') cast(void) mkdir(d.ptr, 493);
            d[i] = c;
        }
    }
    char[512] localBuf = 0, cometBuf = 0;
    auto local = localSandPathInto(home[0 .. n], localBuf[]);
    auto comet = cometPathInto(home[0 .. n], "abcd-nl/stale", cometBuf[]);
    dirs(local);
    auto src = fopen(BUILT.ptr, "rb");
    auto dst = fopen(local.ptr, "wb");
    assert(src !is null && dst !is null);
    __gshared ubyte[65536] piece;
    while (true) {
        auto got = fread(piece.ptr, 1, piece.length, src);
        if (got == 0) break;
        fwrite(piece.ptr, 1, got, dst);
    }
    fclose(src);
    fclose(dst);
    dirs(comet);
    auto f = fopen(comet.ptr, "wb");
    assert(f !is null);
    fputs("no library", f);
    fclose(f);

    auto r = holdLanded(home[0 .. n], "abcd-nl/stale");
    assert(r.what == SandHeld.refused);
    auto why = r.why();
    assert(indexOf(why, comet) >= 0, why);
    assert(indexOf(why, "held: the floor and the local sand at ") >= 0, why);
    assert(indexOf(why, local) > indexOf(why, "held: "), why);
    assert(sand() !is &builtinSand);
}

// Reasons longer than what ground holds are cut, and say they are: what is held still ends
// the message. Two sands under a long home, each refused with the loader's text naming its
// path again and again, ran past the buffer and lost "held".
unittest {
    import core.sys.posix.stdlib : mkdtemp;
    import core.stdc.stdio : fopen, fputs, fclose;
    import errors : mkdir;
    import comet : cometPathInto, localSandPathInto;
    import matcher : indexOf;
    scope (exit) holdSand(null);

    char[1024] home = 0;
    enum base = "/tmp/ground-long-XXXXXX";
    home[0 .. base.length] = base;
    assert(mkdtemp(home.ptr) !is null);
    size_t n = base.length;
    foreach (_; 0 .. 3) {
        home[n++] = '/';
        foreach (k; 0 .. 200) home[n++] = 'a';
        home[n] = 0;
        assert(mkdir(home.ptr, 493) == 0);
    }
    void dirs(const(char)[] path) {
        char[1024] d = 0;
        foreach (i, c; path) {
            if (i > n && c == '/') cast(void) mkdir(d.ptr, 493);
            d[i] = c;
        }
    }
    void notALibrary(const(char)[] path) {
        dirs(path);
        auto f = fopen(path.ptr, "wb");
        assert(f !is null);
        fputs("no library", f);
        fclose(f);
    }
    char[1024] localBuf = 0, cometBuf = 0;
    notALibrary(localSandPathInto(home[0 .. n], localBuf[]));
    notALibrary(cometPathInto(home[0 .. n], "abcd-nl/long", cometBuf[]));

    auto r = holdLanded(home[0 .. n], "abcd-nl/long");
    assert(r.what == SandHeld.refused);
    auto why = r.why();
    enum held = ". held: the floor";
    assert(why.length >= held.length && why[$ - held.length .. $] == held, why[why.length > 200 ? $ - 200 : 0 .. $]);
    assert(indexOf(why, "[cut: ") >= 0, why[why.length > 200 ? $ - 200 : 0 .. $]);
}
