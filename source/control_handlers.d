module control_handlers;

import matcher : contains;
import hooks : CheckResult, fires, passes;
import db : sqlite3, ZBuf;

// Verdict for the approval-gated handlers (commit / merge / kill).
//
// Fail-closed on an unreachable db is the policy and stays the policy: not
// being able to check is not permission. What changes is the story told
// afterwards. Denying because sqlite would not open is a different fact from
// denying because the user never approved, and only the second is what the
// authored pbt message claims. When the check could not run, the handler
// hands back what it actually observed and that text is delivered instead.
CheckResult approvalVerdict(bool dbReachable, bool userApproved, string unreachable) {
    if (!dbReachable) return CheckResult(true, unreachable);
    return CheckResult(!userApproved, null);
}

// Set by PreToolUse handler before calling checkAllCommands.
__gshared const(char)[] g_sessionId;

// Set by PreToolUse handler before calling checkAllCommands. Matcher.d's
// per-segment check_handler invocation passes `input=null`, so Bash-path
// handlers that need the full tool_input JSON read it from here instead.
__gshared const(char)[] g_input;

// Set by matcher.d / pretooluse.d before dispatching a check_handler.
// Reflects the `handler_params { … }` block of the control whose handler
// is about to run. Handlers read named params via `lookupParam(name)`.
__gshared string[8] g_paramKeys;
__gshared string[8] g_paramValues;
__gshared ubyte g_paramCount;

// Look up a handler_params value by name. Returns null if the key is not
// present. Handlers must handle null (no param set) themselves — usually by
// returning false so the control doesn't fire.
const(char)[] lookupParam(const(char)[] name) {
    foreach (i; 0 .. g_paramCount) {
        if (g_paramKeys[i] == name) return g_paramValues[i];
    }
    return null;
}

// Tiny int parser for handler_params values. Returns 0 on non-numeric or
// negative input — handlers should treat 0 as "unset".
int parseParamInt(const(char)[] s) {
    int n = 0;
    foreach (ch; s) {
        if (ch < '0' || ch > '9') return 0;
        n = n * 10 + (ch - '0');
    }
    return n;
}

// --- Check handlers ---
// CheckResult function(cwd, input) — see hooks.CheckResult.

extern (C) int access(const(char)* path, int mode);

unittest {
    // Unreachable db: fail closed, but the Error must say what was measured.
    // The authored pbt message claims the user withheld approval; the code
    // never looked, so that claim is not its to make.
    auto r = approvalVerdict(false, false, "db down");
    assert(r.fired, "unreachable db must still deny");
    assert(r.observed == "db down", "must report what it actually observed");
}

unittest {
    // Reachable, no approval found: the authored message is accurate, so the
    // handler overrides nothing.
    auto r = approvalVerdict(true, false, "db down");
    assert(r.fired);
    assert(r.observed is null, "authored msg stands when the check really ran");
}

unittest {
    // Approval found: don't fire.
    auto r = approvalVerdict(true, true, "db down");
    assert(!r.fired);
    assert(r.observed is null);
}

CheckResult binaryShadowed(const(char)[] cwd, const(char)[] input) {
    enum F_OK = 0;
    return access("/usr/local/bin/ground\0".ptr, F_OK) == 0 ? fires() : passes();
}

