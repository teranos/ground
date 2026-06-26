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

    while (true) {
        auto db = openDb();
        if (db !is null) {
            bool foundNew = false;
            bool urgent = false;

            while (true) {
                auto imm = readImmediateMessage(db, cwd, sessionId);
                if (imm.message is null) break;

                // Late-binding: ci-status resolves live. Uses the repo + branch
                // captured at push time (from the push's own stdout). No cwd anywhere.
                if (imm.name == "ci-status") {
                    import deferred : checkCIStatus;
                    import matcher : contains;
                    if (imm.repo.length == 0 || imm.branch.length == 0) {
                        // Row predates the repo-keyed format — drop it.
                        markImmediateDelivered(db, imm.msgId, imm.projectContext, sessionId);
                        continue;
                    }
                    auto ciResult = checkCIStatus(imm.repo, imm.branch);
                    if (contains(ciResult, "in_progress"))
                        break; // not terminal yet, try again next cycle
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
        sleep(2);
    }
}
