module proto;

import hooks;

// --- Fixed-size intermediate structs (no GC) ---

struct ParsedPermission {
    string name;
    string tool;          // "Bash", "Write", "Edit", etc.
    string[16] allow;
    ubyte allowCount;
    string[16] deny;
    ubyte denyCount;
    string[16] ask;
    ubyte askCount;
    string msg;
}

struct ParsedControl {
    string name;
    string event; // only used for top-level controls (without enclosing scope)
    string cmd, arg, omit;
    string[16] triggers;
    ubyte triggerCount;
    string filepath, userprompt, msg;
    bool bg;
    int tmo;
    string checkHandler, delayHandler, deliverHandler;
    string deferMsg;
    int deferSec;
    int interval;
}

struct ParsedScope {
    string path, decision, event;
    ParsedControl[24] controls;
    size_t controlCount;
    ParsedPermission[16] permissions;
    size_t permissionCount;
}

struct ParseResult {
    ParsedScope[64] scopes;
    size_t scopeCount;
}

// --- Default (no-op) handler resolvers ---

private CheckFn defaultResolveCheck(string) { return null; }
private DelayFn defaultResolveDelay(string) { return null; }
private DeliverFn defaultResolveDeliver(string) { return null; }

// --- Build Scope[] from parsed pbt, filtered by event ---
// Uses fixed-size buffers to avoid GC (required by -betterC).
// Only called at CTFE — local array slices are interned by the compiler.

struct ScopeSet {
    Scope[32] items;
    Control[256] ctrlPool;
    size_t len;

    const(Scope)[] opSlice() const return { return items[0 .. len]; }
}

ScopeSet buildScopes(
    alias resolveCheck = defaultResolveCheck,
    alias resolveDelay = defaultResolveDelay,
    alias resolveDeliver = defaultResolveDeliver,
)(const ParseResult parsed, string eventFilter) {
    ScopeSet result;
    size_t poolLen = 0;

    foreach (i; 0 .. parsed.scopeCount) {
        auto ps = &parsed.scopes[i];
        if (ps.event != eventFilter) continue;

        auto ctrlStart = poolLen;
        foreach (j; 0 .. ps.controlCount) {
            auto pc = &ps.controls[j];
            Control c;
            c.name = pc.name;
            c.cmd = Cmd(pc.cmd);
            c.arg = Arg(pc.arg);
            c.omit = Omit(pc.omit);
            c.filepath = FilePath(pc.filepath);
            c.userprompt = UserPrompt(pc.userprompt);
            c.msg = Msg(pc.msg);
            c.bg = Bg(pc.bg);
            c.tmo = Tmo(pc.tmo);

            if (pc.triggerCount > 0) {
                c.trigger._buf = pc.triggers;
                c.trigger.len = pc.triggerCount;
            }

            if (pc.checkHandler.length > 0) {
                auto fn = resolveCheck(pc.checkHandler);
                assert(fn !is null);
                c.sessionstart = SessionStartTrigger(fn, null);
            }

            if (pc.deliverHandler.length > 0 && ps.event == "SessionStart") {
                auto dfn = resolveDeliver(pc.deliverHandler);
                assert(dfn !is null);
                c.sessionstart.deliver = dfn;
            }

            c.interval = pc.interval;

            if (pc.delayHandler.length > 0 || pc.deliverHandler.length > 0) {
                c.defer.delayFn = pc.delayHandler.length > 0
                    ? resolveDelay(pc.delayHandler) : null;
                c.defer.deliverFn = pc.deliverHandler.length > 0
                    ? resolveDeliver(pc.deliverHandler) : null;
                c.defer.msg = pc.deferMsg;
            } else if (pc.deferSec > 0 || pc.deferMsg.length > 0) {
                c.defer.delaySec = pc.deferSec;
                c.defer.msg = pc.deferMsg;
            }

            assert(poolLen < result.ctrlPool.length);
            result.ctrlPool[poolLen] = c;
            poolLen++;
        }

        assert(result.len < result.items.length);
        auto decision = ps.decision.length > 0 ? ps.decision : "allow";
        result.items[result.len] = Scope(ps.path, decision, result.ctrlPool[ctrlStart .. poolLen]);
        result.len++;
    }
    return result;
}

// --- Scope merging (no GC, returns by value) ---

ScopeSet mergeScopes(const ScopeSet* a, const ScopeSet* b) {
    ScopeSet result;
    foreach (i; 0 .. a.len) { result.items[result.len] = a.items[i]; result.len++; }
    foreach (i; 0 .. b.len) { result.items[result.len] = b.items[i]; result.len++; }
    return result;
}

