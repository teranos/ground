module live_test;

// "its not really like once every 4 hours"
// ug the way Claude Code runs it. "If a new update triggers while a slow script
// is running, the in-flight script is cancelled", and the row refreshes every
// second. Measured 2026-09-15: a recording that waited on QNTX before writing
// its row was cancelled every frame, never wrote the row, and attested once a
// second from every session.
//
// Frames are killed 300ms in, against a QNTX that never answers. Two windows
// in the payload is two rows, however many frames run, and each row's attempt
// finishes on its own.
//
// Run by make test-ug-live, not make test: it waits on curl's timeout.

import core.stdc.stdio : printf, snprintf, fopen, fwrite, fclose;
import core.sys.posix.fcntl : open, O_RDONLY, O_WRONLY;
import core.sys.posix.unistd : fork, execve, dup2, close, _exit, getpid, usleep;
import core.sys.posix.signal : kill, SIGKILL;
import core.sys.posix.sys.wait : waitpid;
import core.sys.posix.sys.stat : mkdir;

extern (C) {
    struct sqlite3;
    struct sqlite3_stmt;
    int sqlite3_open(const(char)* path, sqlite3** db);
    int sqlite3_prepare_v2(sqlite3* db, const(char)* sql, int n, sqlite3_stmt** stmt, const(char)** tail);
    int sqlite3_step(sqlite3_stmt* stmt);
    long sqlite3_column_int64(sqlite3_stmt* stmt, int col);
    int sqlite3_finalize(sqlite3_stmt* stmt);
    int sqlite3_close(sqlite3* db);
}

enum FRAMES = 20;
enum CANCEL_AFTER_US = 300_000;
enum SETTLE_US = 6_000_000;

// 10.255.255.1 is not routed, so a connection to it waits out curl's max-time.
enum NEVER_ANSWERS = "QNTX_HOST=http://10.255.255.1";

enum PAYLOAD = `{"session_id":"live-test","cwd":"/tmp","model":{"display_name":"t"},`
    ~ `"context_window":{"used_percentage":5},`
    ~ `"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1900000000},`
    ~ `"seven_day":{"used_percentage":20,"resets_at":1900000000}}}`;

__gshared char[256] home = 0;
__gshared char[300] homeEnv = 0;

private void run(const(char)* bin, const(char)* arg, const(char)* stdinPath, bool cancel) {
    auto pid = fork();
    if (pid == 0) {
        auto input = open(stdinPath, O_RDONLY);
        if (input >= 0) dup2(input, 0);
        auto sink = open("/dev/null", O_WRONLY);
        if (sink >= 0) { dup2(sink, 1); dup2(sink, 2); }
        const(char)*[3] argv = [bin, arg, null];
        const(char)*[4] envp = [&homeEnv[0], "PATH=/usr/bin:/bin", NEVER_ANSWERS.ptr, null];
        execve(bin, cast(char**) argv.ptr, cast(char**) envp.ptr);
        _exit(127);
    }
    if (cancel) {
        usleep(CANCEL_AFTER_US);
        kill(pid, SIGKILL);
    }
    int status;
    waitpid(pid, &status, 0);
}

private long count(sqlite3* db, const(char)* sql) {
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, null) != 0) return -1;
    long n = sqlite3_step(stmt) == 100 ? sqlite3_column_int64(stmt, 0) : -1;
    sqlite3_finalize(stmt);
    return n;
}

extern (C) int main(int argc, char** argv) {
    if (argc < 3) {
        printf("usage: live_test <ug> <ground>\n");
        return 2;
    }

    snprintf(&home[0], home.length, "/tmp/ug-live-%d", getpid());
    snprintf(&homeEnv[0], homeEnv.length, "HOME=%s", &home[0]);

    char[512] path = 0;
    mkdir(&home[0], 0x1ed);
    snprintf(&path[0], path.length, "%s/.qntx", &home[0]);
    mkdir(&path[0], 0x1c0);
    snprintf(&path[0], path.length, "%s/.qntx/token", &home[0]);
    {
        auto f = fopen(&path[0], "wb");
        enum tok = "live-test-token\n";
        fwrite(tok.ptr, 1, tok.length, f);
        fclose(f);
    }
    char[512] payload = 0;
    snprintf(&payload[0], payload.length, "%s/payload.json", &home[0]);
    {
        auto f = fopen(&payload[0], "wb");
        fwrite(PAYLOAD.ptr, 1, PAYLOAD.length, f);
        fclose(f);
    }

    // The store is ground's, schema and all.
    run(argv[2], "usage", "/dev/null", false);

    foreach (i; 0 .. FRAMES) run(argv[1], null, &payload[0], true);

    usleep(SETTLE_US);

    snprintf(&path[0], path.length, "%s/.local/share/ground/ground.db", &home[0]);
    sqlite3* db;
    if (sqlite3_open(&path[0], &db) != 0) {
        printf("live: cannot open %s\n", &path[0]);
        return 1;
    }
    auto rows = count(db, "SELECT COUNT(*) FROM usage");
    auto unfinished = count(db, "SELECT COUNT(*) FROM usage WHERE qntx_exit = -2");
    sqlite3_close(db);

    printf("live: %d frames cancelled, %lld rows, %lld attempts unfinished (%s)\n",
           FRAMES, rows, unfinished, &home[0]);
    if (rows != 2) {
        printf("live: FAIL — two windows must be two rows, however many frames run\n");
        return 1;
    }
    if (unfinished != 0) {
        printf("live: FAIL — an attempt to attest did not finish outside the frame\n");
        return 1;
    }
    printf("live: ok\n");
    return 0;
}
