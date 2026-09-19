module sky;

// ground sky <cwd>
// "the first part of the hear me out is renaming ground watch to ground sky"
//
// Immediate delivery via asyncRewake. Polls the db every 2 seconds for
// immediate: attestations matching the project, writes what is pending to
// stderr and exits 2 — no timer, nothing held back. Claude Code's
// asyncRewake shows stderr as a system reminder and wakes the session.
//
// A pass with nothing to deliver is spent as the courier: the outbox and the
// timing rows to sentry, and the hook rows to the QNTX node (stream.d). A
// hook opens no socket; this is the one process of a session that does.
//
// Spawned by PostToolUse, Stop and SessionStart:
// {"command":"ground sky $PWD","asyncRewake":true,"timeout":86400}
// Claude Code does NOT deduplicate async hooks
// (confirmed by docs), so we handle it ourselves via PID files.
//
// The timeout is enforced on an asyncRewake hook, and defaults to 600. The
// record showed it 2026-09-18: four watchers, each silent after 597 to 600
// seconds of polling, none ended, no process. An idle session was then
// unwatched until its next hook. A day is the ceiling now.
//
// Session identity:
//   Stdin carries session_id and hook_event_name. The Stop handler also
//   writes a claim file sky-claim-<sessionId>.id, which a watcher with no
//   stdin claims (atomic rename) to learn its session ID. A Stop's watcher
//   replaces its own session's previous watcher itself (see claimTree) —
//   watchers from different sessions never interfere with each other.
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
//       the row. sky.d picks sleep based on elapsed-vs-percentile bracket
//       (see source/adaptive.d, CTFE-tested).
//   [x] Backoff during long-running CI: same mechanism.
//   [ ] claimSession's glob is not session-scoped. It lists sky-claim-*.id
//       across ALL sessions and takes the first it can rename, so a watcher
//       spawned for session A can claim session B. The hook JSON does reach
//       an asyncRewake command — every live row in the process table names
//       its session from stdin — so claimSession is the path nothing takes,
//       and the claim file with it.

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

// What the record calls this process, and the files it holds a tree and a
// session by. Rows written before the rename say watch.
enum KIND = "sky";
enum TREE_FILE = "sky-tree-";
enum CLAIM_FILE = "sky-claim-";

