module proto_test;

import proto : parsePbt, buildScopes;
import hooks : CheckFn, DelayFn, DeliverFn;

private CheckFn noopResolveCheck(string) { return null; }
private DelayFn noopResolveDelay(string) { return null; }

// --- Static assert tests ---

enum testInput = `
scope {
  path: ""
  decision: "allow"
  event: "PreToolUse"

  control {
    name: "test-cmd"
    cmd: "git"
    omit: "--no-verify"
    msg: "Don't skip hooks"
  }

  control {
    name: "test-bg"
    cmd: "dub build"
    bg: true
    tmo: 5000
    msg: "Build reminder"
  }
}

scope {
  path: "/QNTX"
  decision: "allow"
  event: "Stop"

  control {
    name: "test-stop"
    stop: "likely because"
    stop: "probably because"
    msg: "That's a guess"
  }
}

# Comment line
scope {
  path: ""
  decision: "allow"
  event: "PostToolUseDeferred"

  control {
    name: "test-defer"
    cmd: "git push"
    delay_handler: "ciDelay"
    deliver_handler: "ciDeliver"
  }
}

scope {
  path: ""
  decision: "allow"
  event: "SessionStart"

  control {
    name: "test-check"
    check_handler: "testCheck"
    msg: "stale"
  }
}

# Defaults test — no path, no decision
scope {
  event: "PreToolUse"

  control {
    name: "test-defaults"
    cmd: "echo"
  }
}

scope {
  event: "Stop"

  control {
    name: "test-stop-list"
    stop: [
        "each conversation starts fresh",
        "each session starts fresh",
        "don't have access to previous conversation",
        "don't have access to previous session",
        "don't have access to conversation history",
        "dialogue isn't stored anywhere"
    ]
    msg: "Wrong. Previous conversations are accessible. JSONL transcripts are stored at ~/.claude/projects/. The ground db at ~/.local/share/ground/ground.db stores last_assistant_message in Stop attestation attributes. Check before claiming you can't."
  }
}
`;

// Test parse structure
enum testParsed = parsePbt(testInput);
static assert(testParsed.scopeCount == 6);

// Scope 0: PreToolUse
static assert(testParsed.scopes[0].path == "");
static assert(testParsed.scopes[0].decision == "allow");
static assert(testParsed.scopes[0].event == "PreToolUse");
static assert(testParsed.scopes[0].controlCount == 2);
static assert(testParsed.scopes[0].controls[0].name == "test-cmd");
static assert(testParsed.scopes[0].controls[0].cmd == "git");
static assert(testParsed.scopes[0].controls[0].omit == "--no-verify");
static assert(testParsed.scopes[0].controls[0].msg == "Don't skip hooks");
static assert(testParsed.scopes[0].controls[1].bg == true);
static assert(testParsed.scopes[0].controls[1].tmo == 5000);

// Scope 1: Stop with multi-trigger
static assert(testParsed.scopes[1].path == "/QNTX");
static assert(testParsed.scopes[1].event == "Stop");
static assert(testParsed.scopes[1].controls[0].triggerCount == 2);
static assert(testParsed.scopes[1].controls[0].triggers[0] == "likely because");
static assert(testParsed.scopes[1].controls[0].triggers[1] == "probably because");

// Scope 2: Deferred with handlers
static assert(testParsed.scopes[2].event == "PostToolUseDeferred");
static assert(testParsed.scopes[2].controls[0].delayHandler == "ciDelay");
static assert(testParsed.scopes[2].controls[0].deliverHandler == "ciDeliver");
static assert(testParsed.scopes[2].controls[0].deferMsg == "");

// Scope 3: SessionStart with check handler
static assert(testParsed.scopes[3].controls[0].checkHandler == "testCheck");

// Scope 4: defaults — path="" and decision="allow" when omitted
static assert(testParsed.scopes[4].path == "");
static assert(testParsed.scopes[4].decision == "");
static assert(testParsed.scopes[4].controls[0].name == "test-defaults");
static assert(testParsed.scopes[4].controls[0].msg == "");

