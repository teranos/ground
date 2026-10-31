module hookrun;

// "ground_hook as the hooks binary"

// Hook output reference — ground responds via exit code and optional JSON on stdout.
//
// Exit codes:
//   0     — action proceeds, stdout parsed for JSON
//   2     — action blocked, stderr fed to Claude as error
//   other — non-blocking error, action proceeds
//
// Top-level response fields:
//   continue           — (Stop) true makes Claude continue instead of stopping
//   suppressOutput     — suppress hook output from display
//   decision           — "approve" or "block"
//   reason             — explanation for the decision
//   systemMessage      — injected as system message to Claude
//   permissionDecision — "allow", "deny", or "ask"
//
// hookSpecificOutput (PreToolUse, UserPromptSubmit, PostToolUse):
//   hookEventName            — must match the event
//   permissionDecision       — (PreToolUse) "allow", "deny", or "ask"
//   permissionDecisionReason — (PreToolUse) shown to user (allow/ask) or Claude (deny)
//   updatedInput             — (PreToolUse) replaces tool input before execution
//   additionalContext        — (UserPromptSubmit required, PostToolUse optional) injected into context
//   sessionTitle             — (UserPromptSubmit) sets session title, same as /rename
//
// TODO: output fields ground doesn't emit yet:
//   suppressOutput  — could silence verbose hooks (e.g. build-timing)
//   continue:false + stopReason — halt Claude entirely, stronger than decision:block
//   systemMessage   — warning shown to user, separate from context injected to Claude
//
// Common input fields ground doesn't use yet:
//   permission_mode — "default", "plan", "acceptEdits", "auto", "dontAsk", "bypassPermissions"
//   tool_use_id     — unique per tool call, could track tool call chains

enum BOOK_COMMAND = q"EOS
# run by Claude Code and codex on every hook event, the event's JSON on stdin:
ground_hook < event.json
EOS";

import parse : extractCwd, extractSessionId, extractHookEventName, extractSource;
import controls : HookEvent;
import phases : Store;
import core.stdc.stdio : stdin, stdout, stderr, fread, fputs, fwrite, FILE;
import core.sys.posix.unistd : isatty;

extern (C) {
    struct timeval { long tv_sec; long tv_usec; }
    int gettimeofday(timeval* tv, void* tz);
}

long usecNow() {
    timeval tv;
    gettimeofday(&tv, null);
    return tv.tv_sec * 1_000_000 + tv.tv_usec;
}

// Parse hook_event_name string to HookEvent. CTFE-unrolled.
bool parseHookEvent(const(char)[] name, ref HookEvent event) {
    static foreach (member; __traits(allMembers, HookEvent)) {
        if (name == member) {
            event = __traits(getMember, HookEvent, member);
            return true;
        }
    }
    return false;
}

// Reads all of stdin into a static buffer.
// Returns the filled slice, or null on failure/empty.
const(char)[] readStdin() {
    __gshared char[262144] buf = ""; // 256KB — Edit payloads can exceed 64KB
    size_t total = 0;

    while (total < buf.length) {
        auto n = fread(&buf[total], 1, buf.length - total, stdin);
        if (n == 0) break;
        total += n;
    }

    if (total == 0) return null;
    return buf[0 .. total];
}


enum VERSION = import(".version");
enum BUILDDATE = import(".builddate");

void printVersion() {
    fputs("ground ", stderr);
    foreach (c; VERSION)
        if (c != '\n' && c != '\r') {
            char[1] buf = c;
            fwrite(&buf[0], 1, 1, stderr);
        }
    fputs(" built ", stderr);
    foreach (c; BUILDDATE)
        if (c != '\n' && c != '\r') {
            char[1] buf = c;
            fwrite(&buf[0], 1, 1, stderr);
        }
}

size_t argLen(const(char)* ptr) {
    size_t len = 0;
    while (ptr[len] != 0) len++;
    return len;
}