// The receipt is what makes delivery once rather than forever: without it the
// next read returns the same row, and the loop that reads it does not end. So
// a receipt that did not land stops the drain and says so.
private bool receipt(sqlite3* db, const(char)[] msgId, const(char)[] projectContext,
                     const(char)[] sessionId, const(char)[] mark) {
    if (markImmediateDelivered(db, msgId, projectContext, sessionId, mark)) return true;
    import exec : emitError;
    emitError("sky.receipt",
              "the delivery receipt did not land, so this message would be handed over without end",
              0, 1, "", KIND, "", "", cast(string) msgId);
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
// gone, and nothing will ever replace it — that happens at the session's
// own Stop, which will not happen again.
bool orphaned(int ppid) { return ppid <= 1; }

// One watcher per tree. A replacement is by session id, and a watcher on a
// ritual tree takes its id from `claimSession` when stdin carries none, so
// the replacement misses any that claimed something else.
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

// Whether a watcher takes the tree from the one holding it. Only a Stop's
// watcher replaces, and only its own session's watcher: `ground stop` and
// `ground sky` are two hooks run together, with no order between them, so
// the replacing is done by the one process that is the replacement.
bool takesOver(bool stopEvent, bool holderIsMine) {
    return stopEvent && holderIsMine;
}

// Whether the holder is gone with its row still open: it could not write its
// own ending, and the one that finds it so writes it.
bool diedUnsaid(bool alive, bool endedInRecord) {
    return !alive && !endedInRecord;
}

// Whether one more message, its prefix and its separator fit the batch whole.
bool batchFits(size_t used, size_t cap, size_t message) {
    return used + 1 + "ground: ".length + message <= cap;
}

private bool pidAlive(long pid) {
    return pid > 0 && kill(cast(int) pid, 0) == 0;
}

// 0 when this process now watches that tree. Otherwise the pid of the live
// watcher that already does, so the refusal can name it. A Stop's watcher
// replaces its own session's holder on the way: the kill and the record of
// it are written here, by the process that takes the tree.
int claimTree(const(char)[] cwd, int myPid, const(char)[] sessionId, bool stopEvent) {
    __gshared char[512] pathBuf = 0;
    auto pLen = buildGroundPath(pathBuf, TREE_FILE, treeKey(cwd), ".pid");
    if (pLen == 0) return 0;

    auto rf = fopen(&pathBuf[0], "r");
    if (rf !is null) {
        char[16] pidBuf = 0;
        auto n = fread(&pidBuf[0], 1, 15, rf);
        fclose(rf);
        auto held = parsePid(pidBuf[0 .. n]);
        if (held > 0 && held != myPid) {
            import lifecycle : pidEnded, whoOfPid, processKilled;
            import core.stdc.time : time;
            // Signal 0 tests for existence without delivering anything.
            bool alive = kill(held, 0) == 0;
            bool ended = false;
            bool mine = false;
            auto db = openDb();
            if (db !is null) {
                ended = pidEnded(db, held);
                char[128] who;
                mine = sessionId.length > 0 && whoOfPid(db, held, who) == sessionId;
            }
            if (treeHeld(alive, ended) && !takesOver(stopEvent, mine)) {
                if (db !is null) sqlite3_close(db);
                return held;
            }
            if (treeHeld(alive, ended)) kill(held, 15); // SIGTERM
            if (db !is null) {
                __gshared ZBuf why;
                why.reset();
                if (treeHeld(alive, ended)) {
                    why.put("replaced at a stop by pid ");
                    why.putUint(cast(ulong) myPid);
                    processKilled(db, held, why.slice(), cast(long) time(null));
                } else if (diedUnsaid(alive, ended)) {
                    why.put("gone without a word, found so by pid ");
                    why.putUint(cast(ulong) myPid);
                    processKilled(db, held, why.slice(), cast(long) time(null));
                }
                sqlite3_close(db);
            }
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
    if (buildGroundPath(pathBuf, TREE_FILE, treeKey(cwd), ".pid") == 0) return;
    remove(&pathBuf[0]);
}

// --- Called by Stop handler (has session ID) ---

// Write a claim file so the new watcher knows its session ID.
void writeWatchClaim(const(char)[] sessionId) {
    __gshared char[512] pathBuf = 0;
    auto pLen = buildGroundPath(pathBuf, CLAIM_FILE, sessionId, ".id");
    if (pLen == 0) return;

    auto f = fopen(&pathBuf[0], "w");
    if (f !is null) {
        fwrite(sessionId.ptr, 1, sessionId.length, f);
        fprintf(f, "\n");
        fclose(f);
    }
}

// --- Called by watcher (no session ID yet) ---

// Claim a session by reading a sky-claim-*.id file.
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
    foreach (c; "/.local/share/ground/") { if (cp < 510) cmd[cp++] = c; }
    foreach (c; CLAIM_FILE) { if (cp < 510) cmd[cp++] = c; }
    foreach (c; "*.id 2>/dev/null") { if (cp < 510) cmd[cp++] = c; }
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
// about whether messages are being delivered: watch exits 2 by design after
// every batch, and a watcher can hold another session's claim. The honest
// signal is undelivered work — see immediate.countStaleExecForSession.

enum BOOK_COMMAND = q"EOS
# the asyncRewake watcher, with "timeout": 86400 on its hook entry
ground sky $PWD
EOS";

int handleSky(int argc, const(char)** argv) {
    if (argc < 3) {
        fputs("usage: ground sky <cwd>\n", stderr);
        return 1;
    }

    import main : argLen;
    import core.stdc.time : time;
    import lifecycle : processStarted, processSeen, processEnded;
    auto cwd = argv[2][0 .. argLen(argv[2])];
    auto tree = treeKey(cwd);
    int myPid = getpid();
    int myPpid = getppid();

    // The model's mark. The operator is not reached from here — exit 0 renders
    // systemMessage but sends stdout to the debug log, so a second watcher for
    // the screen was built, measured, and deleted. MessageDisplay carries it.
    enum mark = "delivered:";

    // Two watchers cannot share the claim mechanism: the glob is not
    // session-scoped and the rename is a mutex, so the second one steals the
    // first one's session. Stdin carries session_id if it is piped at all,
    // and the event, which says whether this watcher is a replacement.
    const(char)[] sessionId = null;
    const(char)[] event = "";
    size_t stdinBytes = 0;
    bool stopEvent = false;
    {
        import main : readStdin;
        import parse : extractJsonString;
        auto input = readStdin();
        if (input !is null) {
            stdinBytes = input.length;
            __gshared char[128] sidBuf = 0;
            sessionId = extractJsonString(input, `"session_id"`, &sidBuf[0], sidBuf.length);
            __gshared char[32] evBuf = 0;
            auto ev = extractJsonString(input, `"hook_event_name"`, &evBuf[0], evBuf.length);
            if (ev !is null) event = ev;
            stopEvent = ev == "Stop";
        }
    }

    // A second watcher on a tree is a second walker. Refused, it says so: the
    // session it was spawned for is then watched by the one holding the tree,
    // or by nobody, and the record is how that is told apart later.
    auto holder = claimTree(cwd, myPid, sessionId, stopEvent);
    if (holder != 0) {
        auto rdb = openDb();
        if (rdb !is null) {
            auto now = cast(long) time(null);
            auto id = processStarted(rdb, KIND, myPid, myPpid, sessionId, tree, now);
            __gshared ZBuf why;
            why.reset();
            why.put("refused: the tree is watched by pid ");
            why.putUint(cast(ulong) holder);
            // What this one was spawned with, since a refusal with no session
            // is the record's only way to say what stdin carried.
            why.put("; spawned at ");
            why.put(event.length > 0 ? event : "no event");
            why.put(" with ");
            why.putUint(cast(ulong) stdinBytes);
            why.put(" bytes on stdin");
            processEnded(rdb, id, why.slice(), 0, now);
            lifecycleNote(rdb, sessionId, "warn", why.slice(), tree, myPid, 0, 0, now);
            sqlite3_close(rdb);
        }
        return 0;
    }

    if (sessionId is null) sessionId = claimSession(cwd);
    if (sessionId is null) {
        // asyncRewake surfaces stderr on exit 2 only, so this line reached
        // nobody for as long as it has existed.
        import exec : emitError;
        emitError("sky.claim", "no claim file to take, so this watcher has no session",
                  0, 1, "", KIND, "", "", "");
        auto rdb = openDb();
        if (rdb !is null) {
            auto now = cast(long) time(null);
            auto id = processStarted(rdb, KIND, myPid, myPpid, "", tree, now);
            enum why = "no claim file to take, so this watcher has no session";
            processEnded(rdb, id, why, 0, now);
            lifecycleNote(rdb, "", "warn", why, tree, myPid, 0, 0, now);
            sqlite3_close(rdb);
        }
        return 1;
    }

    // The record this watcher keeps of itself, from here to its ending.
    long record = 0;
    auto startedAt = cast(long) time(null);
    {
        auto rdb = openDb();
        if (rdb !is null) {
            record = processStarted(rdb, KIND, myPid, myPpid, sessionId, tree, startedAt);
            import hooktiming;
            import outbox;
            import stream;
            auto freed = hooktiming.releaseDeadClaims(rdb, &pidAlive);
            auto freedItems = outbox.releaseDeadClaims(rdb, &pidAlive);
            auto freedRows = stream.releaseDeadClaims(rdb, &pidAlive);
            if (freed > 0 || freedItems > 0 || freedRows > 0) {
                __gshared ZBuf why;
                why.reset();
                why.put("freed rows claimed by dead watchers: timing ");
                why.putUint(cast(ulong) freed);
                why.put(", outbox ");
                why.putUint(cast(ulong) freedItems);
                why.put(", stream ");
                why.putUint(cast(ulong) freedRows);
                lifecycleNote(rdb, sessionId, "warn", why.slice(), tree, myPid, 0, 0, startedAt);
            }
            sqlite3_close(rdb);
        }
    }
    long polls = 0;

    // Where this session reports, asked once: the place does not move.
    import controls : dsnHere, qntxNode;
    auto dsn = dsnHere(cwd);
    long shipBackoffUntil = 0;

    // "tomorrow i want to send the exact same data to both our local sqlite and also qntx at the same time"
    // The node and its token, read once: a token that changes is a sky that
    // is respawned at the next hook anyway. No node named is no stream, and
    // a node named with no token to read is said once and is no stream.
    import attest : qntxToken;
    const(char)[] streamToken = qntxNode.url.length > 0 ? qntxToken(qntxNode.token) : null;
    if (qntxNode.url.length > 0 && streamToken.length == 0) {
        import exec : emitError;
        emitError("sky.stream", "the qntx block names a node but its token file holds nothing; the stream waits",
                  0, -1, cast(string) sessionId, KIND, "", "", cast(string) qntxNode.token);
    }
    long streamBackoffUntil = 0;
    long streamed = 0;

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
                // the only record that an outcome is still owed. One the
                // driver already found is handed over as it stands.
                if (imm.name == "dispatch" && !imm.resolved) {
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
                       delivered, polls, startedAt, "info", streamed);
                sqlite3_close(db);
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
                       0, polls, startedAt, "warn", streamed);
                sqlite3_close(db);
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
            // The hook rows, to the node, TAKE at a time. A pass the node did
            // not take waits out the same minute the sentry post does.
            if (streamToken.length > 0 && now >= streamBackoffUntil) {
                import stream : streamPass;
                int last;
                if (!streamPass(db, qntxNode.url, streamToken, myPid, now, last, streamed)) {
                    streamBackoffUntil = now + SHIP_BACKOFF_SEC;
                    streamFailed(sessionId, last);
                }
            }
            sqlite3_close(db);
        }

        // The session that spawned this watcher is gone, and only that
        // session's Stop ever replaces it. Without this the loop runs until
        // the machine reboots.
        if (orphaned(getppid())) {
            auto odb = openDb();
            if (odb !is null) {
                ending(odb, record, sessionId, tree, myPid, "orphaned: the session is gone",
                       0, polls, startedAt, "info", streamed);
                sqlite3_close(odb);
            }
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
                    long startedAt, const(char)[] level, long streamed = 0) {
    import core.stdc.time : time;
    import lifecycle : processEnded;
    auto now = cast(long) time(null);
    processEnded(db, record, how, delivered, now);
    lifecycleNote(db, sessionId, level, how, tree, pid, delivered, polls, now, now - startedAt, streamed);
}

// One outbox item about a watcher: what became of it, for whom, how much it
// handed over, and how many rows it carried to the node. The tree is a
// directory's name, never a path.
private void lifecycleNote(sqlite3* db, const(char)[] sessionId, const(char)[] level,
                           const(char)[] how, const(char)[] tree, int pid,
                           long delivered, long polls, long now, long seconds = 0,
                           long streamed = 0) {
    import sentry : openItem;
    import outbox : leave;

    __gshared ZBuf body_;
    body_.reset();
    body_.put("watcher ");
    body_.put(how);

    auto it = openItem(now, sessionId.length > 0 ? sessionId : tree, level, body_.slice());
    it.str("kind", KIND);
    it.str("session", sessionId);
    it.str("tree", tree);
    it.num("pid", pid);
    it.num("delivered", delivered);
    it.num("polls", polls);
    it.num("seconds", seconds);
    it.num("streamed", streamed);
    // What the stream still owes the node as this one leaves, and what the
    // node refused for good.
    import stream : standing;
    auto s = standing(db);
    it.num("stream_pending", s.pending);
    it.num("stream_refused", s.refused);
    it.close();
    cast(void) leave(db, sessionId, level, it, now);
}

// Whatever is pending for this session, posted. False when a post did not
// land, which is what the caller backs off on. Nothing pending is true.
private bool shipPass(sqlite3* db, const(char)[] sessionId, const(char)[] dsn, int pid, long now) {
    import sentry : Batch, envelopeInto, postText, LOG_TYPE, LOG_CONTENT, METRIC_TYPE, METRIC_CONTENT;
    import outbox;
    import hooktiming;
    import db : versionString;
    import exec : emitError;

    __gshared Batch!() logs;
    __gshared char[280_000] envelope = void;
    logs = Batch!().init;
    if (outbox.claimOutbox(db, sessionId, pid) > 0) {
        outbox.claimedInto(db, pid, logs);
        auto n = envelopeInto(logs, dsn, LOG_CONTENT, LOG_TYPE, envelope[]);
        auto r = postText(dsn, envelope[0 .. n]);
        auto landed = r.status == 200;
        outbox.claimResolved(db, pid, landed, now);
        if (!landed) {
            shipFailed(sessionId, "the outbox post", r.status, r.why());
            return false;
        }
    }

    __gshared Batch!() metrics;
    metrics = Batch!().init;
    if (hooktiming.claimTiming(db, pid) > 0) {
        hooktiming.claimedInto(db, pid, versionString(), metrics);
        auto n = envelopeInto(metrics, dsn, METRIC_CONTENT, METRIC_TYPE, envelope[]);
        auto r = postText(dsn, envelope[0 .. n]);
        auto landed = r.status == 200;
        hooktiming.claimResolved(db, pid, landed, now);
        if (!landed) {
            shipFailed(sessionId, "the timing post", r.status, r.why());
            return false;
        }
    }
    return true;
}

// A row the node did not take for a reason that may change, said once per
// backoff: the HTTP status, or libcurl's code below zero.
private void streamFailed(const(char)[] sessionId, int status) {
    import exec : emitError;
    __gshared char[200] said = 0;
    size_t n;
    void put(const(char)[] s) { foreach (c; s) if (n < said.length) said[n++] = c; }
    put("the stream to qntx stopped at a row: ");
    if (status > 0) {
        put("HTTP ");
        char[3] d = [cast(char)('0' + status / 100 % 10), cast(char)('0' + status / 10 % 10),
                     cast(char)('0' + status % 10)];
        put(d[]);
    } else {
        put("no answer, libcurl code ");
        auto v = -status;
        char[3] d = [cast(char)('0' + v / 100 % 10), cast(char)('0' + v / 10 % 10), cast(char)('0' + v % 10)];
        put(d[]);
    }
    put(" — the rows stay pending, and the next try is in a minute");
    emitError("sky.stream", cast(string) said[0 .. n], 0, -1, cast(string) sessionId,
              KIND, "", "", "");
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
    emitError("sky.ship", cast(string) said[0 .. n], 0, -1, cast(string) sessionId,
              KIND, "", "", "");
}
