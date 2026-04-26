module proto_test;

import proto : parsePbt, buildScopes, ParseResult;
import hooks : CheckFn, DelayFn, DeliverFn;

private CheckFn noopResolveCheck(string) { return null; }
private DelayFn noopResolveDelay(string) { return null; }

// Pool accessors for readability
auto ctrl(PR)(const PR r, size_t sc, size_t i) { return r.ctrlPool[r.scopes[sc].controlStart + i]; }
auto perm(PR)(const PR r, size_t sc, size_t i) { return r.permPool[r.scopes[sc].permStart + i]; }

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
static assert(testParsed.scopes[0].pathCount == 0);
static assert(testParsed.scopes[0].decision == "allow");
static assert(testParsed.scopes[0].event == "PreToolUse");
static assert(testParsed.scopes[0].controlCount == 2);
static assert(ctrl(testParsed, 0, 0).name == "test-cmd");
static assert(ctrl(testParsed, 0, 0).cmd == "git");
static assert(ctrl(testParsed, 0, 0).omit == "--no-verify");
static assert(ctrl(testParsed, 0, 0).msg == "Don't skip hooks");
static assert(ctrl(testParsed, 0, 1).bg == true);
static assert(ctrl(testParsed, 0, 1).tmo == 5000);

// Scope 1: Stop with multi-trigger
static assert(testParsed.scopes[1].paths[0] == "/QNTX");
static assert(testParsed.scopes[1].event == "Stop");
static assert(ctrl(testParsed, 1, 0).triggerCount == 2);
static assert(ctrl(testParsed, 1, 0).triggers[0] == "likely because");
static assert(ctrl(testParsed, 1, 0).triggers[1] == "probably because");

// Scope 2: Deferred with handlers
static assert(testParsed.scopes[2].event == "PostToolUseDeferred");
static assert(ctrl(testParsed, 2, 0).delayHandler == "ciDelay");
static assert(ctrl(testParsed, 2, 0).deliverHandler == "ciDeliver");
static assert(ctrl(testParsed, 2, 0).deferMsg == "");

// Scope 3: SessionStart with check handler
static assert(ctrl(testParsed, 3, 0).checkHandler == "testCheck");

// Scope 4: defaults — path="" and decision="" when omitted
static assert(testParsed.scopes[4].pathCount == 0);
static assert(testParsed.scopes[4].decision == "");
static assert(ctrl(testParsed, 4, 0).name == "test-defaults");
static assert(ctrl(testParsed, 4, 0).msg == "");

// BUG: advisory filepath controls must not auto-approve edits.
// Filepath controls inject context — they are not permission decisions.
// A scope with no explicit decision: must not produce "allow" in the response.
import pretooluse : advisoryDecision;
static assert(advisoryDecision("allow") == "");   // default "allow" → no decision
static assert(advisoryDecision("") == "");         // empty → no decision
static assert(advisoryDecision("ask") == "ask");   // explicit ask → preserved
static assert(advisoryDecision("deny") == "deny"); // explicit deny → preserved

// Scope 5: Stop with list triggers
static assert(testParsed.scopes[5].event == "Stop");
static assert(ctrl(testParsed, 5, 0).name == "test-stop-list");
static assert(ctrl(testParsed, 5, 0).triggerCount == 6);
static assert(ctrl(testParsed, 5, 0).triggers[0] == "each conversation starts fresh");
static assert(ctrl(testParsed, 5, 0).triggers[1] == "each session starts fresh");
static assert(ctrl(testParsed, 5, 0).triggers[2] == "don't have access to previous conversation");
static assert(ctrl(testParsed, 5, 0).triggers[3] == "don't have access to previous session");
static assert(ctrl(testParsed, 5, 0).triggers[4] == "don't have access to conversation history");
static assert(ctrl(testParsed, 5, 0).triggers[5] == "dialogue isn't stored anywhere");

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
static assert(testStopBuilt.items[0].paths[0] == "/QNTX");
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
static assert(stopDeliverParsed.scopes[0].paths[0] == "/my-fork");
static assert(ctrl(stopDeliverParsed, 0, 0).name == "upstream-briefing-stop");
static assert(ctrl(stopDeliverParsed, 0, 0).deliverHandler == "testDeliver");
static assert(ctrl(stopDeliverParsed, 0, 0).interval == 604800);
static assert(ctrl(stopDeliverParsed, 0, 0).triggerCount == 0);