void printDuration(long t0) {
    auto elapsed = usecNow() - t0;
    auto ms = elapsed / 1000;
    auto us = elapsed % 1000;
    // Write "ground: XXms" to stderr
    char[32] buf = 0;
    int pos = 0;
    // ms part
    if (ms == 0) { buf[pos++] = '0'; }
    else {
        char[10] digits = 0;
        int dLen = 0;
        auto v = ms;
        while (v > 0) { digits[dLen++] = cast(char)('0' + v % 10); v /= 10; }
        foreach (i; 0 .. dLen) buf[pos++] = digits[dLen - 1 - i];
    }
    buf[pos++] = '.';
    // us part — zero-padded to 3 digits
    buf[pos++] = cast(char)('0' + us / 100);
    buf[pos++] = cast(char)('0' + (us / 10) % 10);
    buf[pos++] = cast(char)('0' + us % 10);
    buf[pos++] = 'm';
    buf[pos++] = 's';
    fputs("ground: ", stderr);
    fwrite(&buf[0], 1, pos, stderr);
    fputs("\n", stderr);
}

// Phase breakdown string — handlers write here, hookMain persists it.
__gshared char[512] g_phasesBuf = 0;
__gshared size_t g_phasesLen = 0;

void setPhases(const(char)[] s) {
    auto n = s.length < g_phasesBuf.length ? s.length : g_phasesBuf.length;
    foreach (i; 0 .. n) g_phasesBuf[i] = s[i];
    g_phasesLen = n;
}

const(char)[] getPhases() {
    return g_phasesBuf[0 .. g_phasesLen];
}

// The hook's own row, and sqlite's answer to it. A store that would not open
// has already been reported by openDb's chain; a store that opened and then
// refused the row is reported here, with the code. 2026-09-25 20:1x the
// timing index went malformed and forty minutes of hooks stepped an 11 and
// said nothing; sentry showed a gap and nobody was told why.
void recordTiming(long elapsedUs, const(char)[] hookEvent, const(char)[] project,
                  const(char)[] phases, const(char)[] sessionId, const(char)[] cwd) {
    import db : openDb, sqlite3_close, SQLITE_DONE, dbFailureCode;
    import hooktiming : insertTiming;

    auto db = openDb();
    if (db is null) {
        // Corruption is said by openDb's chain; a store busy past the wait is not.
        import exec : emitError;
        emitError("hook.timing", "the store would not open for this hook's timing row", 0, dbFailureCode(),
                  cast(string) sessionId, "hook.timing", "", cast(string) phases, "");
        return;
    }
    auto rc = insertTiming(db, elapsedUs, hookEvent, project, phases);
    // "hook timing should go to both"
    if (rc == SQLITE_DONE && sessionId.length > 0) {
        import hookcost : attestCost;
        attestCost(db, cwd, sessionId, hookEvent, elapsedUs, project, phases);
    }
    sqlite3_close(db);
    if (rc != SQLITE_DONE) {
        import exec : emitError;
        __gshared char[640] said = 0;
        size_t n;
        void put(const(char)[] s) { foreach (c; s) if (n < said.length) said[n++] = c; }
        put("the store refused this hook's timing row: sqlite code ");
        char[3] d = [cast(char)('0' + rc / 100 % 10), cast(char)('0' + rc / 10 % 10), cast(char)('0' + rc % 10)];
        put(d[]);
        put("\n");
        put(phases);
        emitError("hook.timing", cast(string) said[0 .. n], 0, rc,
                  cast(string) sessionId, "hook.timing", "", "", "");
    }
}

int hookMain(int argc, const(char)** argv) {
    // agy names itself; Claude Code and codex run bare ground_hook.
    if (argc >= 2 && argv[1][0 .. argLen(argv[1])] == "agy") {
        import agy : handleAgyHook;
        return handleAgyHook(argc, argv);
    }

    if (isatty(0)) {
        printVersion();
        fputs(" — Ground Control for Agentic AI\n", stderr);
        return 0;
    }

    auto t0 = usecNow();
    const(char)[] eventName;
    const(char)[] project;
    bool skipTiming;
    Outer outer;
    auto rc = run(eventName, project, skipTiming, outer);
    auto elapsed = usecNow() - t0;
    printDuration(t0);
    if (!skipTiming) {
        import zbuf : ZBuf;
        import phases : outerPhases;
        __gshared ZBuf row;
        row.reset();
        outerPhases(row, outer.store, elapsed - outer.store.total, getPhases());
        recordTiming(elapsed, eventName, project, row.slice(), outer.sessionId, outer.cwd);
    }
    return rc;
}

