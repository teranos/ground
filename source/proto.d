module proto;

import hooks;

// --- Fixed-size intermediate structs (no GC) ---

struct ParsedControl {
    string name;
    string cmd, arg, omit;
    string[2] triggers;
    ubyte triggerCount;
    string filepath, userprompt, msg;
    bool bg;
    int tmo;
    string checkHandler, delayHandler, deliverHandler;
    string deferPrefix;
    int deferSec;
}

struct ParsedScope {
    string path, decision, event;
    ParsedControl[24] controls;
    size_t controlCount;
}

struct ParseResult {
    ParsedScope[32] scopes;
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
                c.sessionstart = SessionStartTrigger(fn);
            }

            if (pc.delayHandler.length > 0 || pc.deliverHandler.length > 0) {
                c.defer.delayFn = pc.delayHandler.length > 0
                    ? resolveDelay(pc.delayHandler) : null;
                c.defer.deliverFn = pc.deliverHandler.length > 0
                    ? resolveDeliver(pc.deliverHandler) : null;
                c.defer.msgPrefix = pc.deferPrefix;
            } else if (pc.deferSec > 0 || pc.deferPrefix.length > 0) {
                c.defer.delaySec = pc.deferSec;
                c.defer.msgPrefix = pc.deferPrefix;
            }

            assert(poolLen < result.ctrlPool.length);
            result.ctrlPool[poolLen] = c;
            poolLen++;
        }

        assert(result.len < result.items.length);
        result.items[result.len] = Scope(ps.path, ps.decision, result.ctrlPool[ctrlStart .. poolLen]);
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
            assert(result.scopeCount < result.scopes.length);
            result.scopes[result.scopeCount] = parseScope(input, pos);
            result.scopeCount++;
        } else {
            assert(0, "Expected 'scope'");
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
            case "defer_prefix":    c.deferPrefix = val; break;
            case "defer_sec":       c.deferSec = parseInt(val); break;
            case "stop":
            case "posttool":
                assert(c.triggerCount < 2);
                c.triggers[c.triggerCount] = val;
                c.triggerCount++;
                break;
            default: assert(0, "Unknown control field");
        }
    }
    assert(0, "Unterminated control block");
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
    defer_prefix: "CI: "
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
`;

// Test parse structure
enum testParsed = parsePbt(testInput);
static assert(testParsed.scopeCount == 4);

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
static assert(testParsed.scopes[2].controls[0].deferPrefix == "CI: ");

// Scope 3: SessionStart with check handler
static assert(testParsed.scopes[3].controls[0].checkHandler == "testCheck");

// Test buildScopes without handlers (default resolvers)
enum testBuilt = buildScopes(testParsed, "PreToolUse");
static assert(testBuilt.len == 1);
static assert(testBuilt.items[0].controls.length == 2);
static assert(testBuilt.items[0].controls[0].name == "test-cmd");
static assert(testBuilt.items[0].controls[0].cmd.value == "git");
static assert(testBuilt.items[0].controls[0].omit.value == "--no-verify");
static assert(testBuilt.items[0].controls[1].bg.value == true);
static assert(testBuilt.items[0].controls[1].tmo.value == 5000);

// Test Stop scope filtering
enum testStopBuilt = buildScopes(testParsed, "Stop");
static assert(testStopBuilt.len == 1);
static assert(testStopBuilt.items[0].path == "/QNTX");
static assert(testStopBuilt.items[0].controls[0].trigger.len == 2);
static assert(testStopBuilt.items[0].controls[0].trigger._buf[0] == "likely because");
