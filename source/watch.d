module watch;

// ground watch <cwd>
//
// Immediate delivery via asyncRewake. Polls the db every 2 seconds for
// immediate: attestations matching the project. Batches all pending messages,
// debounces (5s quiet window), writes to stderr and exits 2. Claude Code's
// asyncRewake shows stderr as a system reminder and wakes the session.
//
// Spawned by the Stop hook: {"command":"ground watch $PWD","asyncRewake":true}
// Each Stop fires a new watcher. Claude Code does NOT deduplicate async hooks
// (confirmed by docs), so we handle it ourselves via PID files.
//
// Session identity:
//   asyncRewake doesn't expose the session ID. The Stop handler (which has it)
//   kills the previous watcher for its session via watch-<sessionId>.pid, then
//   writes a claim file watch-claim-<sessionId>.id. The new watcher claims the
//   file (atomic rename) to learn its session ID and writes its PID.
//   Killing is keyed by session — watchers from different sessions never
//   interfere with each other.
//
// Debounce:
//   When messages are found, the watcher waits 5s before checking again.
//   If more messages arrive during the wait, the timer resets. Delivery
//   happens only after a full 5s with no new messages. This batches
//   burst events (e.g. QNTX restart with 7 plugins) into one notification.
//
// Two keying models, both flow through this watcher:
//
//   1. SESSION-KEYED (ground's own writers: writeCIStatus, writeClippyReminder).
//      Row contexts: ["session:<sid>"]. Row carries everything the watcher
//      needs to resolve at delivery time — for ci-status that's repo + branch
//      + sha parsed from the push's own stdout (see push.parsePushOutput).
//      readImmediateMessage matches by session. cwd plays no role.
//
//   2. PROJECT-KEYED (external writers like QNTX). Row contexts:
//      ["project:<path>"]. The watcher delivers when its cwd ends with the
//      project path. Cross-session delivery to anyone in the project is
//      intentional for lifecycle events.
//
// Late-binding for ci-status:
//   The placeholder "Checking CI..." is replaced live at delivery time by
//   checkCIStatus(repo, branch) which calls `gh -R <repo> --branch <branch>`.
//   in_progress: skip, retry next 2s cycle. failure: urgent (bypass debounce).
//   success: normal (5s debounce). No CI workflow at all: silently mark
//   delivered so the row doesn't loop forever.
//
// --- Migration from legacy deferred → immediate (sequential checklist) ---
//
// LANDED on this branch:
//   [x] Immediate delivery pipeline + asyncRewake watcher (b0422af)
//   [x] Per-session, per-message dedup via delivered:<msgId> attestations
//   [x] CI status writer: session-keyed (40a1e16); cwd killed (5f94ca7);
//       repo + branch + sha sourced from git push's own stdout
//   [x] Clippy reminder writer + deleter: session-keyed (40a1e16)
//   [x] checkCIStatus uses `gh -R <repo>` (5f94ca7) — no cwd dependency
//   [x] ImmediateMsg carries repo + branch + sha for late-binding
//   [x] Legacy ciDeliver handler removed (no .pbt referenced it)
//
// STILL OWED (move legacy deferred → immediate):
//   [ ] PostToolUseDeferred writers (the `gh pr review` nudge today; future
//       similar) → write to immediate with after-gate instead of polling
//       deferred queue at Stop. Shrinks stop.d's deferred-section.
//   [ ] Session-scoped deferred (stop.d:271-284) → session-keyed immediate
//       removes the need for stop.d to read the deferred queue.
//   [ ] Project-scoped deferred (stop.d:286-301, main/master-only) → either
//       (a) project-keyed immediate (path stays in row contexts, watcher
//       does cwd-suffix match like QNTX rows), or (b) drop the main/master
//       gate as part of the move.
//   [ ] Once the above land: delete deferred.d's read paths (deferred-session
//       and deferred-project) and the stop.d sections that consume them.
//   [ ] writeClippyReminder still cwd-aware in spirit (it doesn't run if
//       isRustProject(cwd) is false). Decide: session-key the trigger too
//       (any .rs edit in this session, no project gate), or keep the gate.
//
// POSSIBLY DROP:
//   [ ] readImmediateMessage's project-suffix fallback path. If/when QNTX
//       writes session-aware messages, the only reason for the project
//       fallback disappears. Until then, keep it.
//
// LATER POLISH:
//   [x] Adaptive poll interval. writeCIStatus fetches p50/p90 of the last 20
//       CI durations per repo+branch via gh, stores them with push_time in
//       the row. watch.d picks sleep based on elapsed-vs-percentile bracket
//       (see source/adaptive.d, CTFE-tested).
//   [x] Backoff during long-running CI: same mechanism.
//   [ ] Race window in claimSession: new watcher reads claim then dies
//       before writePid → session is un-watched until next Stop.