// Scope 5: Stop with list triggers
static assert(testParsed.scopes[5].event == "Stop");
static assert(testParsed.scopes[5].controls[0].name == "test-stop-list");
static assert(testParsed.scopes[5].controls[0].triggerCount == 6);
static assert(testParsed.scopes[5].controls[0].triggers[0] == "each conversation starts fresh");
static assert(testParsed.scopes[5].controls[0].triggers[1] == "each session starts fresh");
static assert(testParsed.scopes[5].controls[0].triggers[2] == "don't have access to previous conversation");
static assert(testParsed.scopes[5].controls[0].triggers[3] == "don't have access to previous session");
static assert(testParsed.scopes[5].controls[0].triggers[4] == "don't have access to conversation history");
static assert(testParsed.scopes[5].controls[0].triggers[5] == "dialogue isn't stored anywhere");

// Test buildScopes without handlers (default resolvers)
enum testBuilt = buildScopes(testParsed, "PreToolUse");
static assert(testBuilt.len == 2);
// Scope with omitted decision defaults to "allow"
static assert(testBuilt.items[1].decision == "allow");
static assert(testBuilt.items[0].controls.length == 2);
static assert(testBuilt.items[0].controls[0].name == "test-cmd");
static assert(testBuilt.items[0].controls[0].cmd.value == "git");
static assert(testBuilt.items[0].controls[0].omit.value == "--no-verify");
static assert(testBuilt.items[0].controls[1].bg.value == true);
static assert(testBuilt.items[0].controls[1].tmo.value == 5000);

// Test Stop scope filtering
enum testStopBuilt = buildScopes(testParsed, "Stop");
static assert(testStopBuilt.len == 2);
static assert(testStopBuilt.items[0].path == "/QNTX");
static assert(testStopBuilt.items[0].controls[0].trigger.len == 2);
static assert(testStopBuilt.items[0].controls[0].trigger._buf[0] == "likely because");
static assert(testStopBuilt.items[1].controls[0].trigger.len == 6);
static assert(testStopBuilt.items[1].controls[0].trigger._buf[0] == "each conversation starts fresh");
static assert(testStopBuilt.items[1].controls[0].trigger._buf[5] == "dialogue isn't stored anywhere");

// Test Stop with deliver_handler + interval (upstream-briefing pattern)
enum stopDeliverInput = `
scope {
  path: "/my-fork"
  event: "Stop"
  control {
    name: "upstream-briefing-stop"
    deliver_handler: "testDeliver"
    interval: 604800
  }
}
`;
enum stopDeliverParsed = parsePbt(stopDeliverInput);
static assert(stopDeliverParsed.scopeCount == 1);
static assert(stopDeliverParsed.scopes[0].event == "Stop");
static assert(stopDeliverParsed.scopes[0].path == "/my-fork");
static assert(stopDeliverParsed.scopes[0].controls[0].name == "upstream-briefing-stop");
static assert(stopDeliverParsed.scopes[0].controls[0].deliverHandler == "testDeliver");
static assert(stopDeliverParsed.scopes[0].controls[0].interval == 604800);
static assert(stopDeliverParsed.scopes[0].controls[0].triggerCount == 0);

// buildScopes for Stop with deliver_handler — wires defer.deliverFn
private const(char)[] testDeliverFn(const(char)[]) { return "test"; }
private DeliverFn testResolveDeliver(string name) {
    if (name == "testDeliver") return &testDeliverFn;
    return null;
}
enum stopDeliverBuilt = buildScopes!(noopResolveCheck, noopResolveDelay, testResolveDeliver)(stopDeliverParsed, "Stop");
static assert(stopDeliverBuilt.len == 1);
static assert(stopDeliverBuilt.items[0].controls[0].name == "upstream-briefing-stop");
static assert(stopDeliverBuilt.items[0].controls[0].defer.deliverFn !is null);  // deliver_handler wired
static assert(stopDeliverBuilt.items[0].controls[0].interval == 604800);
static assert(stopDeliverBuilt.items[0].controls[0].trigger.len == 0);  // no trigger — unconditional

