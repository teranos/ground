module forkguard;

// A fork() with a connection to ground.db open hands the child the parent's
// lock bookkeeping and none of its kernel locks; the child's own connection
// then writes unlocked. That tore the store four times in 2026-09. The kernel
// knows whether this process holds the file open, so the guard asks it and
// no counter has to be kept right across 180 close sites.

import core.sys.posix.sys.stat : stat_t, stat, fstat;
import core.sys.posix.unistd : fork;

extern (C) int getdtablesize();

// Does any descriptor of this process point at the file at path?
bool fileOpenInProcess(const(char)* path) {
    stat_t want;
    if (path is null || stat(path, &want) != 0) return false;
    auto n = getdtablesize();
    foreach (fd; 0 .. n) {
        stat_t st;
        if (fstat(fd, &st) != 0) continue;
        if (st.st_dev == want.st_dev && st.st_ino == want.st_ino) return true;
    }
    return false;
}

enum REFUSED = -2;

// fork(), or REFUSED without forking when the store is open in this process.
// The refusal is a GroundError with the site's name, so it lands where the
// fork would have been counted on. fork()'s own -1 comes through as is.
int forkClean(const(char)[] where, const(char)[] sessionId) {
    import db : storePath;
    if (fileOpenInProcess(storePath())) {
        import exec : emitError;
        emitError("fork.store-open",
                  "a fork with the store open was refused: the child would write unlocked",
                  0, -1, cast(string) sessionId, cast(string) where, "", "", "");
        return REFUSED;
    }
    return fork();
}