// buildScopes for Stop with deliver_handler — wires defer.deliverFn
private const(char)[] testDeliverFn(const(char)[]) { return "test"; }
private DeliverFn testResolveDeliver(string name) {
    if (name == "testDeliver") return &testDeliverFn;
    return null;
}
enum stopDeliverBuilt = buildScopes!(noopResolveCheck, noopResolveDelay, testResolveDeliver)(stopDeliverParsed, "Stop");
static assert(stopDeliverBuilt.len == 1);
static assert(stopDeliverBuilt.items[0].controls[0].name == "upstream-briefing-stop");
static assert(stopDeliverBuilt.items[0].controls[0].defer.deliverFn !is null);
static assert(stopDeliverBuilt.items[0].controls[0].interval == 604800);
static assert(stopDeliverBuilt.items[0].controls[0].trigger.len == 0);

// Minimal list parse test
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
static assert(ctrl(listParsed, 0, 0).triggerCount == 3);
static assert(ctrl(listParsed, 0, 0).triggers[0] == "a");
static assert(ctrl(listParsed, 0, 0).triggers[1] == "b");
static assert(ctrl(listParsed, 0, 0).triggers[2] == "c");

// --- Permission parsing tests ---

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
static assert(permParsed.scopes[0].paths[0] == "/");
static assert(permParsed.scopes[0].permissionCount == 1);
static assert(perm(permParsed, 0, 0).mode == "");
static assert(perm(permParsed, 0, 0).allowCount == 3);
static assert(perm(permParsed, 0, 0).allow[0] == "go build*");
static assert(perm(permParsed, 0, 0).allow[1] == "go test*");
static assert(perm(permParsed, 0, 0).allow[2] == "cargo build*");
static assert(perm(permParsed, 0, 0).denyCount == 2);
static assert(perm(permParsed, 0, 0).deny[0] == "*rm -rf*");
static assert(perm(permParsed, 0, 0).deny[1] == "*--force*");
static assert(perm(permParsed, 0, 0).msg == "Destructive operations blocked");

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
static assert(perm(permFullParsed, 0, 0).allowCount == 1);
static assert(perm(permFullParsed, 0, 0).allow[0] == "sqlite3*");
static assert(perm(permFullParsed, 0, 0).askCount == 2);
static assert(perm(permFullParsed, 0, 0).ask[0] == "*DELETE*");
static assert(perm(permFullParsed, 0, 0).ask[1] == "*DROP*");
static assert(perm(permFullParsed, 0, 0).denyCount == 1);

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
static assert(ctrl(permMixedParsed, 0, 0).name == "test-ctrl");
static assert(permMixedParsed.scopes[0].permissionCount == 1);
static assert(perm(permMixedParsed, 0, 0).mode == "");
static assert(perm(permMixedParsed, 0, 0).allow[0] == "npm run*");

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
static assert(perm(permMultiParsed, 0, 0).allowCount == 2);
static assert(perm(permMultiParsed, 0, 1).denyCount == 1);
static assert(perm(permMultiParsed, 0, 1).msg == "No destructive ops");

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
static assert(permTopParsed.scopeCount == 3);
static assert(permTopParsed.scopes[0].paths[0] == "/");
static assert(permTopParsed.scopes[0].permissionCount == 1);
static assert(perm(permTopParsed, 0, 0).mode == "");
static assert(perm(permTopParsed, 0, 0).allowCount == 2);
static assert(perm(permTopParsed, 0, 0).allow[0] == "go build*");
static assert(permTopParsed.scopes[1].paths[0] == "/");
static assert(perm(permTopParsed, 1, 0).denyCount == 1);
static assert(perm(permTopParsed, 1, 0).msg == "No force pushes");
static assert(permTopParsed.scopes[2].paths[0] == "/my-project");
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
static assert(ctrlTopParsed.scopes[0].paths[0] == "/");
static assert(ctrlTopParsed.scopes[0].controlCount == 1);
static assert(ctrl(ctrlTopParsed, 0, 0).name == "check-logs");
static assert(ctrl(ctrlTopParsed, 0, 0).triggers[0] == "check the*log");

