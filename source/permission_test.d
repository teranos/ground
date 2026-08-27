module permission_test;

import permission : buildPermissions, evaluatePermission, Decision;
import proto : parsePbt;
import sessionmode : SessionMode;

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
static assert(testPermSet.items[0].paths[0] == "/");
static assert(testPermSet.items[0].permissions.length == 1);
static assert(testPermSet.items[0].permissions[0].mode == "");
static assert(testPermSet.items[0].permissions[0].allow.len == 2);
static assert(testPermSet.items[0].permissions[0].deny.len == 1);
static assert(testPermSet.items[0].permissions[0].ask.len == 1);

// Allow match
enum r1 = evaluatePermission(testPermSet[], "/home/user/project", "Bash", "go build ./...", SessionMode.acceptEdits);
static assert(r1.decision == Decision.allow);

// No match
enum r2 = evaluatePermission(testPermSet[], "/home/user/project", "Bash", "echo hello", SessionMode.acceptEdits);
static assert(r2.decision == Decision.none);

// Deny wins — "rm -rf" matches deny even though nothing matches allow
enum r3 = evaluatePermission(testPermSet[], "/home/user/project", "Bash", "rm -rf /tmp", SessionMode.acceptEdits);
static assert(r3.decision == Decision.deny);
static assert(r3.msg == "Destructive op");

// Ask — "DELETE" matches ask
enum r4 = evaluatePermission(testPermSet[], "/home/user/project", "Bash", "sqlite3 db DELETE FROM foo", SessionMode.acceptEdits);
static assert(r4.decision == Decision.ask);

// No mode but Write tool — command patterns don't match file paths
enum r5 = evaluatePermission(testPermSet[], "/home/user/project", "Write", "go build", SessionMode.acceptEdits);
static assert(r5.decision == Decision.none);

// Scope mismatch — npm rule only in /only-here
enum r6 = evaluatePermission(testPermSet[], "/home/user/other", "Bash", "npm run test", SessionMode.acceptEdits);
static assert(r6.decision == Decision.none);

// Scope match — npm rule fires in /only-here
enum r7 = evaluatePermission(testPermSet[], "/home/user/only-here", "Bash", "npm run test", SessionMode.acceptEdits);
static assert(r7.decision == Decision.allow);

// Deny + allow in same permission — deny wins
enum r8 = evaluatePermission(testPermSet[], "/home/user/project", "Bash", "go build && rm -rf /tmp", SessionMode.acceptEdits);
static assert(r8.decision == Decision.deny);

// Quoted content ignored — "rm -rf" inside a commit message does NOT trigger deny
enum r9 = evaluatePermission(testPermSet[], "/home/user/project", "Bash", `git commit -m "rm -rf cleanup"`, SessionMode.acceptEdits);
static assert(r9.decision == Decision.none);

// Quoted content ignored — deny pattern in unquoted part still fires
enum r10 = evaluatePermission(testPermSet[], "/home/user/project", "Bash", `rm -rf /tmp && echo "done"`, SessionMode.acceptEdits);
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

enum n1 = evaluatePermission(namedSet[], "/home/user/project", "Bash", "go build ./...", SessionMode.acceptEdits);
static assert(n1.decision == Decision.allow);
static assert(n1.name == "go-toolchain");

enum n2 = evaluatePermission(namedSet[], "/home/user/project", "Bash", "sqlite3 db DELETE FROM foo", SessionMode.acceptEdits);
static assert(n2.decision == Decision.ask);
static assert(n2.name == "destructive-sql");

// No match — name stays empty
enum n3 = evaluatePermission(namedSet[], "/home/user/project", "Bash", "echo hello", SessionMode.acceptEdits);
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
enum p1 = evaluatePermission(pathSet[], "/home/user/project", "Read", "/home/user/project/.env", SessionMode.acceptEdits);
static assert(p1.decision == Decision.deny);

// .env.local matches .env.*
enum p2 = evaluatePermission(pathSet[], "/home/user/project", "Read", "/home/user/project/.env.local", SessionMode.acceptEdits);
static assert(p2.decision == Decision.deny);

// secrets/config.json matches secrets/*
enum p3 = evaluatePermission(pathSet[], "/home/user/project", "Read", "/home/user/project/secrets/config.json", SessionMode.acceptEdits);
static assert(p3.decision == Decision.deny);

// Normal file — no match
enum p4 = evaluatePermission(pathSet[], "/home/user/project", "Read", "/home/user/project/src/main.d", SessionMode.acceptEdits);
static assert(p4.decision == Decision.none);

