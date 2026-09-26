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