// --- PostToolUse filepath matching ---

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
static assert(ctrl(ptuFileParsed, 0, 0).filepath == ".pbt");
static assert(ctrl(ptuFileParsed, 0, 0).cmd == "");

enum ptuFileBuilt = buildScopes(ptuFileParsed, "PostToolUse");
static assert(ptuFileBuilt.len == 1);
static assert(ptuFileBuilt.items[0].paths[0] == "/ground");
static assert(ptuFileBuilt.items[0].controls[0].filepath.value == ".pbt");
static assert(ptuFileBuilt.items[0].controls[0].cmd.value == "");
static assert(ptuFileBuilt.items[0].controls[0].msg.value == "Controls changed. Run make install to update the binary.");

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
static assert(ctrl(modeParsed, 0, 0).name == "rebuild-after-pbt-edit");
static assert(ctrl(modeParsed, 0, 0).mode == "w");
static assert(ctrl(modeParsed, 0, 1).name == "pbt-access");
static assert(ctrl(modeParsed, 0, 1).mode == "rw");

// permission with mode
enum permModeInput = `
permission.r {
  deny: [".env", "secrets/*"]
  msg: "Secrets are off-limits"
}
`;
enum permModeParsed = parsePbt(permModeInput);
static assert(permModeParsed.scopeCount == 1);
static assert(perm(permModeParsed, 0, 0).mode == "r");

// --- Nested scope tests ---

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
static assert(nestedParsed.scopeCount == 2);
static assert(nestedParsed.scopes[0].paths[0] == "/ground");
static assert(nestedParsed.scopes[0].event == "PreToolUse");
static assert(ctrl(nestedParsed, 0, 0).name == "nested-pre");
static assert(nestedParsed.scopes[1].paths[0] == "/ground");
static assert(nestedParsed.scopes[1].event == "PostToolUse");
static assert(ctrl(nestedParsed, 1, 0).name == "nested-post");

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

// Child inherits path but can override
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
static assert(nestedOverrideParsed.scopes[0].paths[0] == "/other");

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
static assert(nestedDecisionParsed.scopes[0].paths[0] == "/ground");

// --- edited: scope field ---

// Simple edited (no !) — existence check
enum editedSimpleInput = `
scope {
  edited: ["*.sql"]
  event: "Stop"

  control {
    name: "run-migrations"
    stop: "migrate"
    msg: "Run migrations"
  }
}
`;
enum editedSimpleParsed = parsePbt(editedSimpleInput);
static assert(editedSimpleParsed.scopeCount == 1);
static assert(editedSimpleParsed.scopes[0].editedCount == 1);
static assert(editedSimpleParsed.scopes[0].edited[0] == "*.sql");
static assert(editedSimpleParsed.scopes[0].event == "Stop");

// Nested: outer path, inner edited with ! (subtractive)
enum editedNestedInput = `
scope {
  path: "/QNTX"

  scope {
    edited: ["!/ctp/", "!/qntx-plugins/", "!/web/"]
    event: "Stop"

    control {
      name: "make-dev-unnecessary"
      stop: "make dev"
      msg: "No server edits"
    }
  }
}
`;
enum editedNestedParsed = parsePbt(editedNestedInput);
static assert(editedNestedParsed.scopeCount == 1);
static assert(editedNestedParsed.scopes[0].paths[0] == "/QNTX");
static assert(editedNestedParsed.scopes[0].editedCount == 3);
static assert(editedNestedParsed.scopes[0].edited[0] == "!/ctp/");
static assert(editedNestedParsed.scopes[0].edited[1] == "!/qntx-plugins/");
static assert(editedNestedParsed.scopes[0].edited[2] == "!/web/");

// buildScopes preserves edited on Scope
enum editedBuilt = buildScopes(editedNestedParsed, "Stop");
static assert(editedBuilt.len == 1);
static assert(editedBuilt.items[0].editedCount == 3);
static assert(editedBuilt.items[0].edited[0] == "!/ctp/");
static assert(editedBuilt.items[0].edited[1] == "!/qntx-plugins/");

// --- userprompt list syntax ---

