module permission;

import matcher : wildcardContains, stripQuoted, contains;
import proto : ParseResult, ParsedPermission;

// --- Runtime permission structs ---

struct PatternList {
    string[16] _buf;
    ubyte len;
    const(string)[] values() const return { return _buf[0 .. len]; }
}

struct Permission {
    string name;
    string mode;
    PatternList allow;
    PatternList deny;
    PatternList ask;
    string msg;
}

struct PermissionScope {
    string[8] paths;
    ubyte pathCount;
    const(Permission)[] permissions;
}

// --- Permission set (built at CTFE from parsed pbt) ---

struct PermissionSet {
    import count : PbtCounts;
    import proto : pbtCounts;
    PermissionScope[pbtCounts.totalScopes + 1] items;
    Permission[pbtCounts.totalPerms + 1] permPool;
    size_t len;

    const(PermissionScope)[] opSlice() const return { return items[0 .. len]; }
}

PermissionSet buildPermissions(const ParseResult parsed) {
    PermissionSet result;
    size_t poolLen = 0;

    foreach (i; 0 .. parsed.scopeCount) {
        auto ps = &parsed.scopes[i];
        if (ps.permissionCount == 0) continue;

        auto permStart = poolLen;
        foreach (j; ps.permStart .. ps.permEnd) {
            auto pp = &parsed.permPool[j];
            Permission p;
            p.name = pp.name;
            p.mode = pp.mode;
            p.msg = pp.msg;

            p.allow._buf = pp.allow;
            p.allow.len = pp.allowCount;
            p.deny._buf = pp.deny;
            p.deny.len = pp.denyCount;
            p.ask._buf = pp.ask;
            p.ask.len = pp.askCount;

            assert(poolLen < result.permPool.length);
            result.permPool[poolLen] = p;
            poolLen++;
        }

        assert(result.len < result.items.length);
        PermissionScope psc;
        psc.paths = ps.paths;
        psc.pathCount = ps.pathCount;
        psc.permissions = result.permPool[permStart .. poolLen];
        result.items[result.len] = psc;
        result.len++;
    }
    return result;
}

// --- Permission evaluation ---
// Returns "deny", "ask", "allow", or null (no match — fall through).
// Precedence: deny > ask > allow.

enum Decision { none, allow, ask, deny }

struct PermissionResult {
    Decision decision;
    const(char)[] name;
    const(char)[] msg; // only set on deny
}

// Match a wildcard pattern anchored at the start of haystack.
// "secrets/*" matches "secrets/config.json" but NOT "nosecrets/foo".
bool wildcardMatchAnchored(const(char)[] haystack, const(char)[] pattern) {
    size_t hi = 0, pi = 0;
    size_t starIdx = size_t.max, matchPos = 0;

    while (hi < haystack.length) {
        if (pi < pattern.length && pattern[pi] == '*') {
            starIdx = pi++;
            matchPos = hi;
        } else if (pi < pattern.length && haystack[hi] == pattern[pi]) {
            hi++; pi++;
        } else if (starIdx != size_t.max) {
            pi = starIdx + 1;
            hi = ++matchPos;
        } else {
            return false;
        }
    }
    while (pi < pattern.length && pattern[pi] == '*') pi++;
    return pi == pattern.length;
}

// Match a permission pattern against a value.
// For Bash: uses stripQuoted + wildcardContains (substring match).
// For file-path tools: relative patterns (no leading / or *) match as path suffixes.
// TODO: if extractFilePath ever returns relative paths, permMatch silently misses — all
//       deny rules require a '/' before the pattern. Add leading-slash assertion or fallback.
bool permMatch(const(char)[] value, const(char)[] pat) {
    if (pat.length == 0) return false;
    // Absolute or wildcard patterns — match directly
    if (pat[0] == '/' || pat[0] == '*')
        return wildcardContains(value, pat);
    // Relative pattern — match as path suffix: "/.env" at end, "/secrets/" in path
    // Anchored: "secrets/*" matches after "/" only at start of component, not "nosecrets/"
    bool hasWild = contains(pat, "*");
    foreach (i; 0 .. value.length) {
        if (value[i] != '/') continue;
        auto rest = value[i + 1 .. $];
        if (rest.length < pat.length) continue;
        if (hasWild) {
            if (wildcardMatchAnchored(rest, pat)) return true;
        } else {
            if (rest[0 .. pat.length] == pat) {
                if (rest.length == pat.length) return true;
                if (rest[pat.length] == '/') return true;
            }
        }
    }
    return false;
}