// Minimal list parse test — readValue returns null on '[', triggers collected
enum listInput = `
scope {
  event: "Stop"
  control {
    name: "list-3"
    stop: ["a", "b", "c"]
    msg: "x"
  }
}
`;
enum listParsed = parsePbt(listInput);
static assert(listParsed.scopes[0].controls[0].triggerCount == 3);
static assert(listParsed.scopes[0].controls[0].triggers[0] == "a");
static assert(listParsed.scopes[0].controls[0].triggers[1] == "b");
static assert(listParsed.scopes[0].controls[0].triggers[2] == "c");

// --- Permission parsing tests ---

// Basic permission in a scope
enum permInput = `
scope {
  path: "/"

  permission {
    allow: ["go build*", "go test*", "cargo build*"]
    deny: ["*rm -rf*", "*--force*"]
    msg: "Destructive operations blocked"
  }
}
`;
enum permParsed = parsePbt(permInput);
static assert(permParsed.scopeCount == 1);
static assert(permParsed.scopes[0].path == "/");
static assert(permParsed.scopes[0].permissionCount == 1);
static assert(permParsed.scopes[0].permissions[0].mode == "");
static assert(permParsed.scopes[0].permissions[0].allowCount == 3);
static assert(permParsed.scopes[0].permissions[0].allow[0] == "go build*");
static assert(permParsed.scopes[0].permissions[0].allow[1] == "go test*");
static assert(permParsed.scopes[0].permissions[0].allow[2] == "cargo build*");
static assert(permParsed.scopes[0].permissions[0].denyCount == 2);
static assert(permParsed.scopes[0].permissions[0].deny[0] == "*rm -rf*");
static assert(permParsed.scopes[0].permissions[0].deny[1] == "*--force*");
static assert(permParsed.scopes[0].permissions[0].msg == "Destructive operations blocked");

// Permission with all three decision types
enum permFullInput = `
scope {
  path: "/"
  permission {
    allow: ["sqlite3*"]
    ask: ["*DELETE*", "*DROP*"]
    deny: ["*rm -rf*"]
  }
}
`;
enum permFullParsed = parsePbt(permFullInput);
static assert(permFullParsed.scopes[0].permissions[0].allowCount == 1);
static assert(permFullParsed.scopes[0].permissions[0].allow[0] == "sqlite3*");
static assert(permFullParsed.scopes[0].permissions[0].askCount == 2);
static assert(permFullParsed.scopes[0].permissions[0].ask[0] == "*DELETE*");
static assert(permFullParsed.scopes[0].permissions[0].ask[1] == "*DROP*");
static assert(permFullParsed.scopes[0].permissions[0].denyCount == 1);

// Permissions coexist with controls in the same scope
enum permMixedInput = `
scope {
  path: "/my-project"
  event: "Stop"

  control {
    name: "test-ctrl"
    stop: "check the*log"
    msg: "Read logs yourself"
  }

  permission {
    allow: ["npm run*"]
  }
}
`;
enum permMixedParsed = parsePbt(permMixedInput);
static assert(permMixedParsed.scopes[0].controlCount == 1);
static assert(permMixedParsed.scopes[0].controls[0].name == "test-ctrl");
static assert(permMixedParsed.scopes[0].permissionCount == 1);
static assert(permMixedParsed.scopes[0].permissions[0].mode == "");
static assert(permMixedParsed.scopes[0].permissions[0].allow[0] == "npm run*");