CheckResult commitNotRequested(const(char)[] cwd, const(char)[] input) {
    // No session — can't check, don't block
    if (g_sessionId.length == 0) return passes();

    import db : openDb, sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_bind_int64,
                sqlite3_step, sqlite3_column_int64, sqlite3_finalize, sqlite3_close,
                sqlite3_stmt, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    import zbuf : ZBuf;

    auto db = openDb();
    if (db is null)
        return approvalVerdict(false, false,
            "commit denied: ground could not open its database, so it could not check whether you approved a commit. Denying rather than asserting you did not.");

    __gshared ZBuf ctx;
    ctx.reset();
    ctx.put("session:");
    ctx.put(g_sessionId);

    // Find the most recent successful git commit — GroundedPostToolUse fires only after
    // the commit actually ran (denied PreToolUse never reaches PostToolUse).
    enum lastCommitSql = "SELECT rowid FROM attestations WHERE json_extract(predicates, '$[0]') = 'GroundedPostToolUse' AND json_extract(contexts, '$[0]') = ?1 AND json_extract(attributes, '$.control') = 'commit-push-reminder' ORDER BY rowid DESC LIMIT 1\0";

    sqlite3_stmt* commitStmt;
    long lastCommitRowid = 0;
    if (sqlite3_prepare_v2(db, lastCommitSql.ptr, -1, &commitStmt, null) == SQLITE_OK) {
        sqlite3_bind_text(commitStmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
        if (sqlite3_step(commitStmt) == SQLITE_ROW)
            lastCommitRowid = sqlite3_column_int64(commitStmt, 0);
        sqlite3_finalize(commitStmt);
    }

    // Check last 3 user messages after the last commit — any approval counts.
    // Window: 3 past messages. After denial, user says "ok"/"y", next attempt sees it.
    enum last3Sql = "SELECT json_extract(attributes, '$.prompt') FROM attestations WHERE json_extract(predicates, '$[0]') IN ('UserPromptSubmit','QueuedPromptSubmit') AND json_extract(contexts, '$[0]') = ?1 AND rowid > ?2 ORDER BY rowid DESC LIMIT 3\0";

    import db : sqlite3_column_text;
    sqlite3_stmt* userStmt;
    bool userSaid = false;
    if (sqlite3_prepare_v2(db, last3Sql.ptr, -1, &userStmt, null) == SQLITE_OK) {
        sqlite3_bind_text(userStmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
        sqlite3_bind_int64(userStmt, 2, lastCommitRowid);
        int msgIdx = 0;
        while (sqlite3_step(userStmt) == SQLITE_ROW) {
            auto text = sqlite3_column_text(userStmt, 0);
            if (text !is null) {
                size_t tlen = 0;
                while (text[tlen] != 0) tlen++;
                auto m = text[0 .. tlen];
                if (isCommitApproval(m) || (msgIdx == 0 && isImmediateApproval(m))) {
                    userSaid = true;
                    break;
                }
            }
            msgIdx++;
        }
        sqlite3_finalize(userStmt);
    }

    // Standing approval. Deliberately ignores lastCommitRowid: the whole point
    // is that a bare "commit" is not spent by the first commit it authorises.
    // Only the single newest prompt counts — the moment the user says anything
    // else, the standing approval is over and the window rules apply again.
    if (!userSaid) {
        enum newestSql = "SELECT json_extract(attributes, '$.prompt') FROM attestations WHERE json_extract(predicates, '$[0]') IN ('UserPromptSubmit','QueuedPromptSubmit') AND json_extract(contexts, '$[0]') = ?1 ORDER BY rowid DESC LIMIT 1\0";
        sqlite3_stmt* newestStmt;
        if (sqlite3_prepare_v2(db, newestSql.ptr, -1, &newestStmt, null) == SQLITE_OK) {
            sqlite3_bind_text(newestStmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
            if (sqlite3_step(newestStmt) == SQLITE_ROW) {
                auto text = sqlite3_column_text(newestStmt, 0);
                if (text !is null) {
                    size_t tlen = 0;
                    while (text[tlen] != 0) tlen++;
                    if (isStandingCommitApproval(text[0 .. tlen]))
                        userSaid = true;
                }
            }
            sqlite3_finalize(newestStmt);
        }
    }

    sqlite3_close(db);

    // The operator's general go-ahead answers here too.
    if (!userSaid) userSaid = operatorWentAhead(GO_AHEAD_WINDOW);

    // Fire (deny) if user did NOT approve a commit
    return approvalVerdict(true, userSaid, null);
}

// Same approval-in-window shape as killNotRequested (no reset marker
// — merge is rare enough that a per-merge reset would surprise more
// than it protects). Fires deny unless one of the last 3 user
// messages contains a strong approval, or the immediately previous
// message is a bare weak approval.
CheckResult mergeNotRequested(const(char)[] cwd, const(char)[] input) {
    if (g_sessionId.length == 0) return passes();

    import db : openDb, sqlite3_prepare_v2, sqlite3_bind_text,
                sqlite3_step, sqlite3_column_text, sqlite3_finalize, sqlite3_close,
                sqlite3_stmt, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    import zbuf : ZBuf;

    auto db = openDb();
    if (db is null)
        return approvalVerdict(false, false,
            "merge denied: ground could not open its database, so it could not check whether you approved a merge. Denying rather than asserting you did not.");

    __gshared ZBuf ctx;
    ctx.reset();
    ctx.put("session:");
    ctx.put(g_sessionId);

    enum last5Sql = "SELECT json_extract(attributes, '$.prompt') FROM attestations WHERE json_extract(predicates, '$[0]') IN ('UserPromptSubmit','QueuedPromptSubmit') AND json_extract(contexts, '$[0]') = ?1 ORDER BY rowid DESC LIMIT 5\0";


    sqlite3_stmt* stmt;
    bool userSaid = false;
    if (sqlite3_prepare_v2(db, last5Sql.ptr, -1, &stmt, null) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
        int msgIdx = 0;
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            auto text = sqlite3_column_text(stmt, 0);
            if (text !is null) {
                size_t tlen = 0;
                while (text[tlen] != 0) tlen++;
                auto m = text[0 .. tlen];
                if (isMergeApproval(m) || (msgIdx == 0 && isImmediateMergeApproval(m))) {
                    userSaid = true;
                    break;
                }
            }
            msgIdx++;
        }
        sqlite3_finalize(stmt);
    }

    sqlite3_close(db);
    if (!userSaid) userSaid = operatorWentAhead(GO_AHEAD_WINDOW);
    return approvalVerdict(true, userSaid, null);
}

// Strong approval — anywhere in the 5-msg window.
bool isMergeApproval(const(char)[] msg) {
    if (contains(msg, "merge")) return true;
    if (containsCI(msg, "verified")) return true;
    auto trimmed = trimWS(msg);
    return trimmed == "ok" || trimmed == "sure";
}

// Weak approval — must be the immediate previous message.
bool isImmediateMergeApproval(const(char)[] msg) {
    auto trimmed = trimWS(msg);
    return trimmed == "yes" || trimmed == "y" || trimmed == "do it";
}

unittest {
    // "commits" already matched — "commit" is a substring of it. The gate that
    // blocked "Do logical commits" was the rowid window, not the vocabulary.
    assert(isCommitApproval("Do logical commits"));
    assert(isCommitApproval("commit this"));

    // The single-t spellings do not contain "commit" and never matched.
    assert(isCommitApproval("comit"), "comit is approval");
    assert(isCommitApproval("do the comits"), "comits is approval");

    // Still not approval — the word has to actually be asked for.
    assert(!isCommitApproval("what would you put in as a message"));

    // Substring matching is deliberate and this is its cost: "committee"
    // contains "commit", so it reads as approval. Recorded, not fixed —
    // narrowing it would break "commits"/"comits", which is the point.
    assert(isCommitApproval("committee meeting notes"));
}

// Is this message nothing but a request to commit?
//
// The per-commit window made "do logical commits" unsatisfiable: the approval
// is recorded before the first commit, every later commit looks only at
// prompts newer than the last commit marker, and so a plural instruction
// authorised exactly one. Re-asking N times to satisfy an instruction that
// already said N is friction with no safety in it.
//
// A message that carries only the approval word is standing: the user asked,
// and has said nothing since, so it holds until they say something else. A
// message with real content in it stays one-shot and scoped to what it asked
// for — "commit the db fix only" must not authorise the rest.
bool isStandingCommitApproval(const(char)[] msg) {
    auto t = trimWS(msg);
    if (t.length == 0) return false;

    // Drop a trailing politeness so "comit please" still reads as bare.
    if (t.length > 7) {
        auto tail = t[$ - 7 .. $];
        if (containsCI(tail, "please")) t = trimWS(t[0 .. $ - 7]);
    }

    // Every remaining word must be an approval word or a filler like "do"/
    // "logical" — anything else is content, and content means scope.
    size_t start = 0;
    bool sawApproval = false;
    while (start <= t.length) {
        size_t end = start;
        while (end < t.length && t[end] != ' ' && t[end] != '\t') end++;
        if (end > start) {
            auto w = t[start .. end];
            if (containsCI(w, "comit")) sawApproval = true;         // comit(s)
            else if (containsCI(w, "commit")) sawApproval = true;   // commit(s)
            else if (containsCI(w, "do")) {}                        // "do logical commits"
            else if (containsCI(w, "logical")) {}
            else return false;                                      // real content
        }
        if (end >= t.length) break;
        start = end + 1;
    }
    return sawApproval;
}

unittest {
    // A bare approval is a STANDING one. The user asked to commit and has said
    // nothing since, so it covers the whole batch instead of being spent by the
    // first commit — which is what made a plural instruction unsatisfiable.
    assert(isStandingCommitApproval("commit"));
    assert(isStandingCommitApproval("comit please"));
    assert(isStandingCommitApproval("  commits  "));
    assert(isStandingCommitApproval("Do logical commits"));

    // A message carrying real content is a one-shot, scoped to what it asked
    // for. Standing approval is only inferred when there is nothing else in it.
    assert(!isStandingCommitApproval("commit the db fix only"));
    assert(!isStandingCommitApproval("if you would commit, what would you put"));
    assert(!isStandingCommitApproval("what is uncomitted?"));
}

// Strong approval — works anywhere in the 3-message window.
// Contains "commit"/"comit" (either spelling, and their plurals by substring)
// or "verified" (case-insensitive), or bare "ok"/"sure".
bool isCommitApproval(const(char)[] msg) {
    if (contains(msg, "comit")) return true;   // comit, comits
    if (contains(msg, "commit")) return true;
    if (containsCI(msg, "verified")) return true;

    auto trimmed = trimWS(msg);
    return trimmed == "ok" || trimmed == "sure";
}

// Weak approval — only counts as the immediate last message.
// Bare "yes" or "y".
bool isImmediateApproval(const(char)[] msg) {
    auto trimmed = trimWS(msg);
    return trimmed == "yes" || trimmed == "y";
}

unittest {
    // The words the operator named, and nothing else is one.
    assert(isGoAhead("go ahead"));
    assert(isGoAhead("approved"));
    assert(isGoAhead("sure"));

    // Case and surrounding space are not content.
    assert(isGoAhead("  Go Ahead  "));
    assert(isGoAhead("APPROVED"));

    // Bare only. A message carrying anything else is content, and content has
    // a scope — this key has none, so it may not be inferred from a sentence.
    assert(!isGoAhead("go ahead with the merge only"));
    assert(!isGoAhead("dont go ahead"));
    assert(!isGoAhead("is that approved?"));
    assert(!isGoAhead("sure, but not the fonts"));

    // Nothing said is not permission.
    assert(!isGoAhead(""));
    assert(!isGoAhead("   "));
}

unittest {
    // Exact, not substring: a longer word that contains one is a different
    // word. "surely" is not "sure".
    assert(!isGoAhead("surely"));
    assert(!isGoAhead("unapproved"));
    assert(!isGoAhead("goahead"));
}

const(char)[] trimWS(const(char)[] msg) {
    size_t start = 0;
    while (start < msg.length && (msg[start] == ' ' || msg[start] == '\t' || msg[start] == '\n' || msg[start] == '\r'))
        start++;
    size_t end = msg.length;
    while (end > start && (msg[end - 1] == ' ' || msg[end - 1] == '\t' || msg[end - 1] == '\n' || msg[end - 1] == '\r'))
        end--;
    return msg[start .. end];
}

bool containsCI(const(char)[] haystack, const(char)[] needle) {
    if (needle.length == 0) return true;
    if (haystack.length < needle.length) return false;
    foreach (i; 0 .. haystack.length - needle.length + 1) {
        bool match = true;
        foreach (j; 0 .. needle.length) {
            char a = haystack[i + j];
            char b = needle[j];
            if (a >= 'A' && a <= 'Z') a += 32;
            if (b >= 'A' && b <= 'Z') b += 32;
            if (a != b) { match = false; break; }
        }
        if (match) return true;
    }
    return false;
}

// "make sure ground recognises me saying go ahead"
// The operator's own words, lifting every gate at once rather than one act at
// a time. Nothing the assistant writes reaches the corpus these read.
private static immutable string[3] GO_AHEAD = ["go ahead", "approved", "sure"];

// How many of the last prompts a go-ahead reaches back through. The narrowest
// of the windows already in use here, because this one opens every door.
enum GO_AHEAD_WINDOW = 3;

// Exact, ignoring case. A longer word that contains one is a different word.
bool equalsCI(const(char)[] a, const(char)[] b) {
    if (a.length != b.length) return false;
    foreach (i, ca; a) {
        char x = ca;
        char y = b[i];
        if (x >= 'A' && x <= 'Z') x += 32;
        if (y >= 'A' && y <= 'Z') y += 32;
        if (x != y) return false;
    }
    return true;
}

// A message that is nothing but the go-ahead. Carrying anything else makes it
// content, and content has a scope this key does not.
bool isGoAhead(const(char)[] msg) {
    auto t = trimWS(msg);
    if (t.length == 0) return false;
    foreach (w; GO_AHEAD) if (equalsCI(t, w)) return true;
    return false;
}

// Whether the operator went ahead inside the window. Read from the prompts
// only: an assistant cannot put a row where this looks.
bool operatorWentAhead(int limit) {
    import db : openDb, sqlite3_prepare_v2, sqlite3_bind_text,
                sqlite3_step, sqlite3_column_text, sqlite3_finalize, sqlite3_close,
                sqlite3_stmt, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    import zbuf : ZBuf;

    if (g_sessionId.length == 0) return false;

    auto db = openDb();
    if (db is null) return false;

    __gshared ZBuf ctx;
    ctx.reset();
    ctx.put("session:");
    ctx.put(g_sessionId);

    enum sql = "SELECT json_extract(attributes, '$.prompt') FROM attestations WHERE json_extract(predicates, '$[0]') IN ('UserPromptSubmit','QueuedPromptSubmit') AND json_extract(contexts, '$[0]') = ?1 ORDER BY rowid DESC LIMIT 8\0";

    sqlite3_stmt* stmt;
    bool went = false;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
        int seen = 0;
        while (sqlite3_step(stmt) == SQLITE_ROW && seen < limit) {
            auto text = sqlite3_column_text(stmt, 0);
            if (text !is null) {
                size_t tlen = 0;
                while (text[tlen] != 0) tlen++;
                if (isGoAhead(text[0 .. tlen])) { went = true; break; }
            }
            seen++;
        }
        sqlite3_finalize(stmt);
    }

    sqlite3_close(db);
    return went;
}

// Check if Cargo.toml exists in the working directory.
bool isRustProject(const(char)[] cwd) {
    if (cwd.length == 0) return false;
    __gshared char[512] pathBuf = 0;
    if (cwd.length + 11 >= pathBuf.length) return false;
    pathBuf[0 .. cwd.length] = cwd[];
    pathBuf[cwd.length .. cwd.length + 11] = "/Cargo.toml";
    pathBuf[cwd.length + 11] = 0;
    import core.sys.posix.sys.stat : stat_t, stat;
    stat_t st;
    return stat(&pathBuf[0], &st) == 0;
}

unittest {
    // "make sure the did-not-request-kill control doesnt fire for fable"
    // The pbt names the word; the session's model as ug wrote it is matched on it.
    assert(modelExempt("claude-fable-5-1", "fable"));
    assert(modelExempt("claude-fable-5-1", "Fable"));
    assert(!modelExempt("claude-opus-5", "fable"));
    assert(!modelExempt("", "fable"), "a session ug never saw is not exempt");
    assert(!modelExempt("claude-fable-5-1", ""), "no word named, nobody exempt");
}

// True when the session's model, as ug wrote it, carries the word the pbt
// named in unless_model. No word or no model: nobody is exempt.
bool modelExempt(const(char)[] model, const(char)[] word) {
    if (model.length == 0 || word.length == 0) return false;
    return containsCI(model, word);
}

CheckResult killNotRequested(const(char)[] cwd, const(char)[] input) {
    if (g_sessionId.length == 0) return passes();

    import db : openDb, sqlite3_prepare_v2, sqlite3_bind_text,
                sqlite3_step, sqlite3_column_text, sqlite3_finalize, sqlite3_close,
                sqlite3_stmt, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT, modelOf;
    import zbuf : ZBuf;

    auto db = openDb();
    if (db is null)
        return approvalVerdict(false, false,
            "denied: ground could not open its database, so it could not check whether you requested this. Denying rather than asserting you did not.");

    if (modelExempt(modelOf(db, g_sessionId).model(), lookupParam("unless_model"))) {
        sqlite3_close(db);
        return passes();
    }

    __gshared ZBuf ctx;
    ctx.reset();
    ctx.put("session:");
    ctx.put(g_sessionId);

    enum last3Sql = "SELECT json_extract(attributes, '$.prompt') FROM attestations WHERE json_extract(predicates, '$[0]') IN ('UserPromptSubmit','QueuedPromptSubmit') AND json_extract(contexts, '$[0]') = ?1 ORDER BY rowid DESC LIMIT 3\0";

    sqlite3_stmt* stmt;
    bool userSaid = false;
    if (sqlite3_prepare_v2(db, last3Sql.ptr, -1, &stmt, null) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
        int msgIdx = 0;
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            auto text = sqlite3_column_text(stmt, 0);
            if (text !is null) {
                size_t tlen = 0;
                while (text[tlen] != 0) tlen++;
                auto m = text[0 .. tlen];
                if (containsCI(m, "kill")) {
                    userSaid = true;
                    break;
                }
            }
            msgIdx++;
        }
        sqlite3_finalize(stmt);
    }

    sqlite3_close(db);
    if (!userSaid) userSaid = operatorWentAhead(GO_AHEAD_WINDOW);
    return approvalVerdict(true, userSaid, null);
}