// Normalize "git -C <path> <subcmd>" → "git <subcmd>" so permissions don't need -C variants.
// Returns a struct with a static buffer (no GC). Input unchanged if not a git -C command.
struct NormalizedCmd {
    char[512] _buf;
    size_t len;
    const(char)[] slice() const return { return _buf[0 .. len]; }
}

NormalizedCmd normalizeGitC(const(char)[] cmd) {
    NormalizedCmd r;

    // Not a git -C command — copy as-is
    if (cmd.length < 8 || cmd[0 .. 4] != "git " || cmd[4 .. 6] != "-C") {
        auto n = cmd.length < r._buf.length ? cmd.length : r._buf.length;
        r._buf[0 .. n] = cmd[0 .. n];
        r.len = n;
        return r;
    }

    // Skip "-C" and optional space
    size_t i = 6;
    if (i < cmd.length && cmd[i] == ' ') i++;

    // Skip the path argument (possibly quoted)
    if (i < cmd.length && cmd[i] == '"') {
        i++;
        while (i < cmd.length && cmd[i] != '"') i++;
        if (i < cmd.length) i++;
    } else {
        while (i < cmd.length && cmd[i] != ' ') i++;
    }

    // Skip space after path
    if (i < cmd.length && cmd[i] == ' ') i++;

    if (i >= cmd.length) {
        auto n = cmd.length < r._buf.length ? cmd.length : r._buf.length;
        r._buf[0 .. n] = cmd[0 .. n];
        r.len = n;
        return r;
    }

    // "git " + rest
    r._buf[0 .. 4] = "git ";
    auto rest = cmd[i .. $];
    auto n = rest.length < (r._buf.length - 4) ? rest.length : (r._buf.length - 4);
    r._buf[4 .. 4 + n] = rest[0 .. n];
    r.len = 4 + n;
    return r;
}

PermissionResult evaluatePermission(
    const(PermissionScope)[] scopes,
    const(char)[] cwd,
    const(char)[] toolName,
    const(char)[] command,
) {
    import hooks : scopeMatches;

    // Strip double-quoted content so patterns match commands, not their string arguments
    auto stripped = stripQuoted(command);
    auto normalized = normalizeGitC(stripped.slice);
    auto cmd = normalized.slice;

    PermissionResult result;

    foreach (ref sc; scopes) {
        if (!scopeMatches(sc, cwd)) continue;

        foreach (ref p; sc.permissions) {
            if (p.mode.length > 0) {
                import posttooluse : modeMatches;
                if (!modeMatches(p.mode, toolName)) continue;
            } else {
                // no mode = Bash only
                if (toolName != "Bash") continue;
            }

            // Bash: match against stripped command with wildcardContains
            // File-path tools: match against raw path with permMatch
            bool isBash = (toolName == "Bash");

            // Check deny first
            foreach (ref pat; p.deny.values) {
                if (isBash ? wildcardContains(cmd, pat) : permMatch(command, pat)) {
                    return PermissionResult(Decision.deny, p.name, p.msg);
                }
            }

            // Check ask
            foreach (ref pat; p.ask.values) {
                if (isBash ? wildcardContains(cmd, pat) : permMatch(command, pat)) {
                    if (result.decision < Decision.ask) {
                        result.decision = Decision.ask;
                        result.name = p.name;
                    }
                }
            }

            // Check allow
            foreach (ref pat; p.allow.values) {
                if (isBash ? wildcardContains(cmd, pat) : permMatch(command, pat)) {
                    if (result.decision < Decision.allow) {
                        result.decision = Decision.allow;
                        result.name = p.name;
                    }
                }
            }
        }
    }

    return result;
}

