module sandload;

// "A comet held for the harness is checked there."

// A landed sand is a library that hands over its Sand through ground_sand. The engine
// holds it when its ABI is the engine's; otherwise the built-in sand, and why.

import zbuf : ZBuf;
import sandview : Sand, SAND_ABI;

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

// The sand landed for origin under home, held; none landed is the built-in sand.
SandLoad holdLanded(const(char)[] home, const(char)[] origin) {
    import comet : cometPathInto;
    import controls : holdSand;
    __gshared char[1024] buf = 0;
    if (cometPathInto(home, origin, buf[]).length == 0) {
        holdSand(null);
        return SandLoad.init;
    }
    return loadSand(buf.ptr);
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
