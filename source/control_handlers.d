module control_handlers;

import matcher : contains;

// Set by PreToolUse handler before calling checkAllCommands.
__gshared const(char)[] g_sessionId;

// --- Check handlers ---
// bool function(cwd, input) — return true to fire the control.

extern (C) int access(const(char)* path, int mode);

bool binaryShadowed(const(char)[] cwd, const(char)[] input) {
    enum F_OK = 0;
    return access("/usr/local/bin/ground\0".ptr, F_OK) == 0;
}

bool commitNotRequested(const(char)[] cwd, const(char)[] input) {
    // No session — can't check, don't block
    if (g_sessionId.length == 0) return false;

    import db : openDb, sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_bind_int64,
                sqlite3_step, sqlite3_column_int64, sqlite3_finalize, sqlite3_close,
                sqlite3_stmt, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    import zbuf : ZBuf;

    auto db = openDb();
    if (db is null) return true; // can't check, deny

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
    enum last3Sql = "SELECT json_extract(attributes, '$.prompt') FROM attestations WHERE json_extract(predicates, '$[0]') = 'UserPromptSubmit' AND json_extract(contexts, '$[0]') = ?1 AND rowid > ?2 ORDER BY rowid DESC LIMIT 3\0";

    import db : sqlite3_column_text;
    sqlite3_stmt* userStmt;
    bool userSaid = false;
    if (sqlite3_prepare_v2(db, last3Sql.ptr, -1, &userStmt, null) == SQLITE_OK) {
        sqlite3_bind_text(userStmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
        sqlite3_bind_int64(userStmt, 2, lastCommitRowid);
        while (sqlite3_step(userStmt) == SQLITE_ROW) {
            auto text = sqlite3_column_text(userStmt, 0);
            if (text !is null) {
                size_t tlen = 0;
                while (text[tlen] != 0) tlen++;
                if (isCommitApproval(text[0 .. tlen])) {
                    userSaid = true;
                    break;
                }
            }
        }
        sqlite3_finalize(userStmt);
    }

    sqlite3_close(db);

    // Fire (deny) if user did NOT approve a commit
    return !userSaid;
}

// Returns true if message is a commit approval: contains "commit", or is bare "ok"/"y".
bool isCommitApproval(const(char)[] msg) {
    if (contains(msg, "commit")) return true;

    // Trim whitespace
    size_t start = 0;
    while (start < msg.length && (msg[start] == ' ' || msg[start] == '\t' || msg[start] == '\n' || msg[start] == '\r'))
        start++;
    size_t end = msg.length;
    while (end > start && (msg[end - 1] == ' ' || msg[end - 1] == '\t' || msg[end - 1] == '\n' || msg[end - 1] == '\r'))
        end--;
    auto trimmed = msg[start .. end];

    return trimmed == "ok" || trimmed == "y" || trimmed == "sure";
}

bool strikethroughCheck(const(char)[] cwd, const(char)[] input) {
    import parse : extractNewString, extractToolName;
    auto toolName = extractToolName(input);
    if (toolName != "Edit") return false;
    auto newString = extractNewString(input);
    if (newString is null) return false;
    return contains(newString, "~~");
}

// --- Delay handlers ---
// int function(cwd) — return delay in seconds.

int ciDelay(const(char)[] cwd) {
    import deferred : getCIAvgDuration, computeDelay;
    import db : getBranch;
    auto branch = getBranch(cwd);
    if (branch is null) return 60;
    return computeDelay(getCIAvgDuration(cwd, branch));
}

// --- Deliver handlers ---
// const(char)[] function(cwd) — return message or null to suppress.

const(char)[] ciDeliver(const(char)[] cwd) {
    import deferred : checkCIStatus;
    import db : getBranch;
    auto branch = getBranch(cwd);
    if (branch is null) return null;
    return checkCIStatus(cwd, branch);
}

const(char)[] upstreamBriefingDeliver(const(char)[] cwd) {
    import db : popen, pclose, ZBuf;
    import core.stdc.stdio : fread, FILE;

    // Get upstream repo owner/name
    __gshared ZBuf repoCmd;
    repoCmd.reset();
    repoCmd.put("cd \"");
    repoCmd.put(cwd);
    repoCmd.put("\" && git remote get-url upstream 2>/dev/null");
    repoCmd.putChar('\0');

    auto repoPipe = popen(repoCmd.ptr(), "r");
    if (repoPipe is null) return null;

    __gshared char[256] repoBuf = 0;
    auto rn = fread(&repoBuf[0], 1, repoBuf.length - 1, repoPipe);
    pclose(repoPipe);
    if (rn == 0) return null;
    if (repoBuf[rn - 1] == '\n') rn--;
    if (rn == 0) return null;

    __gshared char[128] ownerRepo = 0;
    size_t orLen = 0;
    {
        auto url = repoBuf[0 .. rn];
        int lastGh = -1;
        foreach (i; 0 .. url.length) {
            if (i + 10 <= url.length && url[i .. i + 10] == "github.com")
                lastGh = cast(int) i;
        }
        if (lastGh < 0) return null;
        auto rest = url[lastGh + 10 .. $];
        if (rest.length > 0 && (rest[0] == '/' || rest[0] == ':'))
            rest = rest[1 .. $];
        if (rest.length > 4 && rest[$ - 4 .. $] == ".git")
            rest = rest[0 .. $ - 4];
        foreach (c; rest) {
            if (orLen < ownerRepo.length) ownerRepo[orLen++] = c;
        }
    }
    if (orLen == 0) return null;
    auto repo = ownerRepo[0 .. orLen];

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
    ghCmd.put(" && echo 'Commits (missing):' && git fetch upstream 2>/dev/null && git log --oneline main..upstream/main 2>/dev/null");
    ghCmd.putChar('\0');

    auto pipe = popen(ghCmd.ptr(), "r");
    if (pipe is null) return null;

    __gshared char[3072] outBuf = 0;
    auto n = fread(&outBuf[0], 1, outBuf.length - 1, pipe);
    pclose(pipe);
    if (n == 0) return null;

    __gshared ZBuf result;
    result.reset();
    result.put("Upstream briefing (");
    result.put(repo);
    result.put("): ");
    result.put(outBuf[0 .. n]);
    return result.slice();
}
