module sand.load;

// "A comet held for the harness is checked there."

// A landed sand is a library that hands over its Sand through ground_sand. The engine
// holds it when its ABI is the engine's; otherwise the built-in sand, and why.

import zbuf : ZBuf;
import sand.view : Sand, SAND_ABI;

enum SandHeld {
    builtin,  // no sand landed at the path
    landed,   // the landed sand is the one held
    refused,  // why() says; the built-in sand is held
}

struct SandLoad {
    SandHeld what;
    ZBuf said;
    const(char)[] why() return { return said.slice(); }
}

// "i want FLOOR+LOCALSAND+COMET"
// The floor, this machine's own sand (make install's, under home) and origin's comet, held together.
// A layer that is absent is not held; one that is refused says why, and the others still stand.
SandLoad holdLanded(const(char)[] home, const(char)[] origin) {
    import comet : cometPathInto, localSandPathInto;
    import controls : holdSand;
    import sand.layered : layer;
    import sand.builtin : builtinSand;
    __gshared char[1024] localBuf = 0;
    __gshared char[1024] cometBuf = 0;

    SandLoad r;
    holdSand(null);
    const(Sand)* local = null;
    const(Sand)* comet = null;
    if (localSandPathInto(home, localBuf[]).length > 0) local = openSand(localBuf.ptr, r);
    if (cometPathInto(home, origin, cometBuf[]).length > 0) comet = openSand(cometBuf.ptr, r);
    if (r.what == SandHeld.refused) {
        __gshared ZBuf held;
        held.reset();
        held.put(". held: the floor");
        if (local !is null) { held.put(" and the local sand at "); held.put(localBuf[0 .. lengthOf(localBuf.ptr)]); }
        if (comet !is null) { held.put(" and the comet at "); held.put(cometBuf[0 .. lengthOf(cometBuf.ptr)]); }
        endWithHeld(r.said, held.slice());
    }
    if (local is null && comet is null) return r;
    holdSand(layer(&builtinSand, local, comet));
    if (r.what != SandHeld.refused) r.what = SandHeld.landed;
    return r;
}

// 「[Opus 5.5] The room a refusal has: the hook says it as "sandload: <it>" in a 4096-byte result, and that in」
// 「[Opus 5.5] a 4096-byte exec-result row with the row's own words around it (errors.d formatResult,」
// 「[Opus 5.5] immediate.d writeExecResult).」
enum SAID_ROOM = 3584;

// 「[Opus 5.5] What is held ends a refusal whatever the reasons before it ran to: they are cut to make room for」
// 「[Opus 5.5] it within SAID_ROOM, and say they are.」
void endWithHeld(ref ZBuf said, const(char)[] held) {
    enum cut = " [cut: the reasons ran past what ground holds]";
    if (said.len + held.length > SAID_ROOM) {
        said.len = SAID_ROOM - held.length - cut.length;
        said.data[said.len] = 0;
        said.put(cut);
    }
    said.put(held);
}

private size_t lengthOf(const(char)* s) {
    size_t n = 0;
    while (s[n] != 0) n++;
    return n;
}

// "ritual needs to work for us always"
// 「[Opus 5.5] What a process holds on its first read of a control (controls.d): the same」
// 「[Opus 5.5] layers the hook holds, for the tree it stands in. Refused is said to stderr.」
void holdLandedHere() {
    import core.stdc.stdlib : getenv;
    import core.stdc.stdio : stderr, fprintf;
    import core.sys.posix.unistd : getcwd;
    import git : originOf;
    __gshared char[4096] cwdBuf = 0;
    auto home = getenv("HOME");
    if (home is null || getcwd(cwdBuf.ptr, cwdBuf.length) is null) return;
    size_t hl = 0;
    while (home[hl] != 0) hl++;
    size_t cl = 0;
    while (cwdBuf[cl] != 0) cl++;
    __gshared SandLoad held;
    held = holdLanded(home[0 .. hl], originOf(cwdBuf[0 .. cl]));
    if (held.what == SandHeld.refused) {
        auto why = held.why();
        fprintf(stderr, "ground: %.*s\n", cast(int) why.length, why.ptr);
    }
}

// The Sand the library at path hands over when its ABI is the engine's, else null and r says why.
// 「[Opus 5.5] Each sand refused is its own reason, after the one before it, and names its file.」
private const(Sand)* openSand(const(char)* path, ref SandLoad r) {
    import core.sys.posix.dlfcn : dlopen, dlsym, dlerror, RTLD_NOW, RTLD_LOCAL;
    import core.sys.posix.unistd : access, F_OK;
    if (access(path, F_OK) != 0) return null;
    void about() {
        if (r.what == SandHeld.refused) r.said.put("; ");
        r.said.put(path[0 .. lengthOf(path)]);
        r.said.put(": ");
    }
    auto lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (lib is null) { about(); refuse(r, "the sand did not load: ", dlerror()); return null; }
    alias SandFn = extern (C) const(Sand)* function();
    auto fn = cast(SandFn) dlsym(lib, "ground_sand");
    if (fn is null) { about(); refuse(r, "the sand hands over nothing: ", dlerror()); return null; }
    auto s = fn();
    if (s is null) { about(); refuse(r, "the sand handed over null", null); return null; }
    if (s.abi != SAND_ABI) {
        about();
        r.what = SandHeld.refused;
        r.said.put("the sand was built for engine ABI ");
        r.said.putUint(s.abi);
        r.said.put(", and this engine is ABI ");
        r.said.putUint(SAND_ABI);
        return null;
    }
    return s;
}

// The library stays open for the life of the process: the engine reads its data until exit.
SandLoad loadSand(const(char)* path) {
    import core.sys.posix.dlfcn : dlopen, dlsym, dlerror, RTLD_NOW, RTLD_LOCAL;
    import core.sys.posix.unistd : access, F_OK;
    import controls : holdSand;

    SandLoad r;
    holdSand(null);
    if (access(path, F_OK) != 0) return r;

    auto lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (lib is null) return refuse(r, "the sand did not load: ", dlerror());

    alias SandFn = extern (C) const(Sand)* function();
    auto fn = cast(SandFn) dlsym(lib, "ground_sand");
    if (fn is null) return refuse(r, "the sand hands over nothing: ", dlerror());
    return acceptSand(fn());
}

// The sand is held when it was built for this engine's layout.
SandLoad acceptSand(const(Sand)* s) {
    import controls : holdSand;

    SandLoad r;
    holdSand(null);
    if (s is null) return refuse(r, "the sand handed over null", null);
    if (s.abi != SAND_ABI) {
        r.what = SandHeld.refused;
        r.said.put("the sand was built for engine ABI ");
        r.said.putUint(s.abi);
        r.said.put(", and this engine is ABI ");
        r.said.putUint(SAND_ABI);
        return r;
    }
    holdSand(s);
    r.what = SandHeld.landed;
    return r;
}

private SandLoad refuse(ref SandLoad r, const(char)[] what, const(char)* loader) {
    r.what = SandHeld.refused;
    r.said.put(what);
    if (loader !is null) {
        size_t n = 0;
        while (loader[n] != 0) n++;
        r.said.put(loader[0 .. n]);
    }
    return r;
}
