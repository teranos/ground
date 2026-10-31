module sandload_test;

// "A comet held for the harness is checked there."

import sandload : loadSand, acceptSand, holdLanded, SandHeld;
import sandview : Sand, SAND_ABI;
import controls : sand, holdSand, allScopes;
import builtin_sand : builtinSand;

version (OSX) enum BUILT = "build/libground_sand.dylib\0";
else enum BUILT = "build/libground_sand.so\0";

// make sand's library, loaded, answers what the built-in sand answers.
unittest {
    scope (exit) holdSand(null);
    auto r = loadSand(BUILT.ptr);
    assert(r.what == SandHeld.landed, r.why());
    assert(sand() !is &builtinSand);
    assert(sand().abi == SAND_ABI);
    assert(allScopes.length == builtinSand.preToolUse.length);
    assert(sand().parsed.ritualCount == builtinSand.parsed.ritualCount);
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

// A sand built for another engine is refused, naming both ABIs.
unittest {
    Sand other = builtinSand;
    other.abi = SAND_ABI ^ 1;
    auto r = acceptSand(&other);
    assert(r.what == SandHeld.refused);
    assert(r.why().length > 0);
    assert(sand() is &builtinSand);
}
