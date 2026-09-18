module watch;

// ground watch <cwd>
//
// Immediate delivery via asyncRewake. Polls the db every 2 seconds for
// immediate: attestations matching the project, writes what is pending to
// stderr and exits 2 — no timer, nothing held back. Claude Code's
// asyncRewake shows stderr as a system reminder and wakes the session.
//
// Spawned by PostToolUse, Stop and SessionStart:
// {"command":"ground watch $PWD","asyncRewake":true}
// Claude Code does NOT deduplicate async hooks
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
//   checkCIStatus(repo, branch) which calls `gh -R <repo> --branch <branch>`
//   and returns a CIQuery (see deferred.d), not a string. Four outcomes:
//     InProgress  — not terminal, retry next cycle at the adaptive interval
//     Terminal    — deliver it
//     NoWorkflow  — gh answered and there is genuinely no run; mark delivered
//                   so the row doesn't loop forever
//     Unavailable — gh could not be run or exited non-zero; DELIVERED, not
//                   dropped. "I could not find out" is the honest answer to
//                   "what happened to my CI"
//
//   These were once a single null, and the null was read as NoWorkflow — so an
//   expired token or a dropped connection silently discarded the user's CI
//   result. Empty output cannot tell "nothing to report" from "the query
//   failed"; gh's exit status can, and pclose carries it.
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
//   [ ] Session-scoped deferred (`readDeferredMessage`) → session-keyed
//       immediate removes the need to read the deferred queue at Stop.
//   [ ] Project-scoped deferred (`readProjectDeferredMessage`) → either
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
//   [ ] claimSession's glob is not session-scoped. It lists watch-claim-*.id
//       across ALL sessions and takes the first it can rename, so a watcher
//       spawned for session A can claim session B — A is left unwatched with
//       a stale pid file, and B's pid file names a watcher running in A's cwd.
//       A watcher holding a dead session's claim can never be reached again,
//       because killSessionWatcher is only ever called by that session's own
//       Stop, so orphans accumulate at ppid 1. Nothing unlinks watch-*.pid.
//
//       Root cause is one discarded argument: asyncRewake spawns
//       `ground watch $PWD` from static settings.json, so the session id the
//       spawner holds never reaches the spawned process. The claim file, the
//       global glob, the rename-as-mutex and the pid file are all scaffolding
//       to rebuild it. main.d dispatches `watch` before readStdin, so nobody
//       has tested whether the hook JSON (which carries session_id) is even
//       delivered to an asyncRewake command — if it is, all of this deletes
//       itself.

import db : sqlite3, sqlite3_close, openDb, ZBuf;
import immediate : readImmediateMessage, markImmediateDelivered;
import core.stdc.stdio : stderr, fputs, fwrite, FILE;

