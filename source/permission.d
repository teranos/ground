module permission;

import matcher : wildcardContains, stripQuoted, contains;
import proto : ParseResult, ParsedPermission, parsePbt;

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
    string path;
    const(Permission)[] permissions;
}

// --- Permission set (built at CTFE from parsed pbt) ---

struct PermissionSet {
    PermissionScope[64] items;
    Permission[128] permPool;
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
        foreach (j; 0 .. ps.permissionCount) {
            auto pp = &ps.permissions[j];
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
        result.items[result.len] = PermissionScope(ps.path, result.permPool[permStart .. poolLen]);
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
        if (!scopeMatches(sc.path, cwd)) continue;

        foreach (ref p; sc.permissions) {
            if (p.mode.length > 0) {
                import posttooluse : modeMatches;
                if (!modeMatches(p.mode, toolName)) continue;
            }
            // no mode = match all tools

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

// --- CTFE tests ---

// Build + evaluate test via parsed pbt
enum testPermPbt = `
scope {
  path: "/"
  permission {
    allow: ["go build*", "go test*"]
    deny: ["*rm -rf*"]
    ask: ["*DELETE*"]
    msg: "Destructive op"
  }
}

scope {
  path: "/only-here"
  permission {
    allow: ["npm run*"]
  }
}
`;

enum testPermParsed = parsePbt(testPermPbt);
enum testPermSet = buildPermissions(testPermParsed);
static assert(testPermSet.len == 2);
static assert(testPermSet.items[0].path == "/");
static assert(testPermSet.items[0].permissions.length == 1);
static assert(testPermSet.items[0].permissions[0].mode == "");
static assert(testPermSet.items[0].permissions[0].allow.len == 2);
static assert(testPermSet.items[0].permissions[0].deny.len == 1);
static assert(testPermSet.items[0].permissions[0].ask.len == 1);

// Allow match
enum r1 = evaluatePermission(testPermSet[], "/home/user/project", "Bash", "go build ./...");
static assert(r1.decision == Decision.allow);

// No match
enum r2 = evaluatePermission(testPermSet[], "/home/user/project", "Bash", "echo hello");
static assert(r2.decision == Decision.none);

// Deny wins — "rm -rf" matches deny even though nothing matches allow
enum r3 = evaluatePermission(testPermSet[], "/home/user/project", "Bash", "rm -rf /tmp");
static assert(r3.decision == Decision.deny);
static assert(r3.msg == "Destructive op");

// Ask — "DELETE" matches ask
enum r4 = evaluatePermission(testPermSet[], "/home/user/project", "Bash", "sqlite3 db DELETE FROM foo");
static assert(r4.decision == Decision.ask);

// No mode but Write tool — command patterns don't match file paths
enum r5 = evaluatePermission(testPermSet[], "/home/user/project", "Write", "go build");
static assert(r5.decision == Decision.none);

// Scope mismatch — npm rule only in /only-here
enum r6 = evaluatePermission(testPermSet[], "/home/user/other", "Bash", "npm run test");
static assert(r6.decision == Decision.none);

// Scope match — npm rule fires in /only-here
enum r7 = evaluatePermission(testPermSet[], "/home/user/only-here", "Bash", "npm run test");
static assert(r7.decision == Decision.allow);

// Deny + allow in same permission — deny wins
enum r8 = evaluatePermission(testPermSet[], "/home/user/project", "Bash", "go build && rm -rf /tmp");
static assert(r8.decision == Decision.deny);

// Quoted content ignored — "rm -rf" inside a commit message does NOT trigger deny
enum r9 = evaluatePermission(testPermSet[], "/home/user/project", "Bash", `git commit -m "rm -rf cleanup"`);
static assert(r9.decision == Decision.none);

// Quoted content ignored — deny pattern in unquoted part still fires
enum r10 = evaluatePermission(testPermSet[], "/home/user/project", "Bash", `rm -rf /tmp && echo "done"`);
static assert(r10.decision == Decision.deny);

// --- Name inference tests ---

// No explicit name — inferred from first pattern in the permission block ("go build*" → "go build")
static assert(r1.name == "go build"); // allow match
static assert(r3.name == "go build"); // deny match — name is per-block, not per-list
static assert(r4.name == "go build"); // ask match — same block, same inferred name

// Explicit name overrides inference
enum namedPermPbt = `
scope {
  path: "/"
  permission {
    name: "go-toolchain"
    allow: ["go build*", "go test*"]
  }
  permission {
    name: "destructive-sql"
    allow: ["sqlite3*"]
    ask: ["sqlite3*DELETE*"]
  }
}
`;
enum namedParsed = parsePbt(namedPermPbt);
enum namedSet = buildPermissions(namedParsed);

enum n1 = evaluatePermission(namedSet[], "/home/user/project", "Bash", "go build ./...");
static assert(n1.decision == Decision.allow);
static assert(n1.name == "go-toolchain");

enum n2 = evaluatePermission(namedSet[], "/home/user/project", "Bash", "sqlite3 db DELETE FROM foo");
static assert(n2.decision == Decision.ask);
static assert(n2.name == "destructive-sql");

// No match — name stays empty
enum n3 = evaluatePermission(namedSet[], "/home/user/project", "Bash", "echo hello");
static assert(n3.decision == Decision.none);

// --- Path matching tests (Read/Write/Edit) ---

enum pathPermPbt = `
scope {
  path: "/"
  permission.r {
    deny: [".env", ".env.*", "secrets/*"]
    msg: "Secrets are off-limits"
  }
}
`;
enum pathParsed = parsePbt(pathPermPbt);
enum pathSet = buildPermissions(pathParsed);

// .env at project root
enum p1 = evaluatePermission(pathSet[], "/home/user/project", "Read", "/home/user/project/.env");
static assert(p1.decision == Decision.deny);

// .env.local matches .env.*
enum p2 = evaluatePermission(pathSet[], "/home/user/project", "Read", "/home/user/project/.env.local");
static assert(p2.decision == Decision.deny);

// secrets/config.json matches secrets/*
enum p3 = evaluatePermission(pathSet[], "/home/user/project", "Read", "/home/user/project/secrets/config.json");
static assert(p3.decision == Decision.deny);

// Normal file — no match
enum p4 = evaluatePermission(pathSet[], "/home/user/project", "Read", "/home/user/project/src/main.d");
static assert(p4.decision == Decision.none);

// .env buried in path — still matches
enum p5 = evaluatePermission(pathSet[], "/home/user/project", "Read", "/other/project/.env");
static assert(p5.decision == Decision.deny);

// .environment — should NOT match .env (not a suffix match)
enum p6 = evaluatePermission(pathSet[], "/home/user/project", "Read", "/home/user/project/.environment");
static assert(p6.decision == Decision.none);

// nosecrets/ — should NOT match secrets/* (anchored to path component)
enum p7 = evaluatePermission(pathSet[], "/home/user/project", "Read", "/home/user/project/nosecrets/foo");
static assert(p7.decision == Decision.none);
static assert(n3.name == "");

// --- git -C normalization tests ---

// "git -C /path log" should match "git log*" permission
enum gitCPermPbt = `
scope {
  path: "/"
  permission {
    allow: ["git log*", "git status*", "git diff*"]
  }
}
`;
enum gitCParsed = parsePbt(gitCPermPbt);
enum gitCSet = buildPermissions(gitCParsed);

// Direct git command — matches
enum gc1 = evaluatePermission(gitCSet[], "/home/user/project", "Bash", "git log --oneline");
static assert(gc1.decision == Decision.allow);

// git -C — should also match after normalization
enum gc2 = evaluatePermission(gitCSet[], "/home/user/project", "Bash", "git -C /other/repo log --oneline");
static assert(gc2.decision == Decision.allow);

// git -C with status
enum gc3 = evaluatePermission(gitCSet[], "/home/user/project", "Bash", "git -C /foo/bar status");
static assert(gc3.decision == Decision.allow);

// git -C with diff
enum gc4 = evaluatePermission(gitCSet[], "/home/user/project", "Bash", "git -C /some/path diff HEAD~1");
static assert(gc4.decision == Decision.allow);

// git -C with unmatched subcommand — no match
enum gc5 = evaluatePermission(gitCSet[], "/home/user/project", "Bash", "git -C /foo push origin main");
static assert(gc5.decision == Decision.none);

// git -C with quoted path
enum gc6 = evaluatePermission(gitCSet[], "/home/user/project", "Bash", `git -C "/path with spaces/repo" log`);
static assert(gc6.decision == Decision.allow);
