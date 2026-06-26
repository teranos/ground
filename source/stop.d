module stop;

import parse : extractBool, extractLastAssistantMessage, writeJsonString;
import db : openDb, attestEvent,
                getBranch, sqlite3, sqlite3_close, ZBuf;
import core.stdc.stdio : stdout, stderr, fputs, fprintf;

extern (C) {
    struct timeval { long tv_sec; long tv_usec; }
    int gettimeofday(timeval* tv, void* tz);
}

long usecNow() {
    timeval tv;
    gettimeofday(&tv, null);
    return tv.tv_sec * 1_000_000 + tv.tv_usec;
}
import deferred : DeferredMsg;
import hooks : DeliverFn;

void putInt(ref ZBuf buf, long v) {
    char[20] digits = 0;
    int dLen = 0;
    if (v == 0) { digits[0] = '0'; dLen = 1; }
    else { while (v > 0) { digits[dLen++] = cast(char)('0' + v % 10); v /= 10; } }
    foreach (i; 0 .. dLen) buf.putChar(digits[dLen - 1 - i]);
}

// Look up a deferred control and produce the delivery message.
// Returns null to suppress delivery (e.g. deliverFn returned nothing).
const(char)[] deliverDeferred(DeferredMsg deferred, const(char)[] cwd) {
    import controls : postToolUseDeferredScopes;
    import hooks : scopeMatches;

    DeliverFn deliverFn = null;
    foreach (ref scope_; postToolUseDeferredScopes) {
        if (!scopeMatches(scope_, cwd)) continue;
        foreach (ref c; scope_.controls) {
            if (c.name == deferred.name) {
                deliverFn = c.defer.deliverFn;
                break;
            }
        }
    }

    if (deliverFn !is null) {
        auto result = deliverFn(cwd);
        if (result is null) return null;
        return result;
    }

    return deferred.message;
}

// Notify loom of hook output so it appears as [hook] in weaves
void notifyLoomHook(const(char)[] cwd, const(char)[] sessionId, const(char)[] message) {
    import loom : sendToLoom;
    import db : jsonArray1, buildSubject;
    auto branch = getBranch(cwd);
    if (branch is null) branch = "unknown";

    __gshared ZBuf subjects, predicates, contexts, attrBuf, subjectVal;
    buildSubject(subjectVal, cwd, branch);
    jsonArray1(subjects, subjectVal.slice());
    jsonArray1(predicates, "Hook");

    contexts.reset();
    contexts.put(`["session:`);
    contexts.put(sessionId);
    contexts.put(`"]`);

    attrBuf.reset();
    attrBuf.put(`{"hook_output":"`);
    foreach (c; message) {
        if (c == '"') attrBuf.put(`\"`);
        else if (c == '\\') attrBuf.put(`\\`);
        else attrBuf.putChar(c);
    }
    attrBuf.put(`"}`);

    sendToLoom(subjects, predicates, contexts, attrBuf.slice());
}

// Claude Code renders \n in reason as literal "\n", not as a line break.
void writeStopResponse(const(char)[] reason) {
    fputs(`{"decision":"block","reason":"`, stdout);
    writeJsonString(reason);
    fputs(`"}`, stdout);
    fputs("\n", stdout);
}

// cwd/sessionId stashed by handleStop so writeStopResponse callers don't need them
__gshared const(char)[] g_cwd;
__gshared const(char)[] g_sessionId;

void writeStopResponseAndNotify(const(char)[] reason) {
    writeStopResponse(reason);
    notifyLoomHook(g_cwd, g_sessionId, reason);
}

