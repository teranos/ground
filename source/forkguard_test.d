module forkguard_test;

// "ground cant fail on me" — the store went corrupt four times in one month
// because a hook forked with its connection open. The guard reads the kernel's
// descriptor table, so it is right whether or not every close was counted.

import forkguard : fileOpenInProcess;
import db : sqlite3, sqlite3_open, sqlite3_close, SQLITE_OK;
import core.stdc.stdio : snprintf;
import core.sys.posix.unistd : getpid, unlink;

unittest {
    char[128] path = 0;
    snprintf(path.ptr, path.length, "/tmp/ground-forkguard-%d.db", getpid());
    unlink(path.ptr);

    assert(!fileOpenInProcess(path.ptr), "a file that does not exist is not open");

    sqlite3* db;
    assert(sqlite3_open(path.ptr, &db) == SQLITE_OK);
    // sqlite opens the file lazily; the first statement makes it real.
    import db : sqlite3_exec;
    sqlite3_exec(db, "CREATE TABLE t(x)\0".ptr, null, null, null);
    assert(fileOpenInProcess(path.ptr), "an open connection is a descriptor on the file");

    sqlite3_close(db);
    assert(!fileOpenInProcess(path.ptr), "closed is closed");
    unlink(path.ptr);
}

// A hook's answer printed and not yet flushed was copied into the child a
// slow hook forks to report itself; the child's freopen flushed the copy into
// the same pipe, and Claude Code read the answer twice, as JSON it could not
// parse (2026-11-21, 27 hooks from 09:41Z). What was written is written once.
unittest {
    import forkguard : forkClean;
    import core.stdc.stdio : fopen, fputs, fclose, fread, freopen, FILE;
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.unistd : _exit;
    char[128] path = 0;
    snprintf(path.ptr, path.length, "/tmp/ground-forkflush-%d.txt", getpid());
    auto f = fopen(path.ptr, "w");
    fputs("the answer\n", f);
    auto pid = forkClean("forkguard_test", "");
    assert(pid >= 0);
    if (pid == 0) {
        freopen("/dev/null\0".ptr, "w\0".ptr, f);
        _exit(0);
    }
    int st;
    waitpid(pid, &st, 0);
    fclose(f);
    char[64] got = 0;
    auto r = fopen(path.ptr, "r");
    auto n = fread(got.ptr, 1, got.length, r);
    fclose(r);
    unlink(path.ptr);
    assert(got[0 .. n] == "the answer\n", "written once, by the parent, before the fork");
}
