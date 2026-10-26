module lockholder_test;

// A hook that slept on ground.db's write lock said how long, and never who
// held it, so a 5s wait under codex and Claude Code alike had no cause to name.

// A child process holds the write lock on a WAL store; the parent, which
// would be the hook left waiting, is told the child's pid and what it runs.
unittest {
    import lockholder : writeLockHolder, holderName;
    import db : sqlite3, sqlite3_open, sqlite3_exec, sqlite3_close;
    import core.sys.posix.unistd : fork, pipe, read, write, close, getpid, unlink;
    import core.sys.posix.signal : kill, SIGKILL;
    import core.sys.posix.sys.wait : waitpid;
    import core.stdc.stdio : snprintf;
    import core.stdc.stdlib : getenv;

    char[256] path = 0;
    char[256] shm = 0;
    char[256] wal = 0;
    auto tmp = getenv("TMPDIR");
    snprintf(path.ptr, path.length, "%s/lockholder-%d.db", tmp is null ? "/tmp".ptr : tmp, getpid());
    snprintf(shm.ptr, shm.length, "%s-shm", path.ptr);
    snprintf(wal.ptr, wal.length, "%s-wal", path.ptr);

    sqlite3* db;
    assert(sqlite3_open(path.ptr, &db) == 0);
    sqlite3_exec(db, "PRAGMA journal_mode = WAL; PRAGMA user_version = 1\0".ptr, null, null, null);

    assert(writeLockHolder(shm.ptr) == 0, "nobody writing, nobody named");

    int[2] fds;
    assert(pipe(fds) == 0);
    auto child = fork();
    if (child == 0) {
        sqlite3* own;
        sqlite3_open(path.ptr, &own);
        sqlite3_exec(own, "BEGIN IMMEDIATE\0".ptr, null, null, null);
        char[1] ready = ['r'];
        write(fds[1], ready.ptr, 1);
        while (true) {}
    }
    char[1] got;
    assert(read(fds[0], got.ptr, 1) == 1);

    auto holder = writeLockHolder(shm.ptr);
    char[128] name;
    auto said = holderName(holder, name[]);
    kill(child, SIGKILL);
    int status;
    waitpid(child, &status, 0);
    close(fds[0]);
    close(fds[1]);
    sqlite3_close(db);
    unlink(path.ptr);
    unlink(shm.ptr);
    unlink(wal.ptr);

    assert(holder == child, "the write lock's holder is the child that took it");
    char[16] pidText = 0;
    auto n = snprintf(pidText.ptr, pidText.length, "#%d", child);
    assert(said.length > cast(size_t) n && said[$ - n .. $] == pidText[0 .. n]);
    assert(said[0] < '0' || said[0] > '9', "a phase value that starts with a digit is read as a number");
    // The child runs the test binary itself, so it is named as this process is,
    // whichever build named the binary.
    char[128] mine;
    auto own = holderName(getpid(), mine[]);
    size_t stem;
    while (stem < own.length && own[stem] != '#') stem++;
    assert(stem > 0 && said.length > stem && said[0 .. stem + 1] == own[0 .. stem + 1], said);
    foreach (c; said) assert(c != ' ', "a space ends a phase pair");
}