ScopeSet mergeScopes(const ScopeSet* a, const ScopeSet* b, const ScopeSet* c) {
    ScopeSet result;
    foreach (i; 0 .. a.len) { result.items[result.len] = a.items[i]; result.len++; }
    foreach (i; 0 .. b.len) { result.items[result.len] = b.items[i]; result.len++; }
    foreach (i; 0 .. c.len) { result.items[result.len] = c.items[i]; result.len++; }
    return result;
}

// --- CTFE pbt parser ---
// Controls are data — pbt (Protocol Buffer Text) format, parsed at compile time.
// No .proto schema; format defined by convention. 4 controls reference code
// handlers by name (ciDelay, ciDeliver, binaryShadowed, controlsAreStale),
// the rest are pure name + pattern + message. The UI reads the same pbt files.
//
// Format alternatives considered:
//   HCL  — closest relative (block { } nesting), but requires = on every line
//   KDL  — compact node-based, but key="value" everywhere adds noise
//   TOML — sections + key=value, no nested blocks
//   Pkl  — Apple's config lang, clean but "new { }" stutter for list items
//   Dhall — typed with imports/functions, a programming language not a config format
//   UCL  — FreeBSD config, close but requires = or : and ;
//   Nix  — attribute sets, everything quoted + semicolons
//   INI/conf/cfg — flat key-value, no nested blocks
//
// pbt wins: `key value` on a line, blocks for nesting, quotes only when needed.
// Human-writeable, LLM-writeable, machine-parseable. No ceremony.

ParseResult parsePbt(string input) {
    ParseResult result;
    size_t pos = 0;

    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;

        if (input[pos] == '#') { skipLine(input, pos); continue; }

        auto word = readWord(input, pos);
        if (word == "scope") {
            skipWS(input, pos);
            expect(input, pos, '{');
            assert(result.scopeCount < result.scopes.length, "Scope limit reached — increase ParseResult.scopes array size in proto.d");
            result.scopes[result.scopeCount] = parseScope(input, pos);
            result.scopeCount++;
        } else if (word == "permission") {
            // Top-level permission — wrap in a scope with path "/"
            skipWS(input, pos);
            expect(input, pos, '{');
            assert(result.scopeCount < result.scopes.length, "Scope limit reached — increase ParseResult.scopes array size in proto.d");
            ParsedScope sc;
            sc.path = "/";
            sc.permissions[0] = parsePermission(input, pos);
            sc.permissionCount = 1;
            result.scopes[result.scopeCount] = sc;
            result.scopeCount++;
        } else if (word == "control") {
            // Top-level control — wrap in a scope with path "/"
            skipWS(input, pos);
            expect(input, pos, '{');
            assert(result.scopeCount < result.scopes.length, "Scope limit reached — increase ParseResult.scopes array size in proto.d");
            ParsedScope sc;
            sc.path = "/";
            sc.controls[0] = parseControl(input, pos);
            sc.event = sc.controls[0].event; // inherit event from control
            sc.controlCount = 1;
            result.scopes[result.scopeCount] = sc;
            result.scopeCount++;
        } else {
            assert(0, "Expected 'scope', 'permission', or 'control'");
        }
    }
    return result;
}

private:

ParsedScope parseScope(ref string input, ref size_t pos) {
    ParsedScope sc;
    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }
        if (input[pos] == '}') { pos++; return sc; }

        auto key = readWord(input, pos);
        if (key == "control") {
            skipWS(input, pos);
            expect(input, pos, '{');
            assert(sc.controlCount < sc.controls.length);
            sc.controls[sc.controlCount] = parseControl(input, pos);
            sc.controlCount++;
        } else if (key == "permission") {
            skipWS(input, pos);
            expect(input, pos, '{');
            assert(sc.permissionCount < sc.permissions.length);
            sc.permissions[sc.permissionCount] = parsePermission(input, pos);
            sc.permissionCount++;
        } else {
            skipWS(input, pos);
            expect(input, pos, ':');
            skipWS(input, pos);
            auto val = readValue(input, pos);
            switch (key) {
                case "path":     sc.path = val; break;
                case "decision": sc.decision = val; break;
                case "event":    sc.event = val; break;
                default: assert(0, "Unknown scope field");
            }
        }
    }
    assert(0, "Unterminated scope block");
}