import db : sqlite3, sqlite3_close, openDb, ZBuf;
import immediate : readImmediateMessage, markImmediateDelivered;
import core.stdc.stdio : stderr, fputs, fwrite, FILE;

extern (C) {
    uint sleep(uint seconds);
    int getpid();
    int kill(int pid, int sig);
    FILE* fopen(const(char)* path, const(char)* mode);
    int fclose(FILE* f);
    int fprintf(FILE* f, const(char)* fmt, ...);
    size_t fread(void* ptr, size_t size, size_t nmemb, FILE* stream);
    int rename(const(char)* oldpath, const(char)* newpath);
    int remove(const(char)* path);
    FILE* popen(const(char)* command, const(char)* mode);
    int pclose(FILE* stream);
}

const(char)[] getHome() {
    import core.stdc.stdlib : getenv;
    auto h = getenv("HOME");
    if (h is null) return null;
    size_t len = 0;
    while (h[len] != 0) len++;
    return h[0 .. len];
}

// Build path: ~/.local/share/ground/<prefix><key><suffix>
size_t buildGroundPath(ref char[512] buf, const(char)[] prefix, const(char)[] key, const(char)[] suffix) {
    auto home = getHome();
    if (home is null) return 0;
    size_t pos = 0;
    foreach (c; home) { if (pos < 510) buf[pos++] = c; }
    foreach (c; "/.local/share/ground/") { if (pos < 510) buf[pos++] = c; }
    foreach (c; prefix) { if (pos < 510) buf[pos++] = c; }
    foreach (c; key) { if (pos < 510) buf[pos++] = c; }
    foreach (c; suffix) { if (pos < 510) buf[pos++] = c; }
    buf[pos] = 0;
    return pos;
}

// Last segment of cwd path, safe for filenames (no slashes).
const(char)[] cwdLeaf(const(char)[] path) {
    if (path.length == 0) return "unknown";
    // Strip trailing slash
    while (path.length > 0 && path[$ - 1] == '/') path = path[0 .. $ - 1];
    // Find last slash
    size_t last = path.length;
    while (last > 0 && path[last - 1] != '/') last--;
    return path[last .. $];
}

// --- Called by Stop handler (has session ID) ---

// Kill the previous watcher for THIS session only.
void killSessionWatcher(const(char)[] sessionId) {
    __gshared char[512] pathBuf = 0;
    auto pLen = buildGroundPath(pathBuf, "watch-", sessionId, ".pid");
    if (pLen == 0) return;

    auto rf = fopen(&pathBuf[0], "r");
    if (rf is null) return;

    char[16] pidBuf = 0;
    auto n = fread(&pidBuf[0], 1, 15, rf);
    fclose(rf);

    int oldPid = 0;
    foreach (i; 0 .. n) {
        if (pidBuf[i] >= '0' && pidBuf[i] <= '9')
            oldPid = oldPid * 10 + (pidBuf[i] - '0');
        else break;
    }
    if (oldPid > 0)
        kill(oldPid, 15); // SIGTERM
}

// Write a claim file so the new watcher knows its session ID.
void writeWatchClaim(const(char)[] sessionId) {
    __gshared char[512] pathBuf = 0;
    auto pLen = buildGroundPath(pathBuf, "watch-claim-", sessionId, ".id");
    if (pLen == 0) return;

    auto f = fopen(&pathBuf[0], "w");
    if (f !is null) {
        fwrite(sessionId.ptr, 1, sessionId.length, f);
        fprintf(f, "\n");
        fclose(f);
    }
}

// --- Called by watcher (no session ID yet) ---

