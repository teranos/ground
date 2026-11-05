module close_test;

// ug opens ground's store several times a frame. Whichever close is the last
// must neither write the WAL back nor take the -wal and -shm with it.

import core.stdc.stdio : printf, fopen, fclose;
import core.stdc.stdlib : getenv, exit;
import core.sys.posix.sys.stat : stat_t, stat, mkdir;
import sql;

extern (C) int setenv(const(char)* name, const(char)* value, int overwrite);
extern (C) char* mkdtemp(char* tmpl);

long size(const(char)[] path, const(char)[] suffix) {
    char[600] p = 0;
    size_t o;
    foreach (c; path) p[o++] = c;
    foreach (c; suffix) p[o++] = c;
    stat_t st;
    return stat(&p[0], &st) == 0 ? st.st_size : -1;
}

void check(bool ok, const(char)* what) {
    if (ok) return;
    printf("close_test: %s\n", what);
    exit(1);
}

extern (C) int main() {
    char[64] tmpl = "/tmp/ug-close-XXXXXX\0";
    auto home = mkdtemp(&tmpl[0]);
    check(home !is null, "no temporary HOME");
    size_t hl;
    while (home[hl] != 0) hl++;

    char[600] dir = 0;
    size_t o;
    foreach (c; home[0 .. hl]) dir[o++] = c;
    foreach (part; ["/.local", "/.local/share", "/.local/share/ground"]) {
        foreach (i, c; part) dir[hl + i] = c;
        dir[hl + part.length] = 0;
        mkdir(&dir[0], 493);
    }

    __gshared char[512] path = void;
    auto pl = dbPathInto(home[0 .. hl], path[]);

    // ug opens a store ground made, and never makes one.
    auto made = fopen(&path[0], "w");
    check(made !is null, "the store file could not be made");
    fclose(made);

    sqlite3* db;
    check(openGround(&path[0], db) == SQLITE_OK, "the store did not open");
    sqlite3_exec(db, "PRAGMA journal_mode = WAL; CREATE TABLE t (b BLOB); PRAGMA wal_checkpoint(TRUNCATE)\0".ptr, null, null, null);
    auto before = size(path[0 .. pl], "");
    enum bulk = "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 256) "
        ~ "INSERT INTO t SELECT randomblob(4096) FROM c\0";
    check(sqlite3_exec(db, bulk.ptr, null, null, null) == SQLITE_OK, "the rows did not go in");
    sqlite3_close(db);

    check(size(path[0 .. pl], "") == before, "the last close wrote the WAL back into the store");
    check(size(path[0 .. pl], "-wal") > 0, "the last close took the -wal with it");
    check(size(path[0 .. pl], "-shm") > 0, "the last close took the -shm with it");
    printf("close_test: ok\n");
    return 0;
}