// What the handler cannot time: the read of its input and the event row's
// write to ground.db, both before it is called. The row used to carry the
// handler's phases beside a duration the handler was a tenth of.
struct Outer { Store store; const(char)[] sessionId; const(char)[] cwd; }

int run(ref const(char)[] outEventName, ref const(char)[] outProject, ref bool outSkipTiming,
        ref Outer outer) {
    auto tIn = usecNow();
    auto input = readStdin();
    outer.store.stdinUs = usecNow() - tIn;
    if (input is null) {
        fputs("ground: empty stdin\n", stderr);
        return 1;
    }
    // Common fields
    auto cwd = extractCwd(input);
    if (cwd is null) cwd = "";
    auto sessionId = extractSessionId(input);
    if (sessionId is null) sessionId = "";
    outer.sessionId = sessionId;
    outer.cwd = cwd;

    import db : cwdTail;
    outProject = cwdTail(cwd);

    // "A comet held for the harness is checked there."
    // A repository with a comet landed for it is answered from that comet's sand;
    // one this engine cannot hold is said, and the built-in sand answers.
    {
        import core.stdc.stdlib : getenv;
        import git : originOf;
        import sandload : holdLanded, SandHeld;
        auto home = getenv("HOME");
        if (home !is null) {
            size_t hl = 0;
            while (home[hl] != 0) hl++;
            __gshared typeof(holdLanded("", "")) held;
            held = holdLanded(home[0 .. hl], originOf(cwd));
            if (held.what == SandHeld.refused) {
                import errors : GroundError, deliverError;
                import core.stdc.time : time;
                GroundError err;
                err.origin    = "sandload";
                err.message   = cast(string) held.why();
                err.exitCode  = -1;
                err.sessionId = cast(string) sessionId;
                err.timestamp = cast(long) time(null);
                cast(void) deliverError(err);
            }
        }
    }

    auto eventName = extractHookEventName(input);
    if (eventName is null) return 0;
    outEventName = eventName;

    // Attest every event — even ones we don't handle yet
    {
        import db : openDb, attestEvent, sqlite3_close, dbUnusable, dbFailureMessage, lockWaitUs;
        auto tOpen = usecNow();
        auto db = openDb();
        auto tWrite = usecNow();
        outer.store.openUs = tWrite - tOpen;
        if (db !is null) {
            attestEvent(db, eventName, cwd, sessionId, input);
            // codex runs no statusline for ug to read its model from.
            {
                import parse : codexModel;
                import db : recordModel;
                import core.stdc.time : time;
                char[128] mb = 0;
                auto model = codexModel(input, mb[]);
                if (model !is null) cast(void) recordModel(db, sessionId, model, "", cast(long) time(null));
            }
            auto tClose = usecNow();
            outer.store.writeUs = tClose - tWrite;
            sqlite3_close(db);
            outer.store.closeUs = usecNow() - tClose;
        }
        outer.store.lockUs = lockWaitUs;
        {
            import db : lockHolder;
            outer.store.heldBy = lockHolder();
        }
        // Checked after the write, not only on a null handle: a damaged store
        // opens cleanly when its schema tree survived, and announces itself
        // only when real data moves through the broken ones.
        if (dbUnusable()) {
            // A damaged store is a blocker for everything downstream: controls,
            // attestations, deferred and immediate delivery all read from it,
            // and every one of them reads damage as emptiness. Carrying on
            // would let ground report an all-clear it cannot have verified.
            // So ground does nothing further this invocation — no controls, no
            // delivery — and says why.
            //
            // REPORT ON EVERY HOOK, DENY ON NONE. Returning 2 here denied
            // PreToolUse and UserPromptSubmit, which does not stop ground — it
            // stops the USER, taking away the tool calls and prompts needed to
            // repair the very thing being complained about. It bricked every
            // session at once and made the fix reachable only from outside
            // Claude Code. Refusing to operate and refusing to let someone
            // work are different things.
            //
            // Stop is the one place a block earns its keep: it denies nothing
            // and cannot be scrolled past. stop_hook_active MUST gate it, or
            // Stop never stops firing.
            auto msg = dbFailureMessage();
            fwrite(msg.ptr, 1, msg.length, stderr);
            fputs("\n", stderr);

            import parse : extractBool;
            if (eventName == "Stop" && !extractBool(input, `"stop_hook_active"`))
                return 2;
            return 0;
        }
    }

    HookEvent event;
    if (!parseHookEvent(eventName, event)) return 0;

    if (event == HookEvent.PreToolUse) {
        import pretooluse : handlePreToolUse;
        return handlePreToolUse(input, cwd, sessionId);
    }

    // PermissionRequest — auto-allow/deny permission dialogs
    if (event == HookEvent.PermissionRequest) {
        import permissionrequest : handlePermissionRequest;
        return handlePermissionRequest(input, cwd, sessionId);
    }

    // UserPromptSubmit — keyword controls
    if (event == HookEvent.UserPromptSubmit) {
        import userprompt : handleUserPromptSubmit;
        return handleUserPromptSubmit(input, cwd, sessionId);
    }

    // Stop — deferred messages, lazy-verify
    if (event == HookEvent.Stop) {
        import stop : handleStop;
        auto stopRc = handleStop(input, cwd, sessionId);
        if (stopRc == 2) { outSkipTiming = true; return 0; }
        return stopRc;
    }

    // SessionStart — emit arch context on startup/clear
    if (event == HookEvent.SessionStart) {
        auto source = extractSource(input);
        import sessionstart : handleSessionStart;
        return handleSessionStart(source, cwd, sessionId);
    }

    // The only event that reaches the person and costs nothing: exit 2 shows
    // stderr and nothing else. Registered since forever, handled by nobody.
    if (event == HookEvent.Notification) {
        import notification : handleNotification;
        return handleNotification(input, cwd, sessionId);
    }

    if (event == HookEvent.PreCompact) {
        import precompact : handlePreCompact;
        return handlePreCompact(input, cwd, sessionId);
    }

    // PostToolUse — controls + CI deferral
    if (event == HookEvent.PostToolUse) {
        import posttooluse : handlePostToolUse;
        return handlePostToolUse(input, cwd, sessionId);
    }

    if (event == HookEvent.PostToolUseFailure) {
        import posttoolusefailure : handlePostToolUseFailure;
        return handlePostToolUseFailure(input, cwd, sessionId);
    }

    // The one event where exiting 0 with no output is itself the failure:
    // the docs make the printed path the success, and a hook that prints
    // nothing aborts the creation.
    // An agent started with a ritual: the only place the owning session and
    // the agent are both known.
    // What Claude Code sends on an API error is not written down anywhere,
    // so this records it before anything reads it.
    if (event == HookEvent.StopFailure) {
        import stopfailure : handleStopFailure;
        return handleStopFailure(input, cwd, sessionId);
    }

    if (event == HookEvent.MessageDisplay) {
        import messagedisplay : handleMessageDisplay;
        return handleMessageDisplay(input, cwd, sessionId);
    }

    if (event == HookEvent.WorktreeCreate) {
        import worktree : handleWorktreeCreate;
        return handleWorktreeCreate(input, cwd);
    }

    if (event == HookEvent.WorktreeRemove) {
        import worktree : handleWorktreeRemove;
        return handleWorktreeRemove(input, cwd);
    }

    // Unknown/unhandled events — exit 0, no output
    return 0;
}