enum upListInput = `
scope {
  event: "UserPromptSubmit"

  control {
    name: "dig-before-control"
    userprompt: ["create*control", "as a control", "new control"]
    msg: "Dig first"
  }

  control {
    name: "single-prompt"
    userprompt: "permission"
    msg: "Check permissions"
  }
}
`;
enum upListParsed = parsePbt(upListInput);
static assert(upListParsed.scopeCount == 1);
static assert(ctrl(upListParsed, 0, 0).name == "dig-before-control");
static assert(ctrl(upListParsed, 0, 0).userpromptCount == 3);
static assert(ctrl(upListParsed, 0, 0).userprompts[0] == "create*control");
static assert(ctrl(upListParsed, 0, 0).userprompts[1] == "as a control");
static assert(ctrl(upListParsed, 0, 0).userprompts[2] == "new control");
static assert(ctrl(upListParsed, 0, 1).name == "single-prompt");
static assert(ctrl(upListParsed, 0, 1).userpromptCount == 1);
static assert(ctrl(upListParsed, 0, 1).userprompts[0] == "permission");

// --- cmd: scope field (session command history gate) ---

enum cmdScopeInput = `
scope {
  path: "/QNTX"
  cmd: ["!make install"]
  event: "Stop"

  control {
    name: "build-before-commit"
    stop: ["want me to commit", "ready to commit"]
    msg: "Run make install first"
  }
}
`;
enum cmdScopeParsed = parsePbt(cmdScopeInput);
static assert(cmdScopeParsed.scopeCount == 1);
static assert(cmdScopeParsed.scopes[0].cmdCount == 1);
static assert(cmdScopeParsed.scopes[0].cmds[0] == "!make install");
static assert(cmdScopeParsed.scopes[0].paths[0] == "/QNTX");
static assert(cmdScopeParsed.scopes[0].event == "Stop");

// buildScopes preserves cmd on Scope
enum cmdScopeBuilt = buildScopes(cmdScopeParsed, "Stop");
static assert(cmdScopeBuilt.len == 1);
static assert(cmdScopeBuilt.items[0].cmdCount == 1);
static assert(cmdScopeBuilt.items[0].cmds[0] == "!make install");

// --- event: array syntax (multi-event scopes) ---

enum multiEventInput = `
scope {
  path: "/ground"
  event: ["SessionStart", "PostToolUse"]

  control {
    name: "local-controls-reminder"
    msg: "controls/local/ is a separate repo"
  }
}
`;
enum multiEventParsed = parsePbt(multiEventInput);
// Single scope in parsed output, but matches both events
static assert(multiEventParsed.scopeCount == 1);
static assert(multiEventParsed.scopes[0].paths[0] == "/ground");
static assert(ctrl(multiEventParsed, 0, 0).name == "local-controls-reminder");

// buildScopes should find this scope for both events
enum multiEventSessionStart = buildScopes(multiEventParsed, "SessionStart");
static assert(multiEventSessionStart.len == 1);
static assert(multiEventSessionStart.items[0].controls[0].name == "local-controls-reminder");

enum multiEventPostToolUse = buildScopes(multiEventParsed, "PostToolUse");
static assert(multiEventPostToolUse.len == 1);
static assert(multiEventPostToolUse.items[0].controls[0].name == "local-controls-reminder");

// Should NOT match unrelated events
enum multiEventStop = buildScopes(multiEventParsed, "Stop");
static assert(multiEventStop.len == 0);

// --- mcp_tool scope field + mcp_arg control field ---

enum mcpInput = `
scope {
  path: "/SBVH"
  event: "PreToolUse"
  mcp_tool: "read_messages"

  control {
    name: "contact-a-context"
    mcp_arg: "Alice"
    msg: "Read ~/Obsidian/People/Alice.md first. Update it after if anything significant."
  }

  control {
    name: "contact-b-context"
    mcp_arg: "Bob"
    msg: "Bob is a baker. Check bobsbakery.com/menu for today's pastries before responding."
  }
}
`;
enum mcpParsed = parsePbt(mcpInput);
static assert(mcpParsed.scopeCount == 1);
static assert(mcpParsed.scopes[0].mcpTool == "read_messages");
static assert(mcpParsed.scopes[0].event == "PreToolUse");
static assert(mcpParsed.scopes[0].controlCount == 2);
static assert(ctrl(mcpParsed, 0, 0).name == "contact-a-context");
static assert(ctrl(mcpParsed, 0, 0).mcpArg == "Alice");
static assert(ctrl(mcpParsed, 0, 1).name == "contact-b-context");
static assert(ctrl(mcpParsed, 0, 1).mcpArg == "Bob");