// A word is bounded by something that is not a letter or a digit. Case is
// ignored on both sides.
private bool containsWord(const(char)[] text, const(char)[] word) {
    if (word.length == 0 || word.length > text.length) return false;

    static bool alnum(char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9');
    }

    foreach (i; 0 .. text.length - word.length + 1) {
        bool same = true;
        foreach (j, wc; word) {
            char tc = text[i + j];
            if (tc >= 'A' && tc <= 'Z') tc = cast(char)(tc + 32);
            char lower = wc >= 'A' && wc <= 'Z' ? cast(char)(wc + 32) : wc;
            if (tc != lower) { same = false; break; }
        }
        if (!same) continue;
        if (i > 0 && alnum(text[i - 1])) continue;
        auto after = i + word.length;
        if (after < text.length && alnum(text[after])) continue;
        return true;
    }
    return false;
}

// Whether one of the last few things the user typed carries a word.
private bool userRecentlySaid(const(char)[] word, int limit) {
    import db : openDb, sqlite3_prepare_v2, sqlite3_bind_text,
                sqlite3_step, sqlite3_column_text, sqlite3_finalize, sqlite3_close,
                sqlite3_stmt, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    import zbuf : ZBuf;

    auto db = openDb();
    if (db is null) return false;

    __gshared ZBuf ctx;
    ctx.reset();
    ctx.put("session:");
    ctx.put(g_sessionId);

    enum sql = "SELECT json_extract(attributes, '$.prompt') FROM attestations WHERE json_extract(predicates, '$[0]') IN ('UserPromptSubmit','QueuedPromptSubmit') AND json_extract(contexts, '$[0]') = ?1 ORDER BY rowid DESC LIMIT 8\0";

    sqlite3_stmt* stmt;
    bool said = false;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
        int seen = 0;
        while (sqlite3_step(stmt) == SQLITE_ROW && seen < limit) {
            auto text = sqlite3_column_text(stmt, 0);
            if (text !is null) {
                size_t tlen = 0;
                while (text[tlen] != 0) tlen++;
                if (containsWord(text[0 .. tlen], word)) { said = true; break; }
            }
            seen++;
        }
        sqlite3_finalize(stmt);
    }

    sqlite3_close(db);
    return said;
}