// Multiple permissions in one scope
enum permMultiInput = `
scope {
  path: "/"
  permission {
    allow: ["*sleep*", "*say*"]
  }
  permission {
    deny: ["*rm -rf*"]
    msg: "No destructive ops"
  }
}
`;
enum permMultiParsed = parsePbt(permMultiInput);
static assert(permMultiParsed.scopes[0].permissionCount == 2);
static assert(permMultiParsed.scopes[0].permissions[0].allowCount == 2);
static assert(permMultiParsed.scopes[0].permissions[1].denyCount == 1);
static assert(permMultiParsed.scopes[0].permissions[1].msg == "No destructive ops");

// Top-level permission (no scope) — defaults to path "/"
enum permTopLevelInput = `
permission {

  allow: ["go build*", "make*"]
}

permission {

  deny: ["*--force*"]
  msg: "No force pushes"
}

scope {
  path: "/my-project"
  event: "Stop"
  control {
    name: "test-ctrl"
    stop: "guess"
    msg: "Don't guess"
  }
}
`;
enum permTopParsed = parsePbt(permTopLevelInput);
// Top-level permissions become scopes with path "/" and no event
static assert(permTopParsed.scopeCount == 3);
static assert(permTopParsed.scopes[0].path == "/");
static assert(permTopParsed.scopes[0].permissionCount == 1);
static assert(permTopParsed.scopes[0].permissions[0].mode == "");
static assert(permTopParsed.scopes[0].permissions[0].allowCount == 2);
static assert(permTopParsed.scopes[0].permissions[0].allow[0] == "go build*");
static assert(permTopParsed.scopes[1].path == "/");
static assert(permTopParsed.scopes[1].permissions[0].denyCount == 1);
static assert(permTopParsed.scopes[1].permissions[0].msg == "No force pushes");
// Regular scope still parses normally
static assert(permTopParsed.scopes[2].path == "/my-project");
static assert(permTopParsed.scopes[2].controlCount == 1);

// Top-level control (no scope) — wraps in scope with path "/"
enum ctrlTopLevelInput = `
control {
  name: "check-logs"
  event: "Stop"
  stop: "check the*log"
  msg: "Read logs yourself"
}
`;
enum ctrlTopParsed = parsePbt(ctrlTopLevelInput);
static assert(ctrlTopParsed.scopeCount == 1);
static assert(ctrlTopParsed.scopes[0].path == "/");
static assert(ctrlTopParsed.scopes[0].controlCount == 1);
static assert(ctrlTopParsed.scopes[0].controls[0].name == "check-logs");
static assert(ctrlTopParsed.scopes[0].controls[0].triggers[0] == "check the*log");

// --- PostToolUse filepath matching ---

// PostToolUse scope with filepath control (no cmd)
enum ptuFileInput = `
scope {
  path: "/ground"
  event: "PostToolUse"

  control {
    name: "rebuild-after-pbt-edit"
    filepath: ".pbt"
    msg: "Controls changed. Run make install to update the binary."
  }
}
`;
enum ptuFileParsed = parsePbt(ptuFileInput);
static assert(ptuFileParsed.scopeCount == 1);
static assert(ptuFileParsed.scopes[0].event == "PostToolUse");
static assert(ptuFileParsed.scopes[0].controls[0].filepath == ".pbt");
static assert(ptuFileParsed.scopes[0].controls[0].cmd == "");

// buildScopes preserves filepath into PostToolUse controls
enum ptuFileBuilt = buildScopes(ptuFileParsed, "PostToolUse");
static assert(ptuFileBuilt.len == 1);
static assert(ptuFileBuilt.items[0].path == "/ground");
static assert(ptuFileBuilt.items[0].controls[0].filepath.value == ".pbt");
static assert(ptuFileBuilt.items[0].controls[0].cmd.value == "");
static assert(ptuFileBuilt.items[0].controls[0].msg.value == "Controls changed. Run make install to update the binary.");

// contains matches filepath substring
import matcher : contains;
static assert(contains("/Users/me/ground/controls/permissions.pbt", ".pbt"));
static assert(!contains("/Users/me/ground/source/main.d", ".pbt"));

