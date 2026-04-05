module permission_test;

import permission : buildPermissions, evaluatePermission, Decision;
import proto : parsePbt;

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