extern (C) {
    uint sleep(uint seconds);
    int getpid();
    int getppid();
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

// How long a dispatched run may take to appear in the listing before its
// absence is reported as an absence.
enum DISPATCH_APPEAR_SEC = 60;

// The receipt is what makes delivery once rather than forever: without it the
// next read returns the same row, and the loop that reads it does not end. So
// a receipt that did not land stops the drain and says so.
private bool receipt(sqlite3* db, const(char)[] msgId, const(char)[] projectContext,
                     const(char)[] sessionId, const(char)[] mark) {
    if (markImmediateDelivered(db, msgId, projectContext, sessionId, mark)) return true;
    import exec : emitError;
    emitError("watch.receipt",
              "the delivery receipt did not land, so this message would be handed over without end",
              0, 1, "", "watch", "", "", cast(string) msgId);
    return false;
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

// Everything a pid file can hold that is not a live pid reaches the caller
// as 0, and 0 is never signalled: kill(0, SIGTERM) hits the whole group.
int parsePid(const(char)[] text) {
    int pid = 0;
    foreach (c; text) {
        if (c < '0' || c > '9') break;
        pid = pid * 10 + (c - '0');
    }
    return pid;
}

// A watcher's parent is claude. ppid 1 means the session it would wake is
// gone, and nothing will ever kill it — killSessionWatcher runs from that
// session's own Stop, which will not happen again.
bool orphaned(int ppid) { return ppid <= 1; }

// One watcher per tree. `killSessionWatcher` kills by session id, and a watcher
// on a ritual tree takes its id from `claimSession` when stdin carries none, so
// the kill misses any that claimed something else.
private const(char)[] treeKey(const(char)[] cwd) {
    size_t start;
    foreach (i, c; cwd) if (c == '/') start = i + 1;
    return cwd[start .. $];
}

// Whether the pid in the tree file still holds the tree. kill(pid, 0) answers 0
// for a process a Stop has just signalled and that has not yet gone, and the
// replacement that Stop spawned was refusing itself on that answer.
bool treeHeld(bool alive, bool endedInRecord) {
    return alive && !endedInRecord;
}

// Whether one more message, its prefix and its separator fit the batch whole.
bool batchFits(size_t used, size_t cap, size_t message) {
    return used + 1 + "ground: ".length + message <= cap;
}

private bool pidAlive(long pid) {
    return pid > 0 && kill(cast(int) pid, 0) == 0;
}

// 0 when this process now watches that tree. Otherwise the pid of the live
// watcher that already does, so the refusal can name it.
int claimTree(const(char)[] cwd, int myPid) {
    __gshared char[512] pathBuf = 0;
    auto pLen = buildGroundPath(pathBuf, "watch-tree-", treeKey(cwd), ".pid");
    if (pLen == 0) return 0;

    auto rf = fopen(&pathBuf[0], "r");
    if (rf !is null) {
        char[16] pidBuf = 0;
        auto n = fread(&pidBuf[0], 1, 15, rf);
        fclose(rf);
        auto held = parsePid(pidBuf[0 .. n]);
        // Signal 0 tests for existence without delivering anything.
        if (held > 0 && held != myPid && kill(held, 0) == 0) {
            import lifecycle : pidEnded;
            bool ended = false;
            auto db = openDb();
            if (db !is null) {
                ended = pidEnded(db, held);
                sqlite3_close(db);
            }
            if (treeHeld(true, ended)) return held;
        }
    }

    auto wf = fopen(&pathBuf[0], "w");
    if (wf is null) return 0;
    fprintf(wf, "%d\n", myPid);
    fclose(wf);
    return 0;
}

void releaseTree(const(char)[] cwd) {
    __gshared char[512] pathBuf = 0;
    if (buildGroundPath(pathBuf, "watch-tree-", treeKey(cwd), ".pid") == 0) return;
    remove(&pathBuf[0]);
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

    auto oldPid = parsePid(pidBuf[0 .. n]);
    if (oldPid > 0) {
        kill(oldPid, 15); // SIGTERM

        // The one it killed cannot write its own ending, so this writes it.
        import lifecycle : processKilled;
        import core.stdc.time : time;
        auto db = openDb();
        if (db !is null) {
            __gshared ZBuf why;
            why.reset();
            why.put("killed by a stop of session ");
            why.put(sessionId);
            processKilled(db, oldPid, why.slice(), cast(long) time(null));
            sqlite3_close(db);
        }
    }

    // The file outlives the watcher it named. Left in place it accumulates,
    // and the number it holds is eventually handed to something else.
    remove(&pathBuf[0]);
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

// Pipeline health is NOT asked here. A watcher's pid says nothing useful
// about whether messages are being delivered: stop.d SIGTERMs the pid before
// it would be read, watch exits 2 by design after every batch, nothing ever
// unlinks watch-*.pid, and a watcher can hold another session's claim. The
// honest signal is undelivered work — see immediate.countStaleExecForSession.

// Write our PID to the session-keyed PID file.
void writePid(const(char)[] sessionId, const(char)[] prefix = "watch-") {
    __gshared char[512] pathBuf = 0;
    auto pLen = buildGroundPath(pathBuf, prefix, sessionId, ".pid");
    if (pLen == 0) return;

    auto wf = fopen(&pathBuf[0], "w");
    if (wf !is null) {
        fprintf(wf, "%d\n", getpid());
        fclose(wf);
    }
}

// The watcher unlinks its own file on the way out. Left behind, the number
// it holds is eventually reissued and killSessionWatcher signals a stranger.
void removePid(const(char)[] sessionId, const(char)[] prefix = "watch-") {
    __gshared char[512] pathBuf = 0;
    if (buildGroundPath(pathBuf, prefix, sessionId, ".pid") == 0) return;
    remove(&pathBuf[0]);
}

enum BOOK_COMMAND = q"EOS
# the asyncRewake watcher
ground watch $PWD
EOS";

int handleWatch(int argc, const(char)** argv) {
    if (argc < 3) {
        fputs("usage: ground watch <cwd>\n", stderr);
        return 1;
    }

    import main : argLen;
    import core.stdc.time : time;
    import lifecycle : processStarted, processSeen, processEnded;
    auto cwd = argv[2][0 .. argLen(argv[2])];
    auto tree = treeKey(cwd);
    int myPid = getpid();
    int myPpid = getppid();

    // A second watcher on a tree is a second walker. Refused, it says so: the
    // session it was spawned for is then watched by the one holding the tree,
    // or by nobody, and the record is how that is told apart later.
    auto holder = claimTree(cwd, myPid);
    if (holder != 0) {
        auto rdb = openDb();
        if (rdb !is null) {
            auto now = cast(long) time(null);
            auto id = processStarted(rdb, "watch", myPid, myPpid, "", tree, now);
            __gshared ZBuf why;
            why.reset();
            why.put("refused: the tree is watched by pid ");
            why.putUint(cast(ulong) holder);
            processEnded(rdb, id, why.slice(), 0, now);
            lifecycleNote(rdb, "", "warn", why.slice(), tree, myPid, 0, 0, now);
            sqlite3_close(rdb);
        }
        return 0;
    }

    // The model's mark. The operator is not reached from here — exit 0 renders
    // systemMessage but sends stdout to the debug log, so a second watcher for
    // the screen was built, measured, and deleted. MessageDisplay carries it.
    enum mark = "delivered:";

    // Two watchers cannot share the claim mechanism: the glob is not
    // session-scoped and the rename is a mutex, so the second one steals the
    // first one's session. Stdin carries session_id if it is piped at all.
    const(char)[] sessionId = null;
    {
        import main : readStdin;
        import parse : extractJsonString;
        auto input = readStdin();
        if (input !is null) {
            __gshared char[128] sidBuf = 0;
            sessionId = extractJsonString(input, `"session_id"`, &sidBuf[0], sidBuf.length);
        }
    }

    if (sessionId is null) sessionId = claimSession(cwd);
    if (sessionId is null) {
        // asyncRewake surfaces stderr on exit 2 only, so this line reached
        // nobody for as long as it has existed.
        import exec : emitError;
        emitError("watch.claim", "no claim file to take, so this watcher has no session",
                  0, 1, "", "watch", "", "", "");
        auto rdb = openDb();
        if (rdb !is null) {
            auto now = cast(long) time(null);
            auto id = processStarted(rdb, "watch", myPid, myPpid, "", tree, now);
            enum why = "no claim file to take, so this watcher has no session";
            processEnded(rdb, id, why, 0, now);
            lifecycleNote(rdb, "", "warn", why, tree, myPid, 0, 0, now);
            sqlite3_close(rdb);
        }
        return 1;
    }

    enum pidPrefix = "watch-";
    writePid(sessionId, pidPrefix);

    // The record this watcher keeps of itself, from here to its ending.
    long record = 0;
    auto startedAt = cast(long) time(null);
    {
        auto rdb = openDb();
        if (rdb !is null) {
            record = processStarted(rdb, "watch", myPid, myPpid, sessionId, tree, startedAt);
            import hooktiming : releaseDeadClaims;
            auto freed = releaseDeadClaims(rdb, &pidAlive);
            if (freed > 0) {
                __gshared ZBuf why;
                why.reset();
                why.put("freed timing rows claimed by dead watchers: ");
                why.putUint(cast(ulong) freed);
                lifecycleNote(rdb, sessionId, "warn", why.slice(), tree, myPid, 0, 0, startedAt);
            }
            sqlite3_close(rdb);
        }
    }
    long polls = 0;

    // Where this session reports, asked once: the place does not move.
    import controls : dsnHere;
    auto dsn = dsnHere(cwd);
    long shipBackoffUntil = 0;

    import immediate : MESSAGE_CAP;
    __gshared char[4 * MESSAGE_CAP] batchBuf = 0;
    size_t batchLen = 0;

    int nextSleep = 2;

    while (true) {
        auto db = openDb();
        if (db !is null) {
            // Reset to default each loop; adaptive ci-status may raise it.
            nextSleep = 2;
            polls++;
            processSeen(db, record, cast(long) time(null));

            // The watcher does not walk. `ground drive` was built for exactly
            // the case this block was added for — an agent inside the agentic
            // loop for an hour — and two of them ran every rite twice.

            bool stuck = false;

            while (true) {
                auto imm = readImmediateMessage(db, cwd, sessionId, mark);
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
                        if (!receipt(db, imm.msgId, imm.projectContext, sessionId, mark)) {
                            stuck = true;
                            break;
                        }
                        continue;
                    }
                    import deferred : CIQuery;
                    auto ci = checkCIStatus(imm.repo, imm.branch);
                    if (ci.kind == CIQuery.InProgress) {
                        // Parked, not stopped: breaking here held back every
                        // message written after this row.
                        import immediate : parkImmediate;
                        auto now = cast(long) time(null);
                        auto wait = pickAdaptiveSleep(now - imm.pushTime, imm.p50, imm.p90);
                        nextSleep = wait;
                        parkImmediate(db, imm.msgId, now + wait);
                        continue;
                    }
                    if (ci.kind == CIQuery.NoWorkflow) {
                        // gh answered and there is genuinely no run to report.
                        if (!receipt(db, imm.msgId, imm.projectContext, sessionId, mark)) {
                            stuck = true;
                            break;
                        }
                        continue;
                    }
                    // Unavailable falls through and is DELIVERED, not dropped.
                    // "I could not find out" is the honest answer to "what
                    // happened to my CI" — silently discarding the row is not.
                    imm.message = ci.text;
                }

                // A dispatch is over, but the run it sent is not. This row is
                // the only record that an outcome is still owed.
                if (imm.name == "dispatch") {
                    import deferred : checkRunByToken, CIQuery;
                    import adaptive : pickAdaptiveSleep;
                    import core.stdc.time : time;
                    if (imm.repo.length == 0 || imm.token.length == 0) {
                        if (!receipt(db, imm.msgId, imm.projectContext, sessionId, mark)) {
                            stuck = true;
                            break;
                        }
                        continue;
                    }
                    auto run = checkRunByToken(imm.repo, imm.token);
                    if (run.kind == CIQuery.InProgress) {
                        import immediate : parkImmediate;
                        auto now = cast(long) time(null);
                        auto wait = pickAdaptiveSleep(now - imm.pushTime, imm.p50, imm.p90);
                        nextSleep = wait;
                        parkImmediate(db, imm.msgId, now + wait);
                        continue;
                    }
                    // A run does not appear in the listing the instant it is
                    // dispatched, and "not there yet" is not "not coming".
                    if (run.kind == CIQuery.NoWorkflow) {
                        import immediate : parkImmediate;
                        auto now = cast(long) time(null);
                        if (now - imm.pushTime < DISPATCH_APPEAR_SEC) {
                            nextSleep = 2;
                            parkImmediate(db, imm.msgId, now + 2);
                            continue;
                        }
                        // Long past appearing. Say so rather than drop it.
                        imm.message = "no run carries the name ground gave it";
                    }
                    else imm.message = run.text;

                }

                // A message the batch cannot hold whole is not receipted: it
                // is delivered whole on the next pass, after this batch.
                if (!batchFits(batchLen, batchBuf.length, imm.message.length)) break;

                // The receipt comes before the batch on purpose: a message
                // written to stderr without one is delivered again on the next
                // pass, and the operator reads it twice.
                if (!receipt(db, imm.msgId, imm.projectContext, sessionId, mark)) {
                    stuck = true;
                    break;
                }

                // Append to batch: "ground: <message>\n"
                if (batchLen > 0) batchBuf[batchLen++] = '\n';
                foreach (c; "ground: ") batchBuf[batchLen++] = c;
                foreach (c; imm.message) batchBuf[batchLen++] = c;
            }

            // "nothing can wait, and everything is urgent, at the same level
            // of predictable urgency"
            if (batchLen > 0) {
                // Counted, not parsed: every message went in as one line.
                long delivered = 1;
                foreach (c; batchBuf[0 .. batchLen]) if (c == '\n') delivered++;
                ending(db, record, sessionId, tree, myPid, "delivered and exited 2",
                       delivered, polls, startedAt, "info");
                sqlite3_close(db);
                removePid(sessionId, pidPrefix);
                releaseTree(cwd);
                fwrite(&batchBuf[0], 1, batchLen, stderr);
                fputs("\n", stderr);
                return 2;
            }

            // A receipt that cannot be written is not something to retry every
            // two seconds. This watcher stops; the next hook spawns another,
            // and if the db is still broken that one says so once as well.
            if (stuck) {
                ending(db, record, sessionId, tree, myPid, "stuck: a receipt would not land",
                       0, polls, startedAt, "warn");
                sqlite3_close(db);
                removePid(sessionId, pidPrefix);
                releaseTree(cwd);
                return 1;
            }

            // Nothing to hand over this pass, so the pass is spent shipping:
            // what the hooks left in the outbox, and the timing rows.
            auto now = cast(long) time(null);

            // The orgs' Actions minutes, asked when the last asking is old.
            // Asked from here and from no hook: the asking is a round trip.
            {
                import minutes : refreshDue;
                refreshDue(db, sessionId, now);
            }
            if (dsn.length > 0 && now >= shipBackoffUntil) {
                if (!shipPass(db, sessionId, dsn, myPid, now)) shipBackoffUntil = now + SHIP_BACKOFF_SEC;
            }
            sqlite3_close(db);
        }

        // The session that spawned this watcher is gone, and only that
        // session's Stop ever calls killSessionWatcher. Without this the
        // loop runs until the machine reboots.
        if (orphaned(getppid())) {
            auto odb = openDb();
            if (odb !is null) {
                ending(odb, record, sessionId, tree, myPid, "orphaned: the session is gone",
                       0, polls, startedAt, "info");
                sqlite3_close(odb);
            }
            removePid(sessionId, pidPrefix);
            releaseTree(cwd);
            return 0;
        }

        sleep(nextSleep);
    }
}

// How long a pass that could not post waits before trying again. A refusal
// every two seconds would be the same refusal, said thirty times a minute.
enum SHIP_BACKOFF_SEC = 60;

// The ending, in the record and in the outbox. The outbox item is the next
// watcher's to ship; this one is leaving.
private void ending(sqlite3* db, long record, const(char)[] sessionId, const(char)[] tree,
                    int pid, const(char)[] how, long delivered, long polls,
                    long startedAt, const(char)[] level) {
    import core.stdc.time : time;
    import lifecycle : processEnded;
    auto now = cast(long) time(null);
    processEnded(db, record, how, delivered, now);
    lifecycleNote(db, sessionId, level, how, tree, pid, delivered, polls, now, now - startedAt);
}

// One outbox item about a watcher: what became of it, for whom, and how much
// it handed over. The tree is a directory's name, never a path.
private void lifecycleNote(sqlite3* db, const(char)[] sessionId, const(char)[] level,
                           const(char)[] how, const(char)[] tree, int pid,
                           long delivered, long polls, long now, long seconds = 0) {
    import sentry : openItem;
    import outbox : leave;

    __gshared ZBuf body_;
    body_.reset();
    body_.put("watcher ");
    body_.put(how);

    auto it = openItem(now, sessionId.length > 0 ? sessionId : tree, level, body_.slice());
    it.str("kind", "watch");
    it.str("session", sessionId);
    it.str("tree", tree);
    it.num("pid", pid);
    it.num("delivered", delivered);
    it.num("polls", polls);
    it.num("seconds", seconds);
    it.close();
    cast(void) leave(db, sessionId, level, it, now);
}

// Whatever is pending for this session, posted. False when a post did not
// land, which is what the caller backs off on. Nothing pending is true.
private bool shipPass(sqlite3* db, const(char)[] sessionId, const(char)[] dsn, int pid, long now) {
    import sentry : Batch, envelopeInto, postText, LOG_TYPE, LOG_CONTENT, METRIC_TYPE, METRIC_CONTENT;
    import outbox : pendingInto, shipped;
    import hooktiming : claimTiming, claimedInto, claimResolved;
    import db : versionString;
    import exec : emitError;

    __gshared Batch!() logs;
    __gshared char[280_000] envelope = void;
    logs = Batch!().init;
    auto last = pendingInto(db, sessionId, logs);
    if (last > 0) {
        auto n = envelopeInto(logs, dsn, LOG_CONTENT, LOG_TYPE, envelope[]);
        auto r = postText(dsn, envelope[0 .. n]);
        if (r.status != 200) {
            shipFailed(sessionId, "the outbox post", r.status, r.why());
            return false;
        }
        shipped(db, sessionId, last, now);
    }

    __gshared Batch!() metrics;
    metrics = Batch!().init;
    if (claimTiming(db, pid) > 0) {
        claimedInto(db, pid, versionString(), metrics);
        auto n = envelopeInto(metrics, dsn, METRIC_CONTENT, METRIC_TYPE, envelope[]);
        auto r = postText(dsn, envelope[0 .. n]);
        auto landed = r.status == 200;
        claimResolved(db, pid, landed, now);
        if (!landed) {
            shipFailed(sessionId, "the timing post", r.status, r.why());
            return false;
        }
    }
    return true;
}

// A post that did not land, said once per backoff, with what sentry or
// libcurl said about it.
private void shipFailed(const(char)[] sessionId, const(char)[] what, int status, const(char)[] why) {
    import exec : emitError;
    __gshared char[400] said = 0;
    size_t n;
    void put(const(char)[] s) { foreach (c; s) if (n < said.length) said[n++] = c; }
    put(what);
    if (status > 0) {
        put(" was answered with HTTP ");
        char[3] d = [cast(char)('0' + status / 100 % 10), cast(char)('0' + status / 10 % 10),
                     cast(char)('0' + status % 10)];
        put(d[]);
    } else {
        put(" got no answer: ");
        put(why);
    }
    put(" — the rows stay pending, and the next try is in a minute");
    emitError("watch.ship", cast(string) said[0 .. n], 0, -1, cast(string) sessionId,
              "watch", "", "", "");
}
