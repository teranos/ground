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
    if (local is null && comet is null) return r;
    holdSand(layer(&builtinSand, local, comet));
    if (r.what != SandHeld.refused) r.what = SandHeld.landed;
    return r;
}

// The Sand the library at path hands over when its ABI is the engine's, else null and r says why.
private const(Sand)* openSand(const(char)* path, ref SandLoad r) {
    import core.sys.posix.dlfcn : dlopen, dlsym, dlerror, RTLD_NOW, RTLD_LOCAL;
    import core.sys.posix.unistd : access, F_OK;
    if (access(path, F_OK) != 0) return null;
    auto lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (lib is null) { refuse(r, "the sand did not load: ", dlerror()); return null; }
    alias SandFn = extern (C) const(Sand)* function();
    auto fn = cast(SandFn) dlsym(lib, "ground_sand");
    if (fn is null) { refuse(r, "the sand hands over nothing: ", dlerror()); return null; }
    auto s = fn();
    if (s is null) { refuse(r, "the sand handed over null", null); return null; }
    if (s.abi != SAND_ABI) {
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