// buildScopes preserves mcp_tool on Scope and mcpArg on Control
enum mcpBuilt = buildScopes(mcpParsed, "PreToolUse");
static assert(mcpBuilt.len == 1);
static assert(mcpBuilt.items[0].mcpTool == "read_messages");
static assert(mcpBuilt.items[0].controls[0].mcpArg.value == "Alice");
static assert(mcpBuilt.items[0].controls[1].mcpArg.value == "Bob");

// --- qntx block + attestation block ---

enum qntxInput = `
qntx {
  node {
    url: "http://localhost:8771"
  }
  node {
    url: "http://localhost:8772"
  }
}

attestation {
  subject: "telegram:chat:1667286968"
  predicate: "raven:route"
  context: "project:SBVH"
  attributes: {
    "chat_id": 1667286968,
    "project": "SBVH",
    "chat_name": "Danilo"
  }
}

attestation {
  subject: "telegram:chat:355422856"
  predicate: "raven:route"
  context: "project:SBVH"
}
`;
enum qntxParsed = parsePbt(qntxInput);
static assert(qntxParsed.qntxNodeCount == 2);
static assert(qntxParsed.qntxNodes[0].url == "http://localhost:8771");
static assert(qntxParsed.qntxNodes[1].url == "http://localhost:8772");
static assert(qntxParsed.attestationCount == 2);
static assert(qntxParsed.attestations[0].subject == "telegram:chat:1667286968");
static assert(qntxParsed.attestations[0].predicate == "raven:route");
static assert(qntxParsed.attestations[0].context == "project:SBVH");
static assert(qntxParsed.attestations[0].attributes.length > 0);
static assert(qntxParsed.attestations[1].subject == "telegram:chat:355422856");
static assert(qntxParsed.attestations[1].predicate == "raven:route");
static assert(qntxParsed.attestations[1].attributes.length == 0);

// --- cmd: array syntax at control level ---

enum cmdArrayInput = `
scope {
  event: "PreToolUse"

  control {
    name: "pr-description-no-stats"
    cmd: ["gh pr create", "gh pr edit"]
    msg: "PR descriptions: why, not what. No LOC counts, no file counts, no diff stats."
  }
}
`;
enum cmdArrayParsed = parsePbt(cmdArrayInput);
static assert(cmdArrayParsed.scopeCount == 1);
static assert(ctrl(cmdArrayParsed, 0, 0).name == "pr-description-no-stats");
static assert(ctrl(cmdArrayParsed, 0, 0).cmdCount == 2);
static assert(ctrl(cmdArrayParsed, 0, 0).cmds[0] == "gh pr create");
static assert(ctrl(cmdArrayParsed, 0, 0).cmds[1] == "gh pr edit");

// buildScopes wires cmd array into Control
enum cmdArrayBuilt = buildScopes(cmdArrayParsed, "PreToolUse");
static assert(cmdArrayBuilt.len == 1);
static assert(cmdArrayBuilt.items[0].controls[0].cmd.values.length == 2);
static assert(cmdArrayBuilt.items[0].controls[0].cmd.values[0] == "gh pr create");
static assert(cmdArrayBuilt.items[0].controls[0].cmd.values[1] == "gh pr edit");

// --- content field on Control ---

enum contentInput = `
scope {
  event: "PreToolUse"

  control {
    name: "no-create-table"
    content: "CREATE TABLE"
    msg: "STOP. Tables only through migrations."
  }
}
`;
enum contentParsed = parsePbt(contentInput);
static assert(contentParsed.scopeCount == 1);
static assert(ctrl(contentParsed, 0, 0).name == "no-create-table");
static assert(ctrl(contentParsed, 0, 0).content == "CREATE TABLE");
static assert(ctrl(contentParsed, 0, 0).msg == "STOP. Tables only through migrations.");

// buildScopes wires content into Control
enum contentBuilt = buildScopes(contentParsed, "PreToolUse");
static assert(contentBuilt.len == 1);
static assert(contentBuilt.items[0].controls[0].content.value == "CREATE TABLE");
static assert(contentBuilt.items[0].controls[0].msg.value == "STOP. Tables only through migrations.");