ParsedControl parseControl(ref string input, ref size_t pos) {
    ParsedControl c;
    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }
        if (input[pos] == '}') { pos++; return c; }

        auto key = readWord(input, pos);
        skipWS(input, pos);
        expect(input, pos, ':');
        skipWS(input, pos);
        auto val = readValue(input, pos);

        switch (key) {
            case "name":            c.name = val; break;
            case "event":           c.event = val; break;
            case "cmd":             c.cmd = val; break;
            case "arg":             c.arg = val; break;
            case "omit":            c.omit = val; break;
            case "filepath":        c.filepath = val; break;
            case "userprompt":      c.userprompt = val; break;
            case "msg":             c.msg = val; break;
            case "bg":              c.bg = (val == "true"); break;
            case "tmo":             c.tmo = parseInt(val); break;
            case "check_handler":   c.checkHandler = val; break;
            case "delay_handler":   c.delayHandler = val; break;
            case "deliver_handler": c.deliverHandler = val; break;
            case "defer_msg":       c.deferMsg = val; break;
            case "defer_sec":       c.deferSec = parseInt(val); break;
            case "interval":        c.interval = parseInt(val); break;
            case "stop":
            case "posttool":
                if (val is null) {
                    // List syntax: stop: ["a", "b", ...]
                    while (pos < input.length) {
                        skipWS(input, pos);
                        if (pos < input.length && input[pos] == ']') { pos++; break; }
                        auto item = readValue(input, pos);
                        assert(c.triggerCount < 16);
                        c.triggers[c.triggerCount] = item;
                        c.triggerCount++;
                        skipWS(input, pos);
                        if (pos < input.length && input[pos] == ',') pos++;
                    }
                } else {
                    assert(c.triggerCount < 16);
                    c.triggers[c.triggerCount] = val;
                    c.triggerCount++;
                }
                break;
            default: assert(0, "Unknown control field");
        }
    }
    assert(0, "Unterminated control block");
}

// Infer permission name: strip wildcards/spaces from first pattern
string inferFirstPattern(const ref ParsedPermission p) {
    string pat;
    if (p.allowCount > 0) pat = p.allow[0];
    else if (p.denyCount > 0) pat = p.deny[0];
    else if (p.askCount > 0) pat = p.ask[0];
    else return null;

    size_t start = 0;
    size_t end = pat.length;
    while (start < end && (pat[start] == '*' || pat[start] == ' ')) start++;
    while (end > start && (pat[end - 1] == '*' || pat[end - 1] == ' ')) end--;
    if (start >= end) return null;
    return pat[start .. end];
}

ParsedPermission parsePermission(ref string input, ref size_t pos) {
    ParsedPermission p;
    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }
        if (input[pos] == '}') {
            pos++;
            if (p.name is null) p.name = inferFirstPattern(p);
            return p;
        }

        auto key = readWord(input, pos);
        skipWS(input, pos);
        expect(input, pos, ':');
        skipWS(input, pos);
        auto val = readValue(input, pos);

        switch (key) {
            case "name": p.name = val; break;
            case "tool": p.tool = val; break;
            case "msg":  p.msg = val; break;
            case "allow":
                if (val is null) {
                    while (pos < input.length) {
                        skipWS(input, pos);
                        if (pos < input.length && input[pos] == ']') { pos++; break; }
                        auto item = readValue(input, pos);
                        assert(p.allowCount < 16);
                        p.allow[p.allowCount] = item;
                        p.allowCount++;
                        skipWS(input, pos);
                        if (pos < input.length && input[pos] == ',') pos++;
                    }
                } else {
                    assert(p.allowCount < 16);
                    p.allow[p.allowCount] = val;
                    p.allowCount++;
                }
                break;
            case "deny":
                if (val is null) {
                    while (pos < input.length) {
                        skipWS(input, pos);
                        if (pos < input.length && input[pos] == ']') { pos++; break; }
                        auto item = readValue(input, pos);
                        assert(p.denyCount < 16);
                        p.deny[p.denyCount] = item;
                        p.denyCount++;
                        skipWS(input, pos);
                        if (pos < input.length && input[pos] == ',') pos++;
                    }
                } else {
                    assert(p.denyCount < 16);
                    p.deny[p.denyCount] = val;
                    p.denyCount++;
                }
                break;
            case "ask":
                if (val is null) {
                    while (pos < input.length) {
                        skipWS(input, pos);
                        if (pos < input.length && input[pos] == ']') { pos++; break; }
                        auto item = readValue(input, pos);
                        assert(p.askCount < 16);
                        p.ask[p.askCount] = item;
                        p.askCount++;
                        skipWS(input, pos);
                        if (pos < input.length && input[pos] == ',') pos++;
                    }
                } else {
                    assert(p.askCount < 16);
                    p.ask[p.askCount] = val;
                    p.askCount++;
                }
                break;
            default: assert(0, "Unknown permission field");
        }
    }
    assert(0, "Unterminated permission block");
}

