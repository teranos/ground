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
    int* __error(); // macOS thread-local errno
    int kill(int pid, int sig);
    int getpid();

    struct pollfd {
        int fd;
        short events;
        short revents;
    }
    int poll(pollfd* fds, uint nfds, int timeout);
}

enum POLLIN  = 0x001;
enum POLLHUP = 0x010;
enum POLLERR = 0x008;
enum SIGTERM = 15;
enum SIGKILL = 9;
enum WNOHANG = 1;

// Default script timeout in seconds when handler_params doesn't specify.
// Long enough for realistic deploy scripts; short enough to catch hangs.
enum DEFAULT_TIMEOUT_SEC = 300;

private int errno() { return *__error(); }

// Under the ERROR AXIOM: every failure path constructs a GroundError and
// calls deliverError. This helper packages the boilerplate. When called,
// SOMETHING lands in front of the user — via db, breadcrumb, or stderr.
// Never a silent return.
private void emitError(
    string origin, string message,
    int errnoVal, int exitCode,
    string sessionId, string controlName, string toolUseId,
    string stdoutData, string stderrData,
) {
    import errors : GroundError, deliverError;
    import core.stdc.time : time;
    GroundError err;
    err.origin      = origin;
    err.message     = message;
    err.errnoVal    = errnoVal;
    err.exitCode    = exitCode;
    err.sessionId   = sessionId;
    err.controlName = controlName;
    err.toolUseId   = toolUseId;
    err.timestamp   = cast(long) time(null);
    err.stdout      = stdoutData;
    err.stderr      = stderrData;
    cast(void) deliverError(err);
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

// Fire the exec target as a detached child. Parent forks a wrapper and
// returns; the wrapper spawns the script grandchild, captures stdout AND
// stderr, enforces a timeout, and emits exactly one terminal Error via
// deliverError. Every failure path — pre-execv or otherwise — constructs
// a GroundError. No silent returns. Per the ERROR AXIOM.
//
// exec: values are inline script content (not paths). Ground writes the
// content to a mkstemp'd file at fire time, chmods +x, and execv's the
// file. /tmp housekeeping cleans up the file eventually.
//
// Project env for cwd is resolved from controls.allParsed via
// longest-path-wins match, matching envSubst's own resolution rule.
//
// timeoutSec: how many seconds the wrapper waits before SIGTERM'ing the
// grandchild. 0 or negative → use DEFAULT_TIMEOUT_SEC.
void dispatchExec(
    string execScript,
    string controlName,
    string toolUseId,
    int timeoutSec,
    const(string)[] controlKeys, const(string)[] controlValues,
    string sessionId, const(char)[] cwd, const(char)[] toolInput,
) {
    import controls : allParsed;
    import matcher : contains;

    if (execScript.length == 0) {
        emitError("exec.dispatch", "control has empty exec: script",
                  0, -1, sessionId, controlName, toolUseId, "", "");
        return;
    }

    if (timeoutSec <= 0) timeoutSec = DEFAULT_TIMEOUT_SEC;

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

    // --- Materialize script to a private tempfile ---

    char[64] tmpPath = 0;
    string templ = "/tmp/ground-exec-XXXXXX";
    foreach (i, ch; templ) tmpPath[i] = ch;
    int fd = mkstemp(&tmpPath[0]);
    if (fd < 0) {
        emitError("exec.mkstemp", "mkstemp failed",
                  errno(), -1, sessionId, controlName, toolUseId, "", "");
        return;
    }

    if (write(fd, execScript.ptr, execScript.length) != cast(long) execScript.length) {
        auto e = errno();
        close(fd);
        emitError("exec.write", "wrote fewer bytes than script content",
                  e, -1, sessionId, controlName, toolUseId, "", "");
        return;
    }
    close(fd);

    if (chmod(&tmpPath[0], octal!700) != 0) {
        emitError("exec.chmod", "chmod +x failed",
                  errno(), -1, sessionId, controlName, toolUseId, "", "");
        return;
    }

    // --- Two pipes: stdout AND stderr captured independently ---

    int[2] outPipe;
    if (pipe(&outPipe[0]) != 0) {
        emitError("exec.pipe.stdout", "pipe() failed for stdout capture",
                  errno(), -1, sessionId, controlName, toolUseId, "", "");
        return;
    }
    int[2] errPipe;
    if (pipe(&errPipe[0]) != 0) {
        auto e = errno();
        close(outPipe[0]); close(outPipe[1]);
        emitError("exec.pipe.stderr", "pipe() failed for stderr capture",
                  e, -1, sessionId, controlName, toolUseId, "", "");
        return;
    }

    // --- Fork wrapper. Parent returns immediately. ---

    auto wrapperPid = fork();
    if (wrapperPid < 0) {
        auto e = errno();
        close(outPipe[0]); close(outPipe[1]);
        close(errPipe[0]); close(errPipe[1]);
        emitError("exec.fork.wrapper", "fork() failed for wrapper",
                  e, -1, sessionId, controlName, toolUseId, "", "");
        return;
    }
    if (wrapperPid != 0) {
        close(outPipe[0]); close(outPipe[1]);
        close(errPipe[0]); close(errPipe[1]);
        return;
    }

    // --- Wrapper (child of ground) ---

    auto scriptPid = fork();
    if (scriptPid < 0) {
        auto e = errno();
        close(outPipe[0]); close(outPipe[1]);
        close(errPipe[0]); close(errPipe[1]);
        emitError("exec.fork.script", "fork() failed for script",
                  e, -1, sessionId, controlName, toolUseId, "", "");
        _exit(0);
    }
    if (scriptPid == 0) {
        // --- Grandchild (script) ---
        dup2(outPipe[1], 1);
        dup2(errPipe[1], 2);
        close(outPipe[0]); close(outPipe[1]);
        close(errPipe[0]); close(errPipe[1]);

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
        _exit(127); // execv only returns on failure
    }

    // Wrapper: close write ends (grandchild owns them). Poll-read both
    // pipes concurrently with per-cycle timeout. Track cumulative
    // wall-clock; if we exceed timeoutSec, SIGTERM (then SIGKILL) the
    // grandchild and emit a timeout Error.
    close(outPipe[1]);
    close(errPipe[1]);

    char[4096] outBuf = 0; size_t outLen = 0;
    char[4096] errBuf = 0; size_t errLen = 0;
    bool outOpen = true, errOpen = true;

    import core.stdc.time : time;
    auto startTs = cast(long) time(null);
    bool timedOut = false;

    while (outOpen || errOpen) {
        auto elapsed = cast(long) time(null) - startTs;
        if (elapsed >= timeoutSec) {
            timedOut = true;
            kill(scriptPid, SIGTERM);
            // Give it 2 seconds to react, then SIGKILL.
            auto killDeadline = cast(long) time(null) + 2;
            while (cast(long) time(null) < killDeadline) {
                int st;
                if (waitpid(scriptPid, &st, WNOHANG) != 0) break;
            }
            kill(scriptPid, SIGKILL);
            break;
        }

        pollfd[2] fds;
        uint nfds = 0;
        if (outOpen) { fds[nfds].fd = outPipe[0]; fds[nfds].events = POLLIN; fds[nfds].revents = 0; nfds++; }
        if (errOpen) { fds[nfds].fd = errPipe[0]; fds[nfds].events = POLLIN; fds[nfds].revents = 0; nfds++; }
        if (nfds == 0) break;

        int pollTimeoutMs = 1000; // wake once per second to re-check timeout
        int r = poll(&fds[0], nfds, pollTimeoutMs);
        if (r < 0) {
            // poll error is itself an Error, but we still need to wait for
            // grandchild. Break out and let the completion path emit.
            break;
        }
        if (r == 0) continue; // timeout tick, loop back

        foreach (i; 0 .. nfds) {
            auto pf = fds[i];
            if (pf.revents & POLLIN) {
                char[1024] chunk;
                auto n = read(pf.fd, &chunk[0], chunk.length);
                if (n <= 0) {
                    if (pf.fd == outPipe[0]) { outOpen = false; close(pf.fd); }
                    else if (pf.fd == errPipe[0]) { errOpen = false; close(pf.fd); }
                } else {
                    if (pf.fd == outPipe[0])
                        tailAppend(&outBuf[0], outLen, outBuf.length, chunk[0 .. cast(size_t) n]);
                    else if (pf.fd == errPipe[0])
                        tailAppend(&errBuf[0], errLen, errBuf.length, chunk[0 .. cast(size_t) n]);
                }
            } else if (pf.revents & (POLLHUP | POLLERR)) {
                if (pf.fd == outPipe[0]) { outOpen = false; close(pf.fd); }
                else if (pf.fd == errPipe[0]) { errOpen = false; close(pf.fd); }
            }
        }
    }

    // Drain any remaining pipe data even if we timed out (best-effort;
    // pipes may already be closed by SIGKILL).
    if (outOpen) close(outPipe[0]);
    if (errOpen) close(errPipe[0]);

    int status;
    waitpid(scriptPid, &status, 0);
    int exitCode = (status >> 8) & 0xFF;

    // Every terminal outcome — timeout, non-zero exit, normal exit —
    // flows through the SAME error surface. The wrapper never returns
    // silently.
    string stdoutData = cast(string) outBuf[0 .. outLen];
    string stderrData = cast(string) errBuf[0 .. errLen];
    if (timedOut) {
        emitError("exec.timeout", "grandchild exceeded configured timeout",
                  0, exitCode, sessionId, controlName, toolUseId,
                  stdoutData, stderrData);
    } else {
        emitError("exec.script", "grandchild exited",
                  0, exitCode, sessionId, controlName, toolUseId,
                  stdoutData, stderrData);
    }
    _exit(0);
}

// Bounded ring-tail buffer. If new data would overflow, drop oldest bytes
// to keep the last capBytes. Used per stream for stdout/stderr capture.
private void tailAppend(char* buf, ref size_t len, size_t cap, const(char)[] chunk) {
    if (chunk.length >= cap) {
        foreach (i; 0 .. cap) buf[i] = chunk[chunk.length - cap + i];
        len = cap;
        return;
    }
    if (len + chunk.length > cap) {
        auto drop = len + chunk.length - cap;
        for (size_t i = 0; i < len - drop; i++) buf[i] = buf[i + drop];
        len -= drop;
    }
    foreach (i; 0 .. chunk.length) buf[len + i] = chunk[i];
    len += chunk.length;
}

// Helper for octal literals (D's 0o syntax is deprecated).
private template octal(uint n) {
    static if (n < 10)
        enum uint octal = n;
    else
        enum uint octal = octal!(n / 10) * 8 + (n % 10);
}