int handleStop(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    auto t0 = usecNow();

    g_cwd = cwd;
    g_sessionId = sessionId;

    // Kill previous watcher for THIS session, write claim for the new one.
    if (sessionId !is null) {
        import watch : killSessionWatcher, writeWatchClaim;
        killSessionWatcher(sessionId);
        writeWatchClaim(sessionId);
    }

    auto hookActive = extractBool(input, `"stop_hook_active"`);

    if (hookActive)
        return 0;

    auto t1 = usecNow();

    auto db = openDb();
    if (db is null) return 0;

    auto t2 = usecNow();

    long branchUs;
    const(char)[] branch;
    {
        auto tb0 = usecNow();
        branch = getBranch(cwd);
        branchUs = usecNow() - tb0;
    }

    auto t3 = usecNow();

    // Stop controls — pattern matching on last assistant message
    auto lastMsg = extractLastAssistantMessage(input);
    {
        import matcher : contains;
        import controls : stopScopes;
        import hooks : scopeMatches;
        if (lastMsg !is null) {
            foreach (ref sc; stopScopes) {
                if (!scopeMatches(sc, cwd))
                    continue;
                // edited: scope gate — check session edit history
                if (sc.editedCount > 0) {
                    import db : editAttestationContains, editAttestationOutside;
                    const(char)[][8] exclPats;
                    size_t exclCount;
                    bool inclusiveFailed;
                    foreach (ei; 0 .. sc.editedCount) {
                        auto ep = sc.edited[ei];
                        if (ep.length > 0 && ep[0] == '!') {
                            exclPats[exclCount++] = ep[1 .. $];
                        } else {
                            if (!editAttestationContains(db, ep, sessionId))
                                inclusiveFailed = true;
                        }
                    }
                    if (inclusiveFailed) continue;
                    if (exclCount > 0 && editAttestationOutside(db, exclPats.ptr, exclCount, sessionId, cwd))
                        continue;
                }
                // cmd: scope gate — check session command history
                if (sc.cmdCount > 0) {
                    import db : cmdAttestationExists;
                    bool cmdGateFailed;
                    foreach (ci; 0 .. sc.cmdCount) {
                        auto cp = sc.cmds[ci];
                        if (cp.length > 0 && cp[0] == '!') {
                            // Negated: command must NOT have run
                            if (cmdAttestationExists(db, cp[1 .. $], sessionId))
                                cmdGateFailed = true;
                        } else {
                            // Positive: command must have run
                            if (!cmdAttestationExists(db, cp, sessionId))
                                cmdGateFailed = true;
                        }
                    }
                    if (cmdGateFailed) continue;
                }
                foreach (ref c; sc.controls) {
                    if (c.trigger.len == 0) continue;
                    bool matched = false;
                    import matcher : wildcardContains;
                    foreach (ref v; c.trigger.values)
                        if (wildcardContains(lastMsg, v)) { matched = true; break; }
                    if (!matched) continue;

                    import db : attestationExists, attestControlFire;
                    if (attestationExists(db, "GroundedStop", c.name, sessionId))
                        continue;
                    attestControlFire(db, "GroundedStop", c.name, cwd, sessionId);
                    sqlite3_close(db);
                    import matcher : envSubst;
                    writeStopResponseAndNotify(envSubst(c.msg.value, cwd));
                    return 0;
                }
            }
        }
    }

    // Unread file claim detection — accumulate every project file referenced in
    // the assistant message but never Read this session; surface them all at once.
    {
        import matcher : containsExact;
        import controls : projectFiles;
        if (lastMsg !is null && projectFiles.length > 0) {
            import db : fileAttestationExists, attestationExists, attestControlFire;
            import unread : buildUnreadClaimMessage;

            const(char)[][8] unread;
            size_t unreadCount;

            foreach (ref f; projectFiles) {
                if (unreadCount >= unread.length) break;
                if (!containsExact(lastMsg, f)) continue;
                if (fileAttestationExists(db, f, sessionId)) continue;

                __gshared ZBuf dedupKey;
                dedupKey.reset();
                dedupKey.put("unread-file-claim:");
                dedupKey.put(f);

                if (attestationExists(db, "GroundedStop", dedupKey.slice(), sessionId))
                    continue;

                unread[unreadCount++] = f;
            }

            if (unreadCount > 0) {
                foreach (i; 0 .. unreadCount) {
                    __gshared ZBuf attestKey;
                    attestKey.reset();
                    attestKey.put("unread-file-claim:");
                    attestKey.put(unread[i]);
                    attestControlFire(db, "GroundedStop", attestKey.slice(), cwd, sessionId);
                }
                auto msg = buildUnreadClaimMessage(unread[0 .. unreadCount]);
                sqlite3_close(db);
                writeStopResponseAndNotify(msg.slice());
                return 0;
            }
        }
    }

    auto t4 = usecNow();

    // Deliver-based Stop controls — no trigger, main only, compaction-window dedup
    {
        if (branch == "main" || branch == "master") {
            import controls : stopScopes;
            import hooks : scopeMatches;

            foreach (ref sc; stopScopes) {
                if (!scopeMatches(sc, cwd))
                    continue;
                foreach (ref c; sc.controls) {
                    if (c.trigger.len > 0) continue;       // skip trigger-based (handled above)
                    if (c.defer.deliverFn is null) continue; // nothing to deliver

                    import db : attestationExists, attestControlFire;
                    if (attestationExists(db, "GroundedStop", c.name, sessionId))
                        continue;

                    auto delivered = c.defer.deliverFn(cwd);
                    if (delivered is null) continue;

                    attestControlFire(db, "GroundedStop", c.name, cwd, sessionId);
                    sqlite3_close(db);
                    writeStopResponseAndNotify(delivered);
                    return 0;
                }
            }
        }
    }

    auto t5 = usecNow();

    // Check session-scoped deferred messages — deliver if ready
    // Returns 2 to signal delivery happened (skip timing — subprocess is intentionally slow)
    {
        import deferred : readDeferredMessage, markDelivered;
        auto deferred = readDeferredMessage(db, sessionId);
        if (deferred.message !is null) {
            markDelivered(db, deferred.name, cwd, sessionId);
            auto msg = deliverDeferred(deferred, cwd);
            sqlite3_close(db);
            if (msg !is null)
                writeStopResponseAndNotify(msg);
            return 2;
        }
    }

    auto tDeferSess = usecNow();

    // Check project-scoped deferred messages (from QNTX)
    // Gate: if cwd is a git repo, only deliver on main/master
    {
        if (branch is null || branch == "unknown" || branch == "main" || branch == "master") {
            import deferred : readProjectDeferredMessage, markProjectDelivered;
            auto projDeferred = readProjectDeferredMessage(db, cwd);
            if (projDeferred.message !is null) {
                markProjectDelivered(db, projDeferred.name, projDeferred.projectContext);
                sqlite3_close(db);
                writeStopResponseAndNotify(projDeferred.message);
                return 2;
            }
        }
    }

    auto t6 = usecNow();

    // Per-event-type timing budgets — once per compaction window
    {
        import db : attestationExists, sqlite3_prepare_v2, sqlite3_step, sqlite3_column_int64,
                        sqlite3_bind_text, sqlite3_finalize, sqlite3_stmt, SQLITE_OK, SQLITE_ROW,
                        SQLITE_TRANSIENT, cwdTail;

        if (!attestationExists(db, "GroundedStop", "timing-regression", sessionId)) {
            struct Budget { string event; long thresholdUs; }
            static immutable budgets = [
                Budget("PreToolUse",       50_000),
                Budget("PostToolUse",     200_000),
                Budget("UserPromptSubmit", 50_000),
                Budget("Stop",            300_000),
                Budget("SessionStart",  2_000_000),
            ];

            enum timingSql = "SELECT AVG(duration_us), COUNT(*) FROM (SELECT duration_us FROM timing WHERE hook_event = ?1 AND project = ?2 ORDER BY id DESC LIMIT 20)\0";
            auto project = cwdTail(cwd);

            foreach (ref b; budgets) {
                sqlite3_stmt* stmt;
                if (sqlite3_prepare_v2(db, timingSql.ptr, -1, &stmt, null) != SQLITE_OK)
                    continue;
                sqlite3_bind_text(stmt, 1, b.event.ptr, cast(int) b.event.length, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmt, 2, project.ptr, cast(int) project.length, SQLITE_TRANSIENT);
                if (sqlite3_step(stmt) == SQLITE_ROW) {
                    auto avgUs = sqlite3_column_int64(stmt, 0);
                    auto sampleCount = sqlite3_column_int64(stmt, 1);
                    if (sampleCount >= 10 && avgUs > b.thresholdUs) {
                        sqlite3_finalize(stmt);
                        auto avgMs = avgUs / 1000;
                        auto budgetMs = b.thresholdUs / 1000;
                        __gshared ZBuf timingMsg;
                        timingMsg.reset();
                        timingMsg.put("fyi: ground timing regression: ");
                        timingMsg.put(b.event);
                        timingMsg.put(" averages ");
                        putInt(timingMsg, avgMs);
                        timingMsg.put("ms (budget ");
                        putInt(timingMsg, budgetMs);
                        enum VERSION = import(".version");
                        timingMsg.put("ms, ground ");
                        foreach (vc; VERSION)
                            if (vc != '\n' && vc != '\r') timingMsg.putChar(vc);
                        timingMsg.put(")");
                        auto t7 = usecNow();
                        timingMsg.put(" [parse=");
                        putInt(timingMsg, (t1-t0)/1000);
                        timingMsg.put("ms db=");
                        putInt(timingMsg, (t2-t1)/1000);
                        timingMsg.put("ms branch=");
                        putInt(timingMsg, branchUs/1000);
                        timingMsg.put("ms triggers=");
                        putInt(timingMsg, (t4-t3)/1000);
                        timingMsg.put("ms deliver=");
                        putInt(timingMsg, (t5-t4)/1000);
                        timingMsg.put("ms deferred=");
                        putInt(timingMsg, (t6-t5)/1000);
                        timingMsg.put("ms(sessQ=");
                        putInt(timingMsg, (tDeferSess-t5)/1000);
                        timingMsg.put("ms projQ=");
                        putInt(timingMsg, (t6-tDeferSess)/1000);
                        timingMsg.put("ms) timing=");
                        putInt(timingMsg, (t7-t6)/1000);
                        timingMsg.put("ms]");
                        attestEvent(db, "GroundedStop", cwd, sessionId, `{"control":"timing-regression"}`);
                        sqlite3_close(db);
                        writeStopResponseAndNotify(timingMsg.slice());
                        return 0;
                    }
                }
                sqlite3_finalize(stmt);
            }
        }
    }

    auto t7 = usecNow();

    // Build phases string for persistence and stderr
    {
        import main : setPhases;
        __gshared ZBuf prof;
        prof.reset();
        prof.put("parse="); putInt(prof, t1-t0);
        prof.put("us db="); putInt(prof, t2-t1);
        prof.put("us branch="); putInt(prof, branchUs);
        prof.put("us triggers="); putInt(prof, t4-t3);
        prof.put("us deliver="); putInt(prof, t5-t4);
        prof.put("us deferred="); putInt(prof, t6-t5);
        prof.put("us(sessQ="); putInt(prof, tDeferSess-t5);
        prof.put("us projQ="); putInt(prof, t6-tDeferSess);
        prof.put("us) timing="); putInt(prof, t7-t6);
        prof.put("us total="); putInt(prof, t7-t0);
        prof.put("us");
        setPhases(prof.slice());
        fputs(prof.ptr(), stderr);
        fputs("\n", stderr);
    }

    sqlite3_close(db);
    return 0;
}

// --- Defer delivery tests ---

unittest {
    // deliverDeferred with no matching control falls back to stored message
    auto msg = deliverDeferred(DeferredMsg("nonexistent-control", "stored message"), "/tmp");
    assert(msg == "stored message");
}

unittest {
    // deliverDeferred with unknown control falls back to stored message (not null)
    auto msg = deliverDeferred(DeferredMsg("removed-control", "fallback"), "/tmp");
    assert(msg == "fallback");
}