// --- chmod-style mode syntax ---

enum modeInput = `
scope {
  path: "/ground"
  event: "PostToolUse"

  control.w {
    name: "rebuild-after-pbt-edit"
    filepath: ".pbt"
    msg: "Controls changed. Run make install."
  }

  control.rw {
    name: "pbt-access"
    filepath: ".pbt"
    msg: "Touching controls."
  }
}
`;
enum modeParsed = parsePbt(modeInput);
static assert(modeParsed.scopeCount == 1);
static assert(modeParsed.scopes[0].controls[0].name == "rebuild-after-pbt-edit");
static assert(modeParsed.scopes[0].controls[0].mode == "w");
static assert(modeParsed.scopes[0].controls[1].name == "pbt-access");
static assert(modeParsed.scopes[0].controls[1].mode == "rw");

// permission with mode
enum permModeInput = `
permission.r {
  deny: [".env", "secrets/*"]
  msg: "Secrets are off-limits"
}
`;
enum permModeParsed = parsePbt(permModeInput);
static assert(permModeParsed.scopeCount == 1);
static assert(permModeParsed.scopes[0].permissions[0].mode == "r");

// --- Nested scope tests ---

// Child scopes inherit parent path
enum nestedInput = `
scope {
  path: "/ground"

  scope {
    event: "PreToolUse"
    control {
      name: "nested-pre"
      cmd: "dub build"
      msg: "Build reminder"
    }
  }

  scope {
    event: "PostToolUse"
    control {
      name: "nested-post"
      cmd: "make install"
    }
  }
}
`;
enum nestedParsed = parsePbt(nestedInput);
// Parent scope has no controls/event — only children become real scopes
static assert(nestedParsed.scopeCount == 2);
static assert(nestedParsed.scopes[0].path == "/ground");
static assert(nestedParsed.scopes[0].event == "PreToolUse");
static assert(nestedParsed.scopes[0].controls[0].name == "nested-pre");
static assert(nestedParsed.scopes[1].path == "/ground");
static assert(nestedParsed.scopes[1].event == "PostToolUse");
static assert(nestedParsed.scopes[1].controls[0].name == "nested-post");

// Child inherits event from parent
enum nestedEventInput = `
scope {
  event: "PreToolUse"

  scope {
    control {
      name: "allow-ctrl"
      cmd: "echo"
      msg: "test"
    }
  }

  scope {
    decision: "deny"
    control {
      name: "deny-ctrl"
      cmd: "rm"
      msg: "blocked"
    }
  }
}
`;
enum nestedEventParsed = parsePbt(nestedEventInput);
static assert(nestedEventParsed.scopeCount == 2);
static assert(nestedEventParsed.scopes[0].event == "PreToolUse");
static assert(nestedEventParsed.scopes[1].event == "PreToolUse");
static assert(nestedEventParsed.scopes[1].decision == "deny");

// Child inherits path but can override with its own
enum nestedOverrideInput = `
scope {
  path: "/ground"

  scope {
    path: "/other"
    event: "Stop"
    control {
      name: "override-path"
      stop: "test"
      msg: "overridden"
    }
  }
}
`;
enum nestedOverrideParsed = parsePbt(nestedOverrideInput);
static assert(nestedOverrideParsed.scopeCount == 1);
static assert(nestedOverrideParsed.scopes[0].path == "/other");

// Nested scope inherits decision from parent
enum nestedDecisionInput = `
scope {
  path: "/ground"
  decision: "deny"

  scope {
    event: "PreToolUse"
    control {
      name: "nested-deny"
      cmd: "rm"
      msg: "blocked"
    }
  }
}
`;
enum nestedDecisionParsed = parsePbt(nestedDecisionInput);
static assert(nestedDecisionParsed.scopeCount == 1);
static assert(nestedDecisionParsed.scopes[0].decision == "deny");
static assert(nestedDecisionParsed.scopes[0].path == "/ground");