// Which `gh pr` verbs only look. Everything else — a verb this build has never
// heard of included — stays gated, so a new way to act arrives closed.
private static immutable string[5] PR_OBSERVES = [
    "checks", "diff", "list", "status", "view",
];

private bool prVerbObserves(const(char)[] segment) {
    enum PREFIX = "gh pr ";
    if (segment.length <= PREFIX.length) return false;
    if (segment[0 .. PREFIX.length] != PREFIX) return false;

    auto rest = segment[PREFIX.length .. $];
    size_t end = 0;
    while (end < rest.length && rest[end] != ' ' && rest[end] != '\t') end++;

    foreach (v; PR_OBSERVES) if (rest[0 .. end] == v) return true;
    return false;
}

// Whether every segment naming a pull request only looks at one. A chain is
// judged whole: one look does not carry the merge it is chained to.
bool prOnlyObserves(const(char)[] command) {
    import matcher : strip;

    bool sawOne = false;
    size_t start = 0;
    size_t i = 0;

    while (i <= command.length) {
        bool isSep = false;
        size_t skip = 0;

        if (i == command.length) {
            isSep = true;
        } else if (command[i] == '|' || command[i] == ';' || command[i] == '\n') {
            isSep = true;
            skip = 1;
        } else if (i + 1 < command.length && command[i] == '&' && command[i + 1] == '&') {
            isSep = true;
            skip = 2;
        }

        if (isSep) {
            auto segment = strip(command[start .. i]);
            if (segment.length >= 5 && segment[0 .. 5] == "gh pr") {
                if (!prVerbObserves(segment)) return false;
                sawOne = true;
            }
            if (i == command.length) break;
            start = i + skip;
            i += (skip > 0 ? skip : 1);
            continue;
        }
        i++;
    }
    return sawOne;
}