// .env buried in path — still matches
enum p5 = evaluatePermission(pathSet[], "/home/user/project", "Read", "/other/project/.env", SessionMode.acceptEdits);
static assert(p5.decision == Decision.deny);

// .environment — should NOT match .env (not a suffix match)
enum p6 = evaluatePermission(pathSet[], "/home/user/project", "Read", "/home/user/project/.environment", SessionMode.acceptEdits);
static assert(p6.decision == Decision.none);

// nosecrets/ — should NOT match secrets/* (anchored to path component)
enum p7 = evaluatePermission(pathSet[], "/home/user/project", "Read", "/home/user/project/nosecrets/foo", SessionMode.acceptEdits);
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
enum gc1 = evaluatePermission(gitCSet[], "/home/user/project", "Bash", "git log --oneline", SessionMode.acceptEdits);
static assert(gc1.decision == Decision.allow);

// git -C — should also match after normalization
enum gc2 = evaluatePermission(gitCSet[], "/home/user/project", "Bash", "git -C /other/repo log --oneline", SessionMode.acceptEdits);
static assert(gc2.decision == Decision.allow);

// git -C with status
enum gc3 = evaluatePermission(gitCSet[], "/home/user/project", "Bash", "git -C /foo/bar status", SessionMode.acceptEdits);
static assert(gc3.decision == Decision.allow);

// git -C with diff
enum gc4 = evaluatePermission(gitCSet[], "/home/user/project", "Bash", "git -C /some/path diff HEAD~1", SessionMode.acceptEdits);
static assert(gc4.decision == Decision.allow);

// git -C with unmatched subcommand — no match
enum gc5 = evaluatePermission(gitCSet[], "/home/user/project", "Bash", "git -C /foo push origin main", SessionMode.acceptEdits);
static assert(gc5.decision == Decision.none);

// git -C with quoted path
enum gc6 = evaluatePermission(gitCSet[], "/home/user/project", "Bash", `git -C "/path with spaces/repo" log`, SessionMode.acceptEdits);
static assert(gc6.decision == Decision.allow);

// --- WebFetch URL permission tests (f mode) ---

// f mode implies trailing /* — bare domains match any path
enum fetchPermPbt = `
scope {
  path: "/"
  permission.f {
    allow: ["docs.anthropic.com", "api.github.com"]
  }
}
`;
enum fetchParsed = parsePbt(fetchPermPbt);
enum fetchSet = buildPermissions(fetchParsed);

// WebFetch with allowed domain — bare domain matches subpaths
enum f1 = evaluatePermission(fetchSet[], "/home/user/project", "WebFetch", "https://docs.anthropic.com/en/docs/overview", SessionMode.acceptEdits);
static assert(f1.decision == Decision.allow);

// WebFetch with non-allowed domain
enum f2 = evaluatePermission(fetchSet[], "/home/user/project", "WebFetch", "https://evil.com/steal", SessionMode.acceptEdits);
static assert(f2.decision == Decision.none);

// WebSearch also matches f mode
enum f3 = evaluatePermission(fetchSet[], "/home/user/project", "WebSearch", "https://api.github.com/repos/foo/bar", SessionMode.acceptEdits);
static assert(f3.decision == Decision.allow);

// f mode does NOT match Read
enum f4 = evaluatePermission(fetchSet[], "/home/user/project", "Read", "https://docs.anthropic.com/foo", SessionMode.acceptEdits);
static assert(f4.decision == Decision.none);

// r mode does NOT match WebFetch anymore
enum f5 = evaluatePermission(pathSet[], "/home/user/project", "WebFetch", "/home/user/project/.env", SessionMode.acceptEdits);
static assert(f5.decision == Decision.none);

// Domain root without path still matches
enum f6 = evaluatePermission(fetchSet[], "/home/user/project", "WebFetch", "https://docs.anthropic.com", SessionMode.acceptEdits);
static assert(f6.decision == Decision.allow);

// Subdomain doesn't match parent domain
enum f7 = evaluatePermission(fetchSet[], "/home/user/project", "WebFetch", "https://evil.docs.anthropic.com/foo", SessionMode.acceptEdits);
static assert(f7.decision == Decision.none);

// --- Compound command tests (&&, ;, ||) ---

enum compoundPermPbt = `
scope {
  path: "/"
  permission {
    allow: ["cd *", "git log*", "git status*", "ls *", "grep *"]
    deny: ["*rm -rf*"]
  }
}
`;
enum compoundParsed = parsePbt(compoundPermPbt);
enum compoundSet = buildPermissions(compoundParsed);

