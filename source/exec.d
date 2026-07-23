module exec;

extern (C) {
    int fork();
    int execv(const(char)* path, const(char*)* argv);
    int setenv(const(char)* name, const(char)* value, int overwrite);
    void _exit(int status);
    int mkstemp(char* templ);
    long write(int fd, const(void)* buf, size_t count);
    long read(int fd, void* buf, size_t count);
    int close(int fd);
    int chmod(const(char)* path, uint mode);
    int pipe(int* pipefd);
    int dup2(int oldfd, int newfd);
    int waitpid(int pid, int* wstatus, int options);
}

// Merged env for the exec child. 24 = 8 (control) + 16 (project) — the
// max possible if both are full with disjoint keys. Runtime never sees
// more than this.
struct MergedEnv {
    string[24] keys;
    string[24] values;
    ubyte count;
}

// Full env dict for the child process. GROUND_ floor (3 slots) + merged
// env (24 max) = 27 max entries. Sized to 32 for slack.
struct ChildEnv {
    string[32] keys;
    string[32] values;
    ubyte count;
}

// Layer control-env on top of project-env. Control wins on collision;
// non-colliding pairs union together. Position is stable: project pairs
// first (in arrival order), then non-collision control pairs. Colliding
// control values overwrite in place — the key does not move.
//
// GROUND_-prefixed vars (session_id, cwd, tool_input) are prepended at
// runtime dispatch time, not by this function. This function stays pure
// so the precedence rule can be locked in via CTFE tests.
MergedEnv mergeEnv(
    const(string)[] controlKeys, const(string)[] controlValues,
    const(string)[] projectKeys, const(string)[] projectValues,
) {
    MergedEnv result;

    foreach (i; 0 .. projectKeys.length) {
        if (projectKeys[i] is null || projectKeys[i].length == 0) continue;
        result.keys[result.count] = projectKeys[i];
        result.values[result.count] = projectValues[i];
        result.count++;
    }

    foreach (i; 0 .. controlKeys.length) {
        if (controlKeys[i] is null || controlKeys[i].length == 0) continue;
        bool overwritten = false;
        foreach (j; 0 .. result.count) {
            if (result.keys[j] == controlKeys[i]) {
                result.values[j] = controlValues[i];
                overwritten = true;
                break;
            }
        }
        if (!overwritten) {
            result.keys[result.count] = controlKeys[i];
            result.values[result.count] = controlValues[i];
            result.count++;
        }
    }

    return result;
}

// Build the full env dict passed to an exec child. GROUND_ vars come first
// (positions 0..2, always present), then merged (project + control) pairs.
// Pbt authors should not declare GROUND_-prefixed keys in env {} blocks —
// GROUND_ names are reserved for the runtime floor. Nothing enforces this
// today; it's a convention.
ChildEnv prepareChildEnv(
    const(string)[] controlKeys, const(string)[] controlValues,
    const(string)[] projectKeys, const(string)[] projectValues,
    string sessionId, string cwd, string toolInput,
) {
    ChildEnv result;

    result.keys[0]   = "GROUND_SESSION_ID";
    result.values[0] = sessionId;
    result.keys[1]   = "GROUND_CWD";
    result.values[1] = cwd;
    result.keys[2]   = "GROUND_TOOL_INPUT";
    result.values[2] = toolInput;
    result.count = 3;

    auto merged = mergeEnv(controlKeys, controlValues, projectKeys, projectValues);
    foreach (i; 0 .. merged.count) {
        result.keys[result.count]   = merged.keys[i];
        result.values[result.count] = merged.values[i];
        result.count++;
    }

    return result;
}