// Anything touching a pull request happens because the user said so. The word
// is always there when they mean it.
CheckResult prNotRequested(const(char)[] cwd, const(char)[] input) {
    import parse : extractCommand;

    if (g_sessionId.length == 0) return passes();

    // Looking at a pull request is not touching one, and being denied the look
    // left a session blind to the run it had just started.
    auto src = input.length > 0 ? input : g_input;
    auto command = extractCommand(src);
    if (command !is null && prOnlyObserves(command)) return passes();

    return approvalVerdict(true,
        userRecentlySaid("pr", 8) || operatorWentAhead(GO_AHEAD_WINDOW), null);
}

// "i want to block automatic branch creation by you"

// Same shape as killNotRequested: the word has to be in one of the last few
// things the user typed, or the branch is not made.
CheckResult branchNotRequested(const(char)[] cwd, const(char)[] input) {
    if (g_sessionId.length == 0) return passes();

    import db : openDb, sqlite3_prepare_v2, sqlite3_bind_text,
                sqlite3_step, sqlite3_column_text, sqlite3_finalize, sqlite3_close,
                sqlite3_stmt, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    import zbuf : ZBuf;

    auto db = openDb();
    if (db is null)
        return approvalVerdict(false, false,
            "denied: ground could not open its database, so it could not check whether you asked for a branch. Denying rather than asserting you did not.");

    __gshared ZBuf ctx;
    ctx.reset();
    ctx.put("session:");
    ctx.put(g_sessionId);

    enum lastSql = "SELECT json_extract(attributes, '$.prompt') FROM attestations WHERE json_extract(predicates, '$[0]') IN ('UserPromptSubmit','QueuedPromptSubmit') AND json_extract(contexts, '$[0]') = ?1 ORDER BY rowid DESC LIMIT 5\0";

    sqlite3_stmt* stmt;
    bool userSaid = false;
    if (sqlite3_prepare_v2(db, lastSql.ptr, -1, &stmt, null) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            auto text = sqlite3_column_text(stmt, 0);
            if (text !is null) {
                size_t tlen = 0;
                while (text[tlen] != 0) tlen++;
                if (containsCI(text[0 .. tlen], "branch") || containsWord(text[0 .. tlen], "pr")) {
                    userSaid = true;
                    break;
                }
            }
        }
        sqlite3_finalize(stmt);
    }

    sqlite3_close(db);
    if (!userSaid) userSaid = operatorWentAhead(GO_AHEAD_WINDOW);
    return approvalVerdict(true, userSaid, null);
}

// Two sourced quotes in the wrong order tell a story neither of them told.
// A span with no prompt behind it has no said-time to compare, so it is
// carried by provenance rather than judged here.
CheckResult quoteChronology(const(char)[] cwd, const(char)[] input) {
    import parse : extractWrittenText, extractFilePath;
    import provenance : nextQuotedSpan, firstOutOfOrder, onProseLine, isWord;
    import db : openDb, sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_step,
                sqlite3_column_int64, sqlite3_finalize, sqlite3_close,
                sqlite3_stmt, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    import zbuf : ZBuf;

    auto written = extractWrittenText(input);
    if (written is null) return passes();
    if (g_sessionId.length == 0)
        return CheckResult(true,
            "denied: ground has no session id here, so it could not place these quotes in the record.");

    auto db = openDb();
    if (db is null)
        return CheckResult(true,
            "denied: ground could not open its database, so it could not check the order these were said in.");

    __gshared ZBuf ctx;
    ctx.reset();
    ctx.put("session:");
    ctx.put(g_sessionId);

    enum saidSql = "SELECT MIN(rowid) FROM attestations WHERE json_extract(contexts, '$[0]') = ?1 AND json_extract(predicates, '$[0]') IN ('UserPromptSubmit','QueuedPromptSubmit') AND instr(json_extract(attributes, '$.prompt'), ?2) > 0\0";

    enum MAX_SPANS = 64;
    long[MAX_SPANS] said;
    size_t[MAX_SPANS] spanStart;
    size_t[MAX_SPANS] spanEnd;
    size_t n = 0;

    auto src = extractFilePath(input);

    size_t from = 0;
    while (n < MAX_SPANS) {
        auto sp = nextQuotedSpan(written, from);
        if (!sp.ok) break;
        from = sp.end + 1;
        if (!onProseLine(written, sp, src)) continue;
        if (isWord(written, sp)) continue;
        auto text = written[sp.start .. sp.end];
        if (text.length == 0) continue;

        sqlite3_stmt* stmt;
        if (sqlite3_prepare_v2(db, saidSql.ptr, -1, &stmt, null) != SQLITE_OK) {
            sqlite3_close(db);
            return CheckResult(true,
                "denied: ground could not query its database, so it could not check the order these were said in.");
        }
        sqlite3_bind_text(stmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, text.ptr, cast(int) text.length, SQLITE_TRANSIENT);
        long at = 0;
        if (sqlite3_step(stmt) == SQLITE_ROW) at = sqlite3_column_int64(stmt, 0);
        sqlite3_finalize(stmt);

        if (at > 0) {
            said[n] = at;
            spanStart[n] = sp.start;
            spanEnd[n] = sp.end;
            n++;
        }
    }
    sqlite3_close(db);

    auto bad = firstOutOfOrder(said[0 .. n]);
    if (bad < 0) return passes();

    auto text = written[spanStart[bad] .. spanEnd[bad]];
    __gshared ZBuf observed;
    observed.reset();
    observed.put("this quoted span was said before the one above it: \"");
    observed.put(text.length > 200 ? text[0 .. 200] : text);
    observed.put("\"");
    return CheckResult(true, cast(string) observed.slice());
}