// cd && git log — both sides allowed → allow
enum c1 = evaluatePermission(compoundSet[], "/home/user/project", "Bash", "cd /path && git log --oneline -20", SessionMode.acceptEdits);
static assert(c1.decision == Decision.allow);

// cd && unknown command — one side not matched → none
enum c2 = evaluatePermission(compoundSet[], "/home/user/project", "Bash", "cd /path && python script.py", SessionMode.acceptEdits);
static assert(c2.decision == Decision.none);

// cd && rm -rf — one side denied → deny
enum c3 = evaluatePermission(compoundSet[], "/home/user/project", "Bash", "cd /path && rm -rf /tmp", SessionMode.acceptEdits);
static assert(c3.decision == Decision.deny);

// Three parts: cd && ls && grep — all allowed → allow
enum c4 = evaluatePermission(compoundSet[], "/home/user/project", "Bash", "cd /path && ls -la /foo && grep -l pattern", SessionMode.acceptEdits);
static assert(c4.decision == Decision.allow);

// Semicolon separator: cd ; git status — both allowed → allow
enum c5 = evaluatePermission(compoundSet[], "/home/user/project", "Bash", "cd /path ; git status", SessionMode.acceptEdits);
static assert(c5.decision == Decision.allow);

// || separator: git log || git status — both allowed → allow
enum c6 = evaluatePermission(compoundSet[], "/home/user/project", "Bash", "cd /path || git log --oneline", SessionMode.acceptEdits);
static assert(c6.decision == Decision.allow);

// Single command (no separator) — unchanged behavior
enum c7 = evaluatePermission(compoundSet[], "/home/user/project", "Bash", "git log --oneline", SessionMode.acceptEdits);
static assert(c7.decision == Decision.allow);

// --- session-mode qualified permissions ---

enum sessionPermPbt = `
scope {
  path: "/"
  permission.w.a {
    allow: ["/teranos/", "/sbvh-nl/"]
  }
  permission.w.auto {
    allow: ["/only-under-auto/"]
  }
  permission.w {
    allow: ["/private/tmp/claude-*"]
  }
}
`;
enum sessionParsed = parsePbt(sessionPermPbt);
enum sessionSet = buildPermissions(sessionParsed);

// `a` is both permissive modes.
enum s1 = evaluatePermission(sessionSet[], "/x", "Write", "/teranos/ground/x.d", SessionMode.acceptEdits);
static assert(s1.decision == Decision.allow);

enum s2 = evaluatePermission(sessionSet[], "/x", "Write", "/teranos/ground/x.d", SessionMode.auto_);
static assert(s2.decision == Decision.allow);

// Manual arrives as default, and the grant does not reach it. This is the
// whole point: a blanket write rule stopped manual mode being consulted.
enum s3 = evaluatePermission(sessionSet[], "/x", "Write", "/teranos/ground/x.d", SessionMode.manual);
static assert(s3.decision == Decision.none);

enum s4 = evaluatePermission(sessionSet[], "/x", "Write", "/teranos/ground/x.d", SessionMode.plan);
static assert(s4.decision == Decision.none);

// A full name is exact where a letter is broad.
enum s5 = evaluatePermission(sessionSet[], "/x", "Write", "/only-under-auto/f", SessionMode.auto_);
static assert(s5.decision == Decision.allow);

enum s6 = evaluatePermission(sessionSet[], "/x", "Write", "/only-under-auto/f", SessionMode.acceptEdits);
static assert(s6.decision == Decision.none);

enum s7 = evaluatePermission(sessionSet[], "/x", "Write", "/private/tmp/claude-1/f", SessionMode.manual);
static assert(s7.decision == Decision.none);

enum s7a = evaluatePermission(sessionSet[], "/x", "Write", "/private/tmp/claude-1/f", SessionMode.acceptEdits);
static assert(s7a.decision == Decision.allow);

enum s8 = evaluatePermission(sessionSet[], "/x", "Write", "/private/tmp/claude-1/f", SessionMode.bypassPermissions);
static assert(s8.decision == Decision.allow);

enum s9 = evaluatePermission(sessionSet[], "/x", "Write", "/private/tmp/claude-1/f", SessionMode.unknown);
static assert(s9.decision == Decision.none);

enum s10 = evaluatePermission(sessionSet[], "/x", "Write", "/teranos/ground/x.d", SessionMode.unknown);
static assert(s10.decision == Decision.none);
