module controls;

public import hooks;
import proto : parsePbt, buildScopes, ScopeSet;
import permission : buildPermissions, PermissionSet;

// --- Parsed pbt (CTFE) ---
// Pre-build: cat controls/*.pbt > .ctfe/sand

enum allParsed = parsePbt(import(".ctfe/sand"));

// --- Handler resolvers (CTFE) ---

CheckFn resolveCheck(string name) {
    switch (name) {
        case "binaryShadowed": return &binaryShadowed;
        default: return null;
    }
}

DelayFn resolveDelay(string name) {
    switch (name) {
        case "ciDelay": return &ciDelay;
        default: return null;
    }
}

DeliverFn resolveDeliver(string name) {
    switch (name) {
        case "ciDeliver": return &ciDeliver;
        case "upstreamBriefingDeliver": return &upstreamBriefingDeliver;
        default: return null;
    }
}

// --- Scope arrays (CTFE) ---

// TODO: catch hardcoded URLs in error messages that claim to report runtime values

private static immutable _preToolSet = buildScopes!(resolveCheck, resolveDelay, resolveDeliver)(allParsed, "PreToolUse");
static immutable allScopes = _preToolSet.items[0 .. _preToolSet.len];

private static immutable _fileSet = buildScopes(allParsed, "PreToolUseFile");
static immutable fileScopes = _fileSet.items[0 .. _fileSet.len];

private static immutable _upSet = buildScopes(allParsed, "UserPromptSubmit");
static immutable userPromptScopes = _upSet.items[0 .. _upSet.len];

private static immutable _stopSet = buildScopes!(resolveCheck, resolveDelay, resolveDeliver)(allParsed, "Stop");
static immutable stopScopes = _stopSet.items[0 .. _stopSet.len];

private static immutable _ssSet = buildScopes!(resolveCheck, resolveDelay, resolveDeliver)(allParsed, "SessionStart");
static immutable sessionStartScopes = _ssSet.items[0 .. _ssSet.len];

private static immutable _ptuSet = buildScopes(allParsed, "PostToolUse");
static immutable postToolUseScopes = _ptuSet.items[0 .. _ptuSet.len];

private static immutable _ptudSet = buildScopes!(resolveCheck, resolveDelay, resolveDeliver)(allParsed, "PostToolUseDeferred");
static immutable postToolUseDeferredScopes = _ptudSet.items[0 .. _ptudSet.len];

private static immutable _ptufSet = buildScopes(allParsed, "PostToolUseFailure");
static immutable postToolUseFailureScopes = _ptufSet.items[0 .. _ptufSet.len];

private static immutable _pcSet = buildScopes(allParsed, "PreCompact");
static immutable preCompactScopes = _pcSet.items[0 .. _pcSet.len];

private static immutable _permSet = buildPermissions(allParsed);
static immutable permissionScopes = _permSet.items[0 .. _permSet.len];

// --- Handler functions ---

int ciDelay(const(char)[] cwd) {
    import deferred : getCIAvgDuration, computeDelay;
    import db : getBranch;
    auto branch = getBranch(cwd);
    if (branch is null) return 60;
    return computeDelay(getCIAvgDuration(cwd, branch));
}

const(char)[] ciDeliver(const(char)[] cwd) {
    import deferred : checkCIStatus;
    import db : getBranch;
    auto branch = getBranch(cwd);
    if (branch is null) return null;
    return checkCIStatus(cwd, branch);
}

// --- Check functions for sessionstart() controls ---

extern (C) int access(const(char)* path, int mode);

bool binaryShadowed(const(char)[] cwd) {
    enum F_OK = 0;
    return access("/usr/local/bin/ground\0".ptr, F_OK) == 0;
}

// --- Upstream briefing ---

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

    // Extract owner/repo from URL
    // Handles https://github.com/owner/repo.git and git@github.com:owner/repo.git
    __gshared char[128] ownerRepo = 0;
    size_t orLen = 0;
    {
        auto url = repoBuf[0 .. rn];
        // Find last github.com occurrence, skip past it
        int lastGh = -1;
        foreach (i; 0 .. url.length) {
            if (i + 10 <= url.length && url[i .. i + 10] == "github.com")
                lastGh = cast(int) i;
        }
        if (lastGh < 0) return null;
        auto rest = url[lastGh + 10 .. $]; // after "github.com"
        if (rest.length > 0 && (rest[0] == '/' || rest[0] == ':'))
            rest = rest[1 .. $];
        // Strip .git suffix
        if (rest.length > 4 && rest[$ - 4 .. $] == ".git")
            rest = rest[0 .. $ - 4];
        foreach (c; rest) {
            if (orLen < ownerRepo.length) ownerRepo[orLen++] = c;
        }
    }
    if (orLen == 0) return null;
    auto repo = ownerRepo[0 .. orLen];

    // Run gh commands
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
