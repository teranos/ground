module precompact;

import matcher : contains;
import parse : fputs2;
import core.stdc.stdio : stdin, stdout, fputs, fread, fwrite, FILE;
import db : popen, pclose;

int handlePreCompact(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    import controls : preCompactScopes;

    bool first = true;
    fputs(`{"systemMessage":"`, stdout);

    foreach (ref scope_; preCompactScopes) {
        if (scope_.path.length > 0 && (cwd is null || !contains(cwd, scope_.path)))
            continue;
        foreach (ref c; scope_.controls) {
            if (!first) fputs(" | ", stdout);
            first = false;

            if (c.msg.value.length > 0)
                fputs2(c.msg.value);

            if (c.cmd.value.length > 0) {
                __gshared char[4096] cmdBuf = 0;
                __gshared char[1024] outBuf = 0;
                if (c.cmd.value.length < cmdBuf.length) {
                    foreach (i, ch; c.cmd.value) cmdBuf[i] = ch;
                    cmdBuf[c.cmd.value.length] = 0;
                    auto pipe = popen(&cmdBuf[0], "r");
                    if (pipe !is null) {
                        auto n = fread(&outBuf[0], 1, outBuf.length, pipe);
                        pclose(pipe);
                        while (n > 0 && (outBuf[n-1] == '\n' || outBuf[n-1] == '\r')) n--;
                        if (n > 0) fwrite(&outBuf[0], 1, n, stdout);
                    }
                }
            }

            {
                import db : attestControlFire;
                attestControlFire(null, "GroundedPreCompact", c.name, cwd, sessionId);
            }
        }
    }

    fputs(`"}`, stdout);
    fputs("\n", stdout);

    // Checkpoint WAL so the next Stop doesn't pay for our writes
    {
        import db : openDb, walCheckpoint, sqlite3_close;
        auto cpDb = openDb();
        if (cpDb !is null) {
            walCheckpoint(cpDb);
            sqlite3_close(cpDb);
        }
    }

    return 0;
}