// --- Lexer helpers ---

void skipWS(ref string s, ref size_t pos) {
    while (pos < s.length && (s[pos] == ' ' || s[pos] == '\t' || s[pos] == '\n' || s[pos] == '\r'))
        pos++;
}

void skipLine(ref string s, ref size_t pos) {
    while (pos < s.length && s[pos] != '\n') pos++;
    if (pos < s.length) pos++;
}

void expect(ref string s, ref size_t pos, char ch) {
    assert(pos < s.length && s[pos] == ch);
    pos++;
}

string readWord(ref string s, ref size_t pos) {
    auto start = pos;
    while (pos < s.length && s[pos] != ' ' && s[pos] != '\t' && s[pos] != '\n'
            && s[pos] != '\r' && s[pos] != ':' && s[pos] != '{' && s[pos] != '}')
        pos++;
    assert(pos > start);
    return s[start .. pos];
}

string readValue(ref string s, ref size_t pos) {
    if (pos < s.length && s[pos] == '"')
        return readQuotedString(s, pos);
    if (pos < s.length && s[pos] == '`')
        return readBacktickString(s, pos);
    if (pos < s.length && s[pos] == '[') {
        pos++; // consume '['
        return null; // signal list to caller
    }
    // Unquoted value (true, false, integer)
    auto start = pos;
    while (pos < s.length && s[pos] != ' ' && s[pos] != '\t' && s[pos] != '\n'
            && s[pos] != '\r' && s[pos] != '}')
        pos++;
    return s[start .. pos];
}

// Double-quoted string — no escapes, returns input slice directly.
string readQuotedString(ref string s, ref size_t pos) {
    pos++; // skip opening quote
    auto start = pos;
    while (pos < s.length && s[pos] != '"')
        pos++;
    auto result = s[start .. pos];
    assert(pos < s.length);
    pos++; // skip closing quote
    return result;
}

// Backtick string — for values containing double quotes.
string readBacktickString(ref string s, ref size_t pos) {
    pos++; // skip opening backtick
    auto start = pos;
    while (pos < s.length && s[pos] != '`')
        pos++;
    auto result = s[start .. pos];
    assert(pos < s.length);
    pos++; // skip closing backtick
    return result;
}

int parseInt(string s) {
    int result = 0;
    bool neg = false;
    size_t i = 0;
    if (i < s.length && s[i] == '-') { neg = true; i++; }
    while (i < s.length && s[i] >= '0' && s[i] <= '9') {
        result = result * 10 + (s[i] - '0');
        i++;
    }
    return neg ? -result : result;
}

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
    msg: "Wrong. Previous conversations are accessible. JSONL transcripts are stored at ~/.claude/projects/. The graunde db at ~/.local/share/graunde/graunde.db stores last_assistant_message in Stop attestation attributes. Check before claiming you can't."
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
enum stopDeliverBuilt = buildScopes!(defaultResolveCheck, defaultResolveDelay, testResolveDeliver)(stopDeliverParsed, "Stop");
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
    tool: "Bash"
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
static assert(permParsed.scopes[0].permissions[0].tool == "Bash");
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
    tool: "Bash"
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
    tool: "Bash"
    allow: ["npm run*"]
  }
}
`;
enum permMixedParsed = parsePbt(permMixedInput);
static assert(permMixedParsed.scopes[0].controlCount == 1);
static assert(permMixedParsed.scopes[0].controls[0].name == "test-ctrl");
static assert(permMixedParsed.scopes[0].permissionCount == 1);
static assert(permMixedParsed.scopes[0].permissions[0].tool == "Bash");
static assert(permMixedParsed.scopes[0].permissions[0].allow[0] == "npm run*");

// Multiple permissions in one scope
enum permMultiInput = `
scope {
  path: "/"
  permission {
    tool: "Bash"
    allow: ["*sleep*", "*say*"]
  }
  permission {
    tool: "Bash"
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
  tool: "Bash"
  allow: ["go build*", "make*"]
}

permission {
  tool: "Bash"
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
static assert(permTopParsed.scopes[0].permissions[0].tool == "Bash");
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