// Fire the exec target as a detached child. Parent returns immediately
// regardless of outcome — no waiting, no zombies (child is inherited by
// init when ground's hook process exits shortly after).
//
// exec: values are inline script content (not paths). Ground writes the
// content to a mktemp'd file at fire time, chmods +x, and execv's the
// file. /tmp housekeeping cleans up the file eventually. The pbt is the
// single source of truth for what runs — no separate .fish file to keep
// in sync with the control declaration.
//
// Project env for cwd is resolved from controls.allParsed via
// longest-path-wins match, matching envSubst's own resolution rule.
void dispatchExec(
    string execScript,
    string controlName,
    const(string)[] controlKeys, const(string)[] controlValues,
    string sessionId, const(char)[] cwd, const(char)[] toolInput,
) {
    import controls : allParsed;
    import matcher : contains;

    if (execScript.length == 0) return;

    static immutable parsed = allParsed;
    int bestIdx = -1;
    size_t bestLen = 0;
    foreach (i; 0 .. parsed.envCount) {
        if (parsed.envs[i].path.length > 0 && contains(cwd, parsed.envs[i].path)) {
            if (parsed.envs[i].path.length > bestLen) {
                bestLen = parsed.envs[i].path.length;
                bestIdx = cast(int) i;
            }
        }
    }

    const(string)[] projectKeys;
    const(string)[] projectValues;
    if (bestIdx >= 0) {
        projectKeys   = parsed.envs[bestIdx].keys[0 .. parsed.envs[bestIdx].count];
        projectValues = parsed.envs[bestIdx].values[0 .. parsed.envs[bestIdx].count];
    }

    auto env = prepareChildEnv(
        controlKeys, controlValues,
        projectKeys, projectValues,
        cast(string) sessionId, cast(string) cwd, cast(string) toolInput,
    );

    // Materialize the inline script to a private tempfile.
    // mkstemp creates the file with mode 0600 (owner rw only).
    char[64] tmpPath = 0;
    string templ = "/tmp/ground-exec-XXXXXX";
    foreach (i, ch; templ) tmpPath[i] = ch;
    int fd = mkstemp(&tmpPath[0]);
    if (fd < 0) return;

    if (write(fd, execScript.ptr, execScript.length) != cast(long) execScript.length) {
        close(fd);
        return;
    }
    close(fd);

    // 0o700 = owner rwx, no group/other. Keeps the script private and
    // executable — no world-writable exposure.
    if (chmod(&tmpPath[0], octal!700) != 0) return;

    // One pipe for stdout capture. Parent forks a wrapper (returns
    // immediately). Wrapper forks the grandchild that becomes the script,
    // reads the pipe, waits, writes the completion attestation.
    int[2] outPipe;
    if (pipe(&outPipe[0]) != 0) return;

    auto wrapperPid = fork();
    if (wrapperPid != 0) {
        close(outPipe[0]);
        close(outPipe[1]);
        return;
    }

    auto scriptPid = fork();
    if (scriptPid == 0) {
        // Grandchild.
        dup2(outPipe[1], 1);
        close(outPipe[0]);
        close(outPipe[1]);

        foreach (i; 0 .. env.count) {
            char[256]  kbuf = 0;
            char[8192] vbuf = 0;
            auto k = env.keys[i];
            auto v = env.values[i];
            if (k.length >= kbuf.length || v.length >= vbuf.length) continue;
            foreach (j, ch; k) kbuf[j] = ch;
            foreach (j, ch; v) vbuf[j] = ch;
            setenv(&kbuf[0], &vbuf[0], 1);
        }

        const(char)*[2] argv = [cast(const(char)*) &tmpPath[0], null];
        execv(&tmpPath[0], argv.ptr);
        _exit(127);
    }

    // Wrapper.
    close(outPipe[1]);

    char[4096] captureBuf = 0;
    size_t captureLen = 0;
    while (captureLen < captureBuf.length) {
        auto n = read(outPipe[0], &captureBuf[captureLen], captureBuf.length - captureLen);
        if (n <= 0) break;
        captureLen += cast(size_t) n;
    }
    close(outPipe[0]);

    int status;
    waitpid(scriptPid, &status, 0);
    int exitCode = (status >> 8) & 0xFF;

    {
        import immediate : writeExecComplete;
        import db : openDb, sqlite3_close;
        auto db = openDb();
        if (db !is null) {
            writeExecComplete(db, sessionId, controlName, exitCode,
                              captureBuf[0 .. captureLen]);
            sqlite3_close(db);
        }
    }

    _exit(0);
}

// Helper for octal literals (D's 0o syntax is deprecated).
private template octal(uint n) {
    static if (n < 10)
        enum uint octal = n;
    else
        enum uint octal = octal!(n / 10) * 8 + (n % 10);
}