// A quote sharing its line with commentary reads as part of the quote. This
// refuses the line rather than trusting the reader to tell them apart.
CheckResult quoteStandsAlone(const(char)[] cwd, const(char)[] input) {
    import parse : extractWrittenText, extractFilePath;
    import provenance : nextQuotedSpan, standsAlone, onProseLine, lineComment, isWord;
    import zbuf : ZBuf;

    auto written = extractWrittenText(input);
    if (written is null) return passes();

    auto src = extractFilePath(input);

    __gshared ZBuf observed;
    size_t from = 0;
    while (true) {
        auto sp = nextQuotedSpan(written, from);
        if (!sp.ok) break;
        from = sp.end + 1;
        if (!onProseLine(written, sp, src)) continue;
        if (isWord(written, sp)) continue;
        if (standsAlone(written, sp, lineComment(src))) continue;

        auto text = written[sp.start .. sp.end];
        observed.reset();
        observed.put("this quoted span shares its line with other text: \"");
        observed.put(text.length > 200 ? text[0 .. 200] : text);
        observed.put("\"");
        return CheckResult(true, cast(string) observed.slice());
    }
    return passes();
}

// True when the span already stands quoted in the file being written. Reading
// the target costs one open of a file the writer is already touching, and it
// is the only record of a quote that predates every attestation.
bool spanStandsInFile(const(char)[] input, const(char)[] span) {
    import parse : extractFilePath;
    import core.stdc.stdio : fopen, fread, fclose;
    import zbuf : ZBuf;

    auto path = extractFilePath(input);
    if (path is null || path.length == 0 || path.length > 1000) return false;

    // Copied a character at a time. A slice assignment calls into druntime for
    // _d_array_slice_copy, which -betterC does not link.
    __gshared char[1024] pathBuf = 0;
    foreach (i, c; path) pathBuf[i] = c;
    pathBuf[path.length] = 0;

    auto f = fopen(&pathBuf[0], "rb");
    if (f is null) return false;

    __gshared char[262144] fileBuf = 0;
    auto n = fread(&fileBuf[0], 1, fileBuf.length, f);
    fclose(f);
    if (n == 0) return false;

    __gshared ZBuf needle;
    needle.reset();
    needle.put("\"");
    needle.put(span);
    needle.put("\"");
    return contains(fileBuf[0 .. n], needle.slice());
}

enum QUOTE_CLAIMS_MAX = 32;

struct QuoteClaims {
    size_t[QUOTE_CLAIMS_MAX] starts;
    size_t[QUOTE_CLAIMS_MAX] ends;
    size_t count;
    const(char)[] span(const(char)[] written, size_t i) const { return written[starts[i] .. ends[i]]; }
}

// The spans a write claims the user said: quoted, on a line that is prose,
// more than one word, and not already standing in the file. Whether anybody
// did is asked on the node.
QuoteClaims quoteClaims(const(char)[] written, const(char)[] src,
                        scope bool delegate(const(char)[] span) standsInFile) {
    import provenance : nextQuotedSpan, onProseLine, isWord;
    QuoteClaims c;
    size_t from = 0;
    while (c.count < QUOTE_CLAIMS_MAX) {
        auto sp = nextQuotedSpan(written, from);
        if (!sp.ok) break;
        from = sp.end + 1;
        if (sp.end == sp.start) continue;
        if (!onProseLine(written, sp, src)) continue;
        if (isWord(written, sp)) continue;
        if (standsInFile(written[sp.start .. sp.end])) continue;
        c.starts[c.count] = sp.start;
        c.ends[c.count] = sp.end;
        c.count++;
    }
    return c;
}

QuoteClaims quoteClaims(const(char)[] written, const(char)[] src,
                        bool function(const(char)[] span) standsInFile) {
    return quoteClaims(written, src, (const(char)[] s) => standsInFile(s));
}

// What the node is sent: the file and the spans, one JSON object.
void claimsInto(ref ZBuf o, const(char)[] filePath, const(char)[] written, const ref QuoteClaims c) {
    import immediate : putJsonString;
    o.put(`{"file_path":"`);
    putJsonString(o, filePath);
    o.put(`","spans":[`);
    foreach (i; 0 .. c.count) {
        if (i > 0) o.put(",");
        o.put(`"`);
        putJsonString(o, c.span(written, i));
        o.put(`"`);
    }
    o.put("]}");
}

// "Quote needs to pass always, and sky needs to be told later by QNTX that the Quote is nonexistent, if that is true"
// The write passes. What it claims is attested for sky to carry to the node,
// where quote.provenance asks it of the prompts.
enum QUOTE_CLAIMED = "quote:claimed";

