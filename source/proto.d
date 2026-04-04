module proto;

import hooks;

// --- Fixed-size intermediate structs (no GC) ---

struct ParsedPermission {
    string name;
    string mode;          // chmod-style mode (r/w/x/m/a), parsed from permission.r syntax
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
    string mode;  // chmod-style mode (r/w/x/m/a), parsed from control.w syntax
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
            c.mode = Mode(pc.mode);
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
        auto wm = splitMode(word);
        if (wm.base == "scope") {
            skipWS(input, pos);
            expect(input, pos, '{');
            parseScope(input, pos, result, "", "");
        } else if (wm.base == "permission") {
            // Top-level permission — wrap in a scope with path "/"
            skipWS(input, pos);
            expect(input, pos, '{');
            assert(result.scopeCount < result.scopes.length, "Scope limit reached — increase ParseResult.scopes array size in proto.d");
            ParsedScope sc;
            sc.path = "/";
            sc.permissions[0] = parsePermission(input, pos);
            sc.permissions[0].mode = wm.mode;
            sc.permissionCount = 1;
            result.scopes[result.scopeCount] = sc;
            result.scopeCount++;
        } else if (wm.base == "control") {
            // Top-level control — wrap in a scope with path "/"
            skipWS(input, pos);
            expect(input, pos, '{');
            assert(result.scopeCount < result.scopes.length, "Scope limit reached — increase ParseResult.scopes array size in proto.d");
            ParsedScope sc;
            sc.path = "/";
            sc.controls[0] = parseControl(input, pos);
            sc.controls[0].mode = wm.mode;
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

void parseScope(ref string input, ref size_t pos, ref ParseResult result,
    string parentPath, string parentDecision, string parentEvent = "")
{
    ParsedScope sc;
    sc.path = parentPath;
    sc.decision = parentDecision;
    sc.event = parentEvent;
    bool hasChildren = false;

    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }
        if (input[pos] == '}') {
            pos++;
            // Only emit this scope if it has controls or permissions (not just children)
            if (!hasChildren || sc.controlCount > 0 || sc.permissionCount > 0) {
                assert(result.scopeCount < result.scopes.length,
                    "Scope limit reached — increase ParseResult.scopes array size in proto.d");
                result.scopes[result.scopeCount] = sc;
                result.scopeCount++;
            }
            return;
        }

        auto key = readWord(input, pos);
        auto wm = splitMode(key);
        if (wm.base == "scope") {
            skipWS(input, pos);
            expect(input, pos, '{');
            hasChildren = true;
            parseScope(input, pos, result, sc.path, sc.decision, sc.event);
        } else if (wm.base == "control") {
            skipWS(input, pos);
            expect(input, pos, '{');
            assert(sc.controlCount < sc.controls.length);
            sc.controls[sc.controlCount] = parseControl(input, pos);
            sc.controls[sc.controlCount].mode = wm.mode;
            sc.controlCount++;
        } else if (wm.base == "permission") {
            skipWS(input, pos);
            expect(input, pos, '{');
            assert(sc.permissionCount < sc.permissions.length);
            sc.permissions[sc.permissionCount] = parsePermission(input, pos);
            sc.permissions[sc.permissionCount].mode = wm.mode;
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
            // "tool" removed — use control.w/r/x/m/a syntax instead
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
            // "tool" removed — use permission.r/w/x syntax instead
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

// Split "control.rw" into ("control", "rw"). No dot returns (word, "").
struct WordMode { string base; string mode; }
WordMode splitMode(string word) {
    foreach (i; 0 .. word.length) {
        if (word[i] == '.') return WordMode(word[0 .. i], word[i + 1 .. $]);
    }
    return WordMode(word, "");
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