// Claim a session by reading a watch-claim-*.id file.
// Returns the session ID, or null if no claim found.
const(char)[] claimSession(const(char)[] cwd) {
    import matcher : indexOf;

    auto home = getHome();
    if (home is null) return null;

    // List claim files via ls (readdir on macOS links to 32-bit inode version from D)
    __gshared char[512] cmd = 0;
    size_t cp = 0;
    foreach (c; "ls ") { if (cp < 510) cmd[cp++] = c; }
    foreach (c; home) { if (cp < 510) cmd[cp++] = c; }
    foreach (c; "/.local/share/ground/watch-claim-*.id 2>/dev/null") { if (cp < 510) cmd[cp++] = c; }
    cmd[cp] = 0;

    auto pipe = popen(&cmd[0], "r");
    if (pipe is null) return null;

    __gshared char[512] lineBuf = 0;
    __gshared char[512] claimedPath = 0;
    __gshared char[128] sessionBuf = 0;

    while (true) {
        // Read one line (one file path per line)
        size_t lineLen = 0;
        while (lineLen < 511) {
            char[1] ch;
            if (fread(&ch[0], 1, 1, pipe) != 1) break;
            if (ch[0] == '\n') break;
            lineBuf[lineLen++] = ch[0];
        }
        if (lineLen == 0) break;
        lineBuf[lineLen] = 0;
        auto line = lineBuf[0 .. lineLen];

        // Try to claim by renaming to .claimed
        size_t rp = 0;
        foreach (c; line[0 .. lineLen - 3]) { if (rp < 510) claimedPath[rp++] = c; } // strip .id
        foreach (c; ".claimed") { if (rp < 510) claimedPath[rp++] = c; }
        claimedPath[rp] = 0;

        if (rename(&lineBuf[0], &claimedPath[0]) != 0)
            continue; // another watcher claimed it first

        // Read session ID from the claimed file
        auto f = fopen(&claimedPath[0], "r");
        if (f is null) continue;
        auto n = fread(&sessionBuf[0], 1, 127, f);
        fclose(f);
        remove(&claimedPath[0]); // clean up

        while (n > 0 && (sessionBuf[n-1] == '\n' || sessionBuf[n-1] == '\r')) n--;
        if (n == 0) continue;

        pclose(pipe);
        return sessionBuf[0 .. n];
    }

    pclose(pipe);
    return null;
}

// Write our PID to the session-keyed PID file.
void writePid(const(char)[] sessionId) {
    __gshared char[512] pathBuf = 0;
    auto pLen = buildGroundPath(pathBuf, "watch-", sessionId, ".pid");
    if (pLen == 0) return;

    auto wf = fopen(&pathBuf[0], "w");
    if (wf !is null) {
        fprintf(wf, "%d\n", getpid());
        fclose(wf);
    }
}

int handleWatch(int argc, const(char)** argv) {
    if (argc < 3) {
        fputs("usage: ground watch <cwd>\n", stderr);
        return 1;
    }

    import main : argLen;
    auto cwd = argv[2][0 .. argLen(argv[2])];

    auto sessionId = claimSession(cwd);
    if (sessionId is null) {
        fputs("ground watch: no claim file found\n", stderr);
        return 1;
    }

    writePid(sessionId);

    __gshared char[4096] batchBuf = 0;
    size_t batchLen = 0;

    int nextSleep = 2;

    while (true) {
        auto db = openDb();
        if (db !is null) {
            bool foundNew = false;
            bool urgent = false;

            // Reset to default each loop; adaptive ci-status may raise it.
            nextSleep = 2;

            while (true) {
                auto imm = readImmediateMessage(db, cwd, sessionId);
                if (imm.message is null) break;

                // Late-binding: ci-status resolves live. Uses the repo + branch
                // captured at push time (from the push's own stdout). No cwd anywhere.
                if (imm.name == "ci-status") {
                    import deferred : checkCIStatus;
                    import matcher : contains;
                    import adaptive : pickAdaptiveSleep;
                    import core.stdc.time : time;
                    if (imm.repo.length == 0 || imm.branch.length == 0) {
                        // Row predates the repo-keyed format — drop it.
                        markImmediateDelivered(db, imm.msgId, imm.projectContext, sessionId);
                        continue;
                    }
                    auto ciResult = checkCIStatus(imm.repo, imm.branch);
                    if (contains(ciResult, "in_progress")) {
                        // Adaptive backoff: stay quiet during the unlikely-done
                        // window, poll actively in the likely-done window.
                        auto elapsed = cast(long) time(null) - imm.pushTime;
                        nextSleep = pickAdaptiveSleep(elapsed, imm.p50, imm.p90);
                        break; // not terminal yet, try again next cycle
                    }
                    if (ciResult is null) {
                        markImmediateDelivered(db, imm.msgId, imm.projectContext, sessionId);
                        continue; // no CI runs after gate opened — no workflow exists
                    }
                    imm.message = ciResult;
                    if (contains(ciResult, "failure"))
                        urgent = true;
                }

                markImmediateDelivered(db, imm.msgId, imm.projectContext, sessionId);
                foundNew = true;

                // Append to batch: "ground: <message>\n"
                if (batchLen > 0 && batchLen < batchBuf.length) batchBuf[batchLen++] = '\n';
                foreach (c; "ground: ") { if (batchLen < batchBuf.length) batchBuf[batchLen++] = c; }
                foreach (c; imm.message) { if (batchLen < batchBuf.length) batchBuf[batchLen++] = c; }
            }

            sqlite3_close(db);

            if (foundNew && !urgent) {
                // Debounce: new messages arrived, wait 5s for more before delivering.
                sleep(5);
                continue;
            }

            // No new messages this cycle. If we accumulated anything, deliver now.
            if (batchLen > 0) {
                fwrite(&batchBuf[0], 1, batchLen, stderr);
                fputs("\n", stderr);
                return 2;
            }
        }
        sleep(nextSleep);
    }
}