// A quoted span asserts the user said it. The write passes; the spans it
// claims are attested for the node to check. With no session or no store the
// claim cannot be recorded, which is said, and the write still passes.
CheckResult quoteProvenance(const(char)[] cwd, const(char)[] input) {
    import parse : extractWrittenText, extractFilePath;
    import db : openDb, sqlite3_close, attestEvent;
    import exec : emitError;

    auto written = extractWrittenText(input);
    if (written is null) return passes();
    auto src = extractFilePath(input);

    auto claims = quoteClaims(written, src, (const(char)[] span) => spanStandsInFile(input, span));
    if (claims.count == 0) return passes();

    if (g_sessionId.length == 0) {
        emitError("quote.claim", "a write claimed quoted spans and ground had no session to file the claim under, so QNTX never checks them",
                  0, 1, "", "quotes-deserve-provenance", "", "", cast(string) src);
        return passes();
    }
    auto db = openDb();
    if (db is null) {
        emitError("quote.claim", "a write claimed quoted spans and ground could not open its store, so QNTX never checks them",
                  0, 1, cast(string) g_sessionId, "quotes-deserve-provenance", "", "", cast(string) src);
        return passes();
    }
    __gshared ZBuf body_;
    body_.reset();
    claimsInto(body_, src, written, claims);
    attestEvent(db, QUOTE_CLAIMED, cwd, g_sessionId, body_.slice(), "quote");
    sqlite3_close(db);
    return passes();
}

CheckResult strikethroughCheck(const(char)[] cwd, const(char)[] input) {
    import parse : extractNewString, extractToolName;
    auto toolName = extractToolName(input);
    if (toolName != "Edit") return passes();
    auto newString = extractNewString(input);
    if (newString is null) return passes();
    return contains(newString, "~~") ? fires() : passes();
}

// Shell constructs Claude Code's Bash allowlist cannot statically decompose.
// Presence of any → the interactive "Contains shell syntax (string) that cannot
// be statically analyzed" halt fires and breaks auto-approve. Pre-reject at
// PreToolUse so the halt is never constructed.
bool containsUnanalyzableShell(const(char)[] command) {
    static immutable string[] markers = [
        "$(", "while ", "until ", "for ", "if [", "case ", "<<",
    ];

    // Quoted text is an argument, not shell. Scanning through it rejected
    // commit messages for containing the English words "for" and "while".
    for (size_t i = 0; i < command.length; i++) {
        if (command[i] == '\'' || command[i] == '"') {
            char q = command[i];
            size_t j = i + 1;
            while (j < command.length && command[j] != q) {
                // Double quotes still interpolate, so $( is live even inside.
                if (q == '"' && command[j] == '$' && j + 1 < command.length
                    && command[j + 1] == '(') return true;
                j++;
            }
            // Unterminated: the rest is not quoted, so keep analysing it.
            if (j >= command.length) continue;
            i = j;
            continue;
        }

        foreach (m; markers) {
            if (i + m.length > command.length) continue;
            if (command[i .. i + m.length] == m) return true;
        }
    }
    return false;
}

// Top-level "&&" separator count. Pbt controls threshold this to enforce
// "one primitive per Bash call" — long chains hide the real command.
int countAndChains(const(char)[] command) {
    int count = 0;
    for (size_t i = 0; i + 1 < command.length; i++) {
        if (command[i] == '&' && command[i + 1] == '&') {
            count++;
            i++;
        }
    }
    return count;
}

CheckResult unanalyzableBash(const(char)[] cwd, const(char)[] input) {
    import parse : extractToolName, extractCommand;
    auto src = input.length > 0 ? input : g_input;
    if (extractToolName(src) != "Bash") return passes();
    auto command = extractCommand(src);
    if (command is null) return passes();
    return containsUnanalyzableShell(command) ? fires() : passes();
}

// Chain depth threshold comes from handler_params { depth: "N" } in the pbt
// control. If `depth` is unset or non-numeric, the handler does not fire —
// no hidden defaults. The chain-depth policy lives in the pbt, not here.
CheckResult deepAndChain(const(char)[] cwd, const(char)[] input) {
    import parse : extractToolName, extractCommand;
    auto src = input.length > 0 ? input : g_input;
    if (extractToolName(src) != "Bash") return passes();
    auto command = extractCommand(src);
    if (command is null) return passes();

    int depth = parseParamInt(lookupParam("depth"));
    if (depth <= 0) return passes();

    return countAndChains(command) >= depth ? fires() : passes();
}

// Cached file list from the last few commits in `cwd`.
// Shared across all `pushed_paths:` matchers in one PostToolUse invocation.
__gshared char[8192] g_pushedFilesBuf = 0;
__gshared size_t g_pushedFilesLen;
__gshared bool g_pushedFilesValid;

const(char)[] pushedFiles(const(char)[] cwd) {
    if (g_pushedFilesValid) return g_pushedFilesBuf[0 .. g_pushedFilesLen];

    import libgit2 : Repo;
    g_pushedFilesValid = true;

    // A failure here is invisible downstream: `pushed_paths:` matchers read an
    // empty list as "this commit touched nothing", so every control gated on
    // it quietly does not fire. The user sees no controls and no reason. Raise
    // it on the axiom's own channel instead of returning a silent empty.
    void reportUnreadable(string why) {
        import errors : GroundError, deliverError;
        import core.stdc.time : time;
        GroundError err;
        err.origin      = "control_handlers.pushedFiles";
        err.message     = why;
        err.exitCode    = -1;
        err.sessionId   = cast(string) g_sessionId;
        err.controlName = "pushed_paths";
        err.timestamp   = cast(long) time(null);
        cast(void) deliverError(err);
    }

    // The last three commits' files, as `git log -3 --name-only` names them.
    __gshared Repo g;
    __gshared char[1024] said = 0;
    const(char)[] refused(const(char)[] why) {
        size_t n;
        foreach (c; why) if (n < said.length) said[n++] = c;
        foreach (c; " — pushed_paths controls did not evaluate") if (n < said.length) said[n++] = c;
        return said[0 .. n];
    }
    if (!g.open(cwd)) {
        g_pushedFilesLen = 0;
        reportUnreadable(cast(string) refused(g.why()));
        return g_pushedFilesBuf[0 .. 0];
    }
    scope (exit) g.close();
    auto names = g.recent(3, g_pushedFilesBuf[]);
    if (names is null) {
        g_pushedFilesLen = 0;
        reportUnreadable(cast(string) refused(g.why()));
        return g_pushedFilesBuf[0 .. 0];
    }
    g_pushedFilesLen = names.length;
    return g_pushedFilesBuf[0 .. g_pushedFilesLen];
}


// --- Deliver handlers ---
// const(char)[] function(cwd) — return message or null to suppress.

// Result of resolving a git remote URL to an owner/repo pair.
//
// The distinction the old code could not express: `repo is null` with
// `problem is null` means there is legitimately nothing to say (no upstream
// configured) and silence is correct. `problem` non-null means we were asked
// for a briefing and could not produce one, which the user is owed.
struct UpstreamParse {
    const(char)[] repo;
    string problem;
}

// Pure — the shelling out stays in upstreamBriefingDeliver.
UpstreamParse parseUpstreamUrl(const(char)[] url) {
    // Trim trailing newline / whitespace from git's output.
    while (url.length > 0 && (url[$ - 1] == '\n' || url[$ - 1] == '\r' || url[$ - 1] == ' '))
        url = url[0 .. $ - 1];

    if (url.length == 0)
        return UpstreamParse(null, null); // no upstream remote — nothing to brief

    int lastGh = -1;
    foreach (i; 0 .. url.length) {
        if (i + 10 <= url.length && url[i .. i + 10] == "github.com")
            lastGh = cast(int) i;
    }
    if (lastGh < 0)
        return UpstreamParse(null, "upstream briefing unavailable: the upstream remote is not a github.com URL, and ground can only query GitHub");

    auto rest = url[lastGh + 10 .. $];
    if (rest.length > 0 && (rest[0] == '/' || rest[0] == ':'))
        rest = rest[1 .. $];
    if (rest.length > 4 && rest[$ - 4 .. $] == ".git")
        rest = rest[0 .. $ - 4];

    if (rest.length == 0)
        return UpstreamParse(null, "upstream briefing unavailable: the upstream remote URL has no owner/repo path");

    __gshared char[128] repoBuf = 0;
    size_t n = rest.length > repoBuf.length ? repoBuf.length : rest.length;
    foreach (i; 0 .. n) repoBuf[i] = rest[i];
    return UpstreamParse(repoBuf[0 .. n], null);
}

unittest {
    // No upstream remote is not a failure. There is legitimately nothing to
    // brief on, so silence is correct and no Error is owed.
    auto r = parseUpstreamUrl("");
    assert(r.repo is null);
    assert(r.problem is null, "absence of an upstream is not an error");
}

unittest {
    // ssh remote
    auto r = parseUpstreamUrl("git@github.com:teranos/QNTX.git");
    assert(r.repo == "teranos/QNTX");
    assert(r.problem is null);
}

unittest {
    // https remote, no .git suffix
    auto r = parseUpstreamUrl("https://github.com/teranos/QNTX");
    assert(r.repo == "teranos/QNTX");
    assert(r.problem is null);
}

unittest {
    // An upstream exists but we cannot address it. Returning silence here is
    // the swallow: the control was asked for a briefing and the user learns
    // neither the briefing nor why there isn't one.
    auto r = parseUpstreamUrl("git@gitlab.com:foo/bar.git");
    assert(r.repo is null);
    assert(r.problem !is null, "an unusable upstream must be reported");
}

const(char)[] upstreamBriefingDeliver(const(char)[] cwd) {
    import db : popen, pclose, ZBuf;
    import core.stdc.stdio : fread, FILE;
    import libgit2 : Repo;

    // The upstream remote and what it has that main does not, read in this
    // process by libgit2; gh asks GitHub for the rest.
    __gshared Repo g;
    if (!g.open(cwd)) return null; // no repository is no upstream to brief
    scope (exit) g.close();
    auto upstreamUrl = g.remoteUrl("upstream");
    auto parsed = parseUpstreamUrl(upstreamUrl is null ? "" : upstreamUrl);
    if (parsed.problem !is null) return parsed.problem;
    if (parsed.repo is null) return null; // no upstream configured — nothing to brief
    auto repo = parsed.repo;

    __gshared ZBuf ghCmd;
    ghCmd.reset();
    ghCmd.put("cd \"");
    ghCmd.put(cwd);
    ghCmd.put("\" && echo 'PRs:' && gh pr list -R ");
    ghCmd.put(repo);
    ghCmd.put(" --limit 10 --state all --json number,title,state --jq '.[] | \"#\\(.number) [\\(.state)] \\(.title)\"' 2>/dev/null");
    ghCmd.put(" && echo 'Issues:' && gh issue list -R ");
    ghCmd.put(repo);
    ghCmd.put(" --limit 10 --json number,title,state --jq '.[] | \"#\\(.number) [\\(.state)] \\(.title)\"' 2>/dev/null");
    ghCmd.put(" && echo 'Releases:' && gh release list -R ");
    ghCmd.put(repo);
    ghCmd.put(" --limit 3 2>/dev/null");
    ghCmd.putChar('\0');

    auto pipe = popen(ghCmd.ptr(), "r");
    if (pipe is null)
        return "upstream briefing unavailable: could not run gh";

    __gshared char[3072] outBuf = 0;
    auto n = fread(&outBuf[0], 1, outBuf.length - 1, pipe);
    auto ghStatus = pclose(pipe);
    // Same trap as checkCIStatus had: empty output alone cannot tell "nothing
    // to report" from "gh failed". The exit status can, so keep it.
    if (ghStatus != 0)
        return "upstream briefing unavailable: gh exited non-zero (auth or network?)";
    if (n == 0)
        return "upstream briefing unavailable: gh returned nothing";

    // What upstream's main has that main does not.
    __gshared ZBuf unavailable;
    unavailable.reset();
    unavailable.put("upstream briefing unavailable: ");
    if (!g.fetch("upstream", null)) { unavailable.put(g.why()); return unavailable.slice(); }
    __gshared char[2048] missing = 0;
    auto log = g.oneline("main", "upstream/main", missing[]);
    if (log is null) { unavailable.put(g.why()); return unavailable.slice(); }
    enum head = "Commits (missing):\n";
    if (n + head.length < outBuf.length - 1) foreach (c; head) outBuf[n++] = c;
    foreach (c; log) if (n < outBuf.length - 1) outBuf[n++] = c;
    if (log.length > 0 && n < outBuf.length - 1) outBuf[n++] = '\n';

    __gshared ZBuf result;
    result.reset();
    result.put("Upstream briefing (");
    result.put(repo);
    result.put("): ");
    result.put(outBuf[0 .. n]);
    return result.slice();
}
