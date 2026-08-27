module proto;

import hooks;
import receiver : Receiver, parseReceiver;
import strop : parseStropBlock, Strop, MAX_STROP_POOL;

// TODO: pbt variable/template support — define a message once, reference it in multiple controls.
//       Like HCL locals: local { sbvh_ctx = "..." } then msg: local.sbvh_ctx
//       Requires a pre-parse expansion pass before the two-pass CTFE.

// --- Two-pass CTFE sizing ---
// Pass 1 (count.d) counts blocks, pass 2 parses into right-sized arrays.

import count : countPbt, PbtCounts;

private enum _sand = import(".ctfe/sand");
enum pbtCounts = countPbt(_sand);

// --- Intermediate structs — sized by pass 1 ---

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
    // The repo the holding project named, empty when it named none.
    string origin;
    // The ritual this control performs. An inline body is registered like any
    // other ritual; the index is 1-based so 0 means it named one instead.
    string ritual;
    size_t inlineRitualIdx;
    string event; // only used for top-level controls (without enclosing scope)
    string mode;  // chmod-style mode (r/w/x/m/a), parsed from control.w syntax
    string[8] cmds;
    ubyte cmdCount;
    string cmd() const { return cmdCount > 0 ? cmds[0] : ""; }
    string arg, omit, omitLine, clamp;
    string[16] triggers;
    ubyte triggerCount;
    string filepath, msg, mcpArg, pushedPath, exec;
    string[8] contents;
    ubyte contentCount;
    string[8] substituteForRead;
    ubyte substituteForReadCount;
    string substituteForCmd;
    string[8] userprompts;
    ubyte userpromptCount;
    string[32] rewrites;
    ubyte rewriteCount;
    bool bg;
    int tmo;
    string checkHandler, delayHandler, deliverHandler;
    string deferMsg;
    int deferSec;
    int interval;
    int commentRun;
    string[8] paramKeys;
    string[8] paramValues;
    ubyte paramCount;
    string[8] envKeys;
    string[8] envValues;
    ubyte envCount;
    size_t stropIdx; // 0 = no strop; else 1-based index into ParseResult.stropPool.
}

struct ParsedScope {
    string[8] paths;
    ubyte pathCount;
    string[8] edited;
    ubyte editedCount;
    string[8] cmds;
    ubyte cmdCount;
    string decision, event;
    string[3] extraEvents;
    ubyte extraEventCount;
    string mcpTool;
    size_t controlStart, controlEnd;     // indices into ParseResult.ctrlPool
    size_t permStart, permEnd;           // indices into ParseResult.permPool

    size_t controlCount() const { return controlEnd - controlStart; }
    size_t permissionCount() const { return permEnd - permStart; }
}

struct ParsedProject {
    // Several blocks can share a path, and the name is what tells them apart.
    // Empty is the unnamed block, which wins when a word resolves to both.
    string name;
    string path;
    // The repo this project is, when it says so. Set, it outranks path: every
    // checkout of that repo is this project, including ones made later.
    string origin;
    // Per performance, a full run of a ritual. Zero means the project said
    // nothing and MAX_GOTOS stands.
    size_t maxGoto;
    string[1024] files;
    size_t fileCount;
}

struct ParsedEnv {
    string path;
    string[16] keys;
    string[16] values;
    ubyte count;
}

struct ParsedQntxNode {
    string url;
}

struct ParsedAttestation {
    string subject;
    string predicate;
    string context;
    string attributes; // raw JSON
}

// A rite is a command and a verdict. `cmd` is the only required field.
struct ParsedRite {
    string name;
    // "to me its eval" — the operation. `pass`, `catch`, `goto`, `to`, `wait`
    // and `mic` are what the writer changes its default behaviour with.
    string eval;
    // "a different rite that runs a tool unconditionally". Fires once when the
    // rite is entered, before the agent has the mic. A non-zero halts.
    string run;
    // "dispatch could be its own thing, its own abstraction" — "<owner>/<repo>
    // <workflow>". Both halves of the rite: sending is the doing, and the run's
    // conclusion is the answer.
    string dispatch;
    // A shell fragment run in the worktree. Each line it prints becomes one -f,
    // which is the only part of a dispatch ground cannot know for itself.
    string inputs;
    // A field this rite named that no rite has. Carried so the refusal can
    // say which one, which betterC forbids building at the parse site.
    string badKey;
    string msg;
    // "mic makes sure it also gets to us"
    // "nothing / msg / mic / msg+mic are all possible"
    string mic;
    int pass;
    int[8] catches;
    size_t catchCount;
    string goto_;
    // Seconds ground holds after throwing the Stop back, not before. Neither
    // side has it for that long, which is the one window a throw-back is
    // visible in — the throw itself has no duration to see.
    int grace = 2;
    // Seconds ground sleeps before running the rite at all, so the first look
    // is taken after whatever the turn left in flight has settled. Nothing
    // shortens it — there is no answer yet to shorten it with.
    int wait = 0;
    // Where this rite's verdict goes. Silence is silence: a rite that names
    // no receiver reports to nobody, which is the only honest default when
    // the alternative is guessing that somebody wanted to hear it.
    Receiver to = Receiver.None;
}

// A rites group is material — it is never invoked, only referenced.
struct ParsedRites {
    string name;
    string[8] params;
    size_t paramCount;
    ParsedRite[32] rites;
    size_t riteCount;
}

// A reference from a ritual to a rites group. A bare name carries nothing;
// a name with a block carries values for that group's params.
struct ParsedRiteRef {
    string name;
    string[8] keys;
    string[8] values;
    size_t valueCount;
}

// A ritual is the only thing that can be invoked, and it lives inside the
// project whose env its rites read.
struct ParsedRitual {
    string name;
    // The block this ritual was declared in. Empty is the unnamed one.
    string projectName;
    string projectPath;
    // "define a CLAUDE.md inline in a ritual" — appended to what the agent
    // already is, so a ritual says what this performer additionally knows.
    string system;
    // What kind of worktree it performs in. "empty" is an orphan onto the
    // empty tree, for a ritual with nothing to inspect.
    string tree;
    string badKey;
    ParsedRiteRef[16] refs;
    size_t refCount;
}

struct ParseResult {
    ParsedRites[32] rites;
    size_t ritesCount;
    ParsedRitual[16] rituals;
    size_t ritualCount;
    ParsedScope[pbtCounts.totalScopes + 1] scopes;
    size_t scopeCount;
    ParsedControl[pbtCounts.totalControls + 1] ctrlPool;
    size_t ctrlPoolLen;
    ParsedPermission[pbtCounts.totalPerms + 1] permPool;
    size_t permPoolLen;
    ParsedProject[pbtCounts.totalProjects + 4] projects;
    size_t projectCount;
    ParsedEnv[pbtCounts.totalEnvs + 4] envs;
    size_t envCount;
    ParsedQntxNode[16] qntxNodes;
    size_t qntxNodeCount;
    ParsedAttestation[128] attestations;
    size_t attestationCount;
    Strop[MAX_STROP_POOL] stropPool;
    size_t stropPoolLen;
}

// What is wrong with a ritual, in a buffer rather than a concatenation. `~`
// allocates, and this project has no GC, so a message built with it compiles
// only while nothing emits this function as runtime code.
struct Wrong {
    char[192] buf = 0;
    size_t len;
    const(char)[] text() const return { return buf[0 .. len]; }
}

private void say(ref Wrong w, const(char)[] s) {
    foreach (c; s) { if (w.len < w.buf.length) w.buf[w.len++] = c; }
}

private Wrong wrong(const(char)[] a, const(char)[] b = "", const(char)[] c = "",
                    const(char)[] d = "", const(char)[] e = "",
                    const(char)[] f = "") {
    Wrong w;
    w.say(a); w.say(b); w.say(c); w.say(d); w.say(e); w.say(f);
    return w;
}

// What is worth saying about a ritual that is not worth refusing it for. All
// of them, not the first: a warning you fix one at a time is a build you run
// once per warning.
struct Warns {
    char[1024] buf = 0;
    size_t len;
    const(char)[] text() const return { return buf[0 .. len]; }
}

private void say(ref Warns w, const(char)[] s) {
    foreach (c; s) { if (w.len < w.buf.length) w.buf[w.len++] = c; }
}

// A value handed to a block that declares no such param goes nowhere. The
// rite still runs, so this is informational — "make this a warn, but still let
// it pass, like informational warn, that its not used".
Warns warnRituals(PR)(const PR r) {
    Warns w;
    foreach (i; 0 .. r.ritualCount) {
        foreach (j; 0 .. r.rituals[i].refCount) {
            auto refName = r.rituals[i].refs[j].name;
            ptrdiff_t gi = -1;
            foreach (m; 0 .. r.ritesCount)
                if (r.rites[m].name == refName) gi = m;
            if (gi < 0) continue;

            foreach (v; 0 .. r.rituals[i].refs[j].valueCount) {
                auto key = r.rituals[i].refs[j].keys[v];
                bool declared = false;
                foreach (p; 0 .. r.rites[gi].paramCount)
                    if (r.rites[gi].params[p] == key) declared = true;
                if (declared) continue;

                w.say("ritual ");
                w.say(r.rituals[i].name);
                w.say(": ");
                w.say(refName);
                w.say(" declares no param `");
                w.say(key);
                w.say("`, so the value is unused\n");
            }
        }
    }
    return w;
}

// Everything a ritual can be wrong about before it runs. Empty when clean,
// else one message — a value rather than an assert, because an assert at CTFE
// cannot be caught by a static assert.
// A permission is a grant, and a grant says which session modes it reaches.
// Written without one it reached every mode, manual included, so ground
// approved what the operator had asked to see.
Wrong validatePermissions(PR)(const PR r) {
    import posttooluse : sessionSegment;

    foreach (i; 0 .. r.permPoolLen) {
        auto p = &r.permPool[i];
        if (p.allowCount == 0) continue;
        if (sessionSegment(p.mode).length > 0) continue;

        if (p.mode.length == 0)
            return wrong("permission ", p.name,
                         ": names no session mode. Write permission.x.<modes>");
        return wrong("permission.", p.mode, " ", p.name,
                     ": names no session mode. Add .<modes> after the tool letters");
    }
    return Wrong.init;
}

Wrong validateRituals(PR)(const PR r) {
    // "within a rites block, rite should be unique, yes. but in my mental
    // image, you can have a same name rite in multiple RITES"
    foreach (i; 0 .. r.ritesCount) {
        foreach (j; 0 .. r.rites[i].riteCount) {
            auto name = r.rites[i].rites[j].name;
            foreach (n; 0 .. r.rites[i].riteCount) {
                if (n == j) continue;
                if (r.rites[i].rites[n].name == name)
                    return wrong("duplicate rite name: ", name);
            }
        }
    }

    // A field no ritual has.
    foreach (i; 0 .. r.ritualCount) {
        if (r.rituals[i].badKey.length > 0)
            return wrong("ritual ", r.rituals[i].name, ": unknown field `",
                         r.rituals[i].badKey, "`");
    }

    // A field no rite has. `cmd` gets its own line because it is a real word
    // elsewhere in the grammar, pointing the other way.
    foreach (i; 0 .. r.ritesCount) {
        foreach (j; 0 .. r.rites[i].riteCount) {
            auto bad = r.rites[i].rites[j].badKey;
            if (bad.length == 0) continue;
            if (bad == "cmd")
                return wrong("rite ", r.rites[i].rites[j].name, ": `cmd` is a control's word. A rite evaluates: use `eval`");
            return wrong("rite ", r.rites[i].rites[j].name, ": unknown field `",
                         bad, "`");
        }
    }

    // "|| TRUE || EXIT 1 || EXIT 22 || EXIT WHATEVER SHOUDL NOT BE A THING IN
    // GROUND" — a rite that stamps its own code leaves ground one event where
    // the tool gave several.
    foreach (i; 0 .. r.ritesCount) {
        foreach (j; 0 .. r.rites[i].riteCount) {
            import rite : launders;
            enum tail = " writes its own exit code. Let the tool answer";
            auto rt = r.rites[i].rites[j];
            if (launders(rt.eval))
                return wrong("rite ", rt.name, ": `eval`", tail);
            if (launders(rt.run))
                return wrong("rite ", rt.name, ": `run`", tail);
        }
    }

    // A code that both advances and holds makes the rite mean two things.
    foreach (i; 0 .. r.ritesCount) {
        foreach (j; 0 .. r.rites[i].riteCount) {
            foreach (c; 0 .. r.rites[i].rites[j].catchCount) {
                if (r.rites[i].rites[j].catches[c] == r.rites[i].rites[j].pass) {
                    auto n = r.rites[i].rites[j].pass == 0 ? "0" :
                             r.rites[i].rites[j].pass == 1 ? "1" : "that code";
                    return wrong("rite ", r.rites[i].rites[j].name,
                                 ": ", n, " is both pass and catch");
                }
            }
        }
    }

    // "DISPATCH AND EVAL ARE DIFFERENT THIGNS"
    foreach (i; 0 .. r.ritesCount) {
        foreach (j; 0 .. r.rites[i].riteCount) {
            auto rr = r.rites[i].rites[j];
            if (rr.dispatch.length == 0 || rr.eval.length == 0) continue;
            return wrong("rite ", rr.name,
                         ": dispatch is not asked, so it cannot carry an eval");
        }
    }

    // A goto naming nothing is a jump into the dark.
    foreach (i; 0 .. r.ritesCount) {
        foreach (j; 0 .. r.rites[i].riteCount) {
            auto target = r.rites[i].rites[j].goto_;
            if (target.length == 0) continue;
            bool found = false;
            foreach (m; 0 .. r.ritesCount)
                foreach (n; 0 .. r.rites[m].riteCount)
                    if (r.rites[m].rites[n].name == target) found = true;
            if (!found) return wrong("goto names no rite: ", target);
        }
    }

    foreach (i; 0 .. r.ritualCount) {
        foreach (j; 0 .. r.rituals[i].refCount) {
            auto refName = r.rituals[i].refs[j].name;
            ptrdiff_t gi = -1;
            foreach (m; 0 .. r.ritesCount)
                if (r.rites[m].name == refName) gi = m;

            // A ritual performing a group that does not exist.
            if (gi < 0)
                return wrong("ritual ", r.rituals[i].name,
                             ": no rites named ", refName);

            // An unsupplied param expands to empty, and an empty grep
            // pattern matches anything — a false pass.
            foreach (p; 0 .. r.rites[gi].paramCount) {
                auto need = r.rites[gi].params[p];
                bool supplied = false;
                foreach (v; 0 .. r.rituals[i].refs[j].valueCount)
                    if (r.rituals[i].refs[j].keys[v] == need) supplied = true;
                if (!supplied)
                    return wrong("ritual ", r.rituals[i].name, ": ",
                                 refName, " needs ", need);
            }
        }
    }

    return Wrong();
}

// --- Flat file list extraction (CTFE) ---
// Flattens all project file lists into a single array for runtime lookup.

struct ProjectFileList(size_t N) {
    string[N] files;
    size_t len;
}

auto extractProjectFiles(PR)(const PR parsed) {
    // Count total files across all projects
    size_t total = 0;
    foreach (i; 0 .. parsed.projectCount)
        total += parsed.projects[i].fileCount;

    ProjectFileList!(PR.init.projects.length * 4096) result;
    size_t pos = 0;
    foreach (i; 0 .. parsed.projectCount) {
        foreach (j; 0 .. parsed.projects[i].fileCount) {
            result.files[pos++] = parsed.projects[i].files[j];
        }
    }
    result.len = pos;
    return result;
}

// --- Env lookup (CTFE) ---
// Finds the env block whose path best matches cwd, returns value for key.
// Returns null if no match. Used by CTFE tests; runtime uses envSubst.

string envLookup(PR)(const PR parsed, string cwd, string key) {
    int bestIdx = -1;
    size_t bestLen = 0;
    foreach (i; 0 .. parsed.envCount) {
        auto p = parsed.envs[i].path;
        if (p.length > 0 && cwd.length >= p.length) {
            // Substring match (same as runtime contains)
            foreach (j; 0 .. cwd.length - p.length + 1) {
                if (cwd[j .. j + p.length] == p) {
                    if (p.length > bestLen) {
                        bestLen = p.length;
                        bestIdx = cast(int) i;
                    }
                    break;
                }
            }
        }
    }
    if (bestIdx < 0) return null;
    foreach (k; 0 .. parsed.envs[bestIdx].count) {
        if (parsed.envs[bestIdx].keys[k] == key)
            return parsed.envs[bestIdx].values[k];
    }
    return null;
}

// --- Default (no-op) handler resolvers ---

private CheckFn defaultResolveCheck(string) { return null; }
private DelayFn defaultResolveDelay(string) { return null; }
private DeliverFn defaultResolveDeliver(string) { return null; }

// --- Build Scope[] from parsed pbt, filtered by event ---
// Uses fixed-size buffers to avoid GC (required by -betterC).
// Only called at CTFE — local array slices are interned by the compiler.

struct ScopeSet {
    Scope[pbtCounts.totalScopes + 1] items;
    Control[pbtCounts.totalControls + 1] ctrlPool;
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
        if (ps.event != eventFilter) {
            bool found = false;
            foreach (ei; 0 .. ps.extraEventCount)
                if (ps.extraEvents[ei] == eventFilter) { found = true; break; }
            if (!found) continue;
        }

        auto ctrlStart = poolLen;
        foreach (j; ps.controlStart .. ps.controlEnd) {
            auto pc = &parsed.ctrlPool[j];
            Control c;
            c.name = pc.name;
            c.mode = Mode(pc.mode);
            if (pc.cmdCount > 0) {
                c.cmd._buf = pc.cmds;
                c.cmd.len = pc.cmdCount;
            } else if (pc.stropIdx > 0 && ps.cmdCount > 0) {
                // Strop control inherits enclosing scope's cmd so checkAllCommands
                // routes it to Bash dispatch. Only for strop; other controls keep
                // their own cmd semantics.
                c.cmd._buf = ps.cmds;
                c.cmd.len = ps.cmdCount;
            }
            c.arg = Arg(pc.arg);
            c.omit = Omit(pc.omit);
            c.omitLine = OmitLine(pc.omitLine);
            c.clamp = Clamp(pc.clamp);
            c.filepath = FilePath(pc.filepath);
            c.pushedPath = PushedPath(pc.pushedPath);
            if (pc.userpromptCount > 0) {
                c.userprompt._buf = pc.userprompts;
                c.userprompt.len = pc.userpromptCount;
            }
            if (pc.rewriteCount > 0) {
                c.rewrites._buf = pc.rewrites;
                c.rewrites.len = pc.rewriteCount;
            }
            c.msg = Msg(pc.msg);
            c.mcpArg = McpArg(pc.mcpArg);
            if (pc.contentCount > 0) {
                c.content._buf = pc.contents;
                c.content.len = pc.contentCount;
            }
            if (pc.substituteForReadCount > 0) {
                c.substituteForRead._buf = pc.substituteForRead;
                c.substituteForRead.len = pc.substituteForReadCount;
            }
            c.substituteForCmd = SubstituteForCmd(pc.substituteForCmd);
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

            if (pc.paramCount > 0) {
                c.paramKeys = pc.paramKeys;
                c.paramValues = pc.paramValues;
                c.paramCount = pc.paramCount;
            }

            if (pc.envCount > 0) {
                c.envKeys = pc.envKeys;
                c.envValues = pc.envValues;
                c.envCount = pc.envCount;
            }

            c.exec = pc.exec;
            c.origin = pc.origin;
            c.ritual = pc.ritual;

            if (pc.deliverHandler.length > 0 && ps.event == "SessionStart") {
                auto dfn = resolveDeliver(pc.deliverHandler);
                assert(dfn !is null);
                c.sessionstart.deliver = dfn;
            }

            c.interval = pc.interval;
            c.commentRun = pc.commentRun;
            c.stropIdx = pc.stropIdx;

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
        Scope s;
        s.paths = ps.paths;
        s.pathCount = ps.pathCount;
        s.edited = ps.edited;
        s.editedCount = ps.editedCount;
        s.cmds = ps.cmds;
        s.cmdCount = ps.cmdCount;
        s.decision = decision;
        s.mcpTool = ps.mcpTool;
        s.controls = result.ctrlPool[ctrlStart .. poolLen];
        result.items[result.len] = s;
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
            assert(result.scopeCount < result.scopes.length, "Scope overflow — pbtCounts.totalScopes too small");
            ParsedScope sc;
            sc.paths[0] = "/"; sc.pathCount = 1;
            sc.permStart = result.permPoolLen;
            assert(result.permPoolLen < result.permPool.length);
            result.permPool[result.permPoolLen] = parsePermission(input, pos);
            result.permPool[result.permPoolLen].mode = wm.mode;
            result.permPoolLen++;
            sc.permEnd = result.permPoolLen;
            result.scopes[result.scopeCount] = sc;
            result.scopeCount++;
        } else if (wm.base == "control") {
            // Top-level control — wrap in a scope with path "/"
            skipWS(input, pos);
            expect(input, pos, '{');
            assert(result.scopeCount < result.scopes.length, "Scope overflow — pbtCounts.totalScopes too small");
            ParsedScope sc;
            sc.paths[0] = "/"; sc.pathCount = 1;
            sc.controlStart = result.ctrlPoolLen;
            assert(result.ctrlPoolLen < result.ctrlPool.length);
            result.ctrlPool[result.ctrlPoolLen] = parseControl(input, pos, result);
            result.ctrlPool[result.ctrlPoolLen].mode = wm.mode;
            sc.event = result.ctrlPool[result.ctrlPoolLen].event; // inherit event
            result.ctrlPoolLen++;
            sc.controlEnd = result.ctrlPoolLen;
            result.scopes[result.scopeCount] = sc;
            result.scopeCount++;
        } else if (wm.base == "project") {
            skipWS(input, pos);
            // `project { }` and `project <name> { }` both. A word before the
            // brace names the block; several blocks may share one path.
            string projectName;
            if (isNameStart(input, pos)) {
                projectName = readWord(input, pos);
                skipWS(input, pos);
            }
            expect(input, pos, '{');
            parseProject(input, pos, result, projectName);
        } else if (wm.base == "qntx") {
            skipWS(input, pos);
            expect(input, pos, '{');
            parseQntx(input, pos, result);
        } else if (wm.base == "attestation") {
            skipWS(input, pos);
            expect(input, pos, '{');
            parseAttestation(input, pos, result);
        } else if (wm.base == "rites") {
            skipWS(input, pos);
            auto groupName = readWord(input, pos);
            skipWS(input, pos);
            expect(input, pos, '{');
            assert(result.ritesCount < result.rites.length, "Rites group overflow");
            result.rites[result.ritesCount] = parseRites(input, pos, groupName);
            result.ritesCount++;
        } else if (wm.base == "include") {
            // A directive to wind, not a declaration. By the time ground parses
            // sand the directory has already been folded in, so all that is
            // left is to step over the line rather than trip on it.
            skipWS(input, pos);
            cast(void) readValue(input, pos);
        } else {
            assert(0, "Expected 'scope', 'permission', 'control', 'project', 'qntx', 'attestation', 'rites', or 'include'");
        }
    }
    return result;
}

private:

import lexer : skipWS, skipLine, expect, splitMode, readWord, readValue, parseInt;

void parseScope(ref string input, ref size_t pos, ref ParseResult result,
    string parentPath, string parentDecision, string parentEvent = "")
{
    ParsedScope sc;
    if (parentPath.length > 0) { sc.paths[0] = parentPath; sc.pathCount = 1; }
    sc.decision = parentDecision;
    sc.event = parentEvent;
    sc.controlStart = result.ctrlPoolLen;
    sc.permStart = result.permPoolLen;
    bool hasChildren = false;
    bool rangeFinalized = false;

    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }
        if (input[pos] == '}') {
            pos++;
            if (!rangeFinalized) {
                sc.controlEnd = result.ctrlPoolLen;
                sc.permEnd = result.permPoolLen;
            }
            bindInlineRituals(result, sc);
            if (!hasChildren || sc.controlCount > 0 || sc.permissionCount > 0) {
                assert(result.scopeCount < result.scopes.length,
                    "Scope overflow — pbtCounts.totalScopes too small");
                result.scopes[result.scopeCount] = sc;
                result.scopeCount++;
            }
            return;
        }

        auto key = readWord(input, pos);
        auto wm = splitMode(key);
        if (wm.base == "scope") {
            // Finalize this scope's control/perm range before children add to pools
            if (!rangeFinalized) {
                sc.controlEnd = result.ctrlPoolLen;
                sc.permEnd = result.permPoolLen;
                rangeFinalized = true;
            }
            skipWS(input, pos);
            expect(input, pos, '{');
            hasChildren = true;
            parseScope(input, pos, result, sc.pathCount > 0 ? sc.paths[0] : "", sc.decision, sc.event);
        } else if (wm.base == "control") {
            skipWS(input, pos);
            expect(input, pos, '{');
            assert(result.ctrlPoolLen < result.ctrlPool.length);
            result.ctrlPool[result.ctrlPoolLen] = parseControl(input, pos, result);
            result.ctrlPool[result.ctrlPoolLen].mode = wm.mode;
            result.ctrlPoolLen++;
        } else if (wm.base == "permission") {
            skipWS(input, pos);
            expect(input, pos, '{');
            assert(result.permPoolLen < result.permPool.length);
            result.permPool[result.permPoolLen] = parsePermission(input, pos);
            result.permPool[result.permPoolLen].mode = wm.mode;
            result.permPoolLen++;
        } else if (wm.base == "project") {
            skipWS(input, pos);
            string projectName;
            if (isNameStart(input, pos)) {
                projectName = readWord(input, pos);
                skipWS(input, pos);
            }
            expect(input, pos, '{');
            hasChildren = true;
            parseProject(input, pos, result, projectName);
        } else {
            skipWS(input, pos);
            expect(input, pos, ':');
            skipWS(input, pos);
            auto val = readValue(input, pos);
            switch (key) {
                case "path":
                    if (val is null) {
                        // List syntax: path: ["/ctp/", "/qntx-plugins/"]
                        while (pos < input.length) {
                            skipWS(input, pos);
                            if (pos < input.length && input[pos] == ']') { pos++; break; }
                            auto item = readValue(input, pos);
                            assert(sc.pathCount < 8, "Path list overflow");
                            sc.paths[sc.pathCount++] = item;
                            skipWS(input, pos);
                            if (pos < input.length && input[pos] == ',') pos++;
                        }
                    } else if (val.length > 0) {
                        sc.paths[0] = val; sc.pathCount = 1;
                    }
                    break;
                case "decision": sc.decision = val; break;
                case "event":
                    if (val is null) {
                        // Array syntax: event: ["SessionStart", "PostToolUse"]
                        bool first = true;
                        while (pos < input.length) {
                            skipWS(input, pos);
                            if (pos < input.length && input[pos] == ']') { pos++; break; }
                            auto item = readValue(input, pos);
                            if (first) { sc.event = item; first = false; }
                            else {
                                assert(sc.extraEventCount < 3, "Event list overflow");
                                sc.extraEvents[sc.extraEventCount++] = item;
                            }
                            skipWS(input, pos);
                            if (pos < input.length && input[pos] == ',') pos++;
                        }
                    } else {
                        sc.event = val;
                    }
                    break;
                case "edited":
                    if (val is null) {
                        while (pos < input.length) {
                            skipWS(input, pos);
                            if (pos < input.length && input[pos] == ']') { pos++; break; }
                            auto item = readValue(input, pos);
                            assert(sc.editedCount < 8, "Edited list overflow");
                            sc.edited[sc.editedCount++] = item;
                            skipWS(input, pos);
                            if (pos < input.length && input[pos] == ',') pos++;
                        }
                    } else if (val.length > 0) {
                        sc.edited[0] = val; sc.editedCount = 1;
                    }
                    break;
                case "cmd":
                    if (val is null) {
                        while (pos < input.length) {
                            skipWS(input, pos);
                            if (pos < input.length && input[pos] == ']') { pos++; break; }
                            auto item = readValue(input, pos);
                            assert(sc.cmdCount < 8, "Cmd list overflow");
                            sc.cmds[sc.cmdCount++] = item;
                            skipWS(input, pos);
                            if (pos < input.length && input[pos] == ',') pos++;
                        }
                    } else if (val.length > 0) {
                        sc.cmds[0] = val; sc.cmdCount = 1;
                    }
                    break;
                case "mcp_tool": sc.mcpTool = val; break;
                default: assert(0, "Unknown scope field");
            }
        }
    }
    assert(0, "Unterminated scope block");
}

// `project { }` and `project <name> { }` both. A word before the brace names
// the block, and several blocks may share one path.
private bool isNameStart(ref string s, size_t pos) {
    if (pos >= s.length) return false;
    auto c = s[pos];
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_' || c == '-';
}

void parseProject(ref string input, ref size_t pos, ref ParseResult result,
                  string projectName = "") {
    string projectPath;
    string projectOrigin;
    size_t projectMaxGoto;
    size_t fileIdx;
    // Temporary file storage — copied to project on close
    string[1024] files;
    size_t fCount;
    // Env stored in separate lightweight pool (not in ParsedProject — too large)
    string[16] envKeys;
    string[16] envValues;
    ubyte envCount;

    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }
        if (input[pos] == '}') {
            pos++;
            assert(result.projectCount < result.projects.length);
            result.projects[result.projectCount].name = projectName;
            result.projects[result.projectCount].path = projectPath;
            result.projects[result.projectCount].origin = projectOrigin;
            result.projects[result.projectCount].maxGoto = projectMaxGoto;
            result.projects[result.projectCount].files = files;
            result.projects[result.projectCount].fileCount = fCount;
            result.projectCount++;
            // Store env block separately with project path
            if (envCount > 0) {
                assert(result.envCount < result.envs.length, "Env overflow");
                result.envs[result.envCount].path = projectPath;
                result.envs[result.envCount].keys = envKeys;
                result.envs[result.envCount].values = envValues;
                result.envs[result.envCount].count = envCount;
                result.envCount++;
            }
            return;
        }

        auto key = readWord(input, pos);
        auto wm = splitMode(key);
        if (wm.base == "env") {
            skipWS(input, pos);
            expect(input, pos, '{');
            parseEnvBlock(input, pos, envKeys, envValues, envCount);
        } else if (wm.base == "ritual") {
            skipWS(input, pos);
            auto ritualName = readWord(input, pos);
            skipWS(input, pos);
            expect(input, pos, '{');
            assert(result.ritualCount < result.rituals.length, "Ritual overflow");
            result.rituals[result.ritualCount] = parseRitual(input, pos, ritualName, projectPath, projectName);
            result.ritualCount++;
        } else if (wm.base == "scope") {
            skipWS(input, pos);
            expect(input, pos, '{');
            parseScope(input, pos, result, "", "");
        } else if (wm.base == "control") {
            // A project that names a repo hands the control that repo, and no
            // path decides. One that names none wraps in a scope with path "/".
            skipWS(input, pos);
            expect(input, pos, '{');
            assert(result.scopeCount < result.scopes.length);
            ParsedScope sc;
            if (projectOrigin.length == 0) { sc.paths[0] = "/"; sc.pathCount = 1; }
            sc.controlStart = result.ctrlPoolLen;
            assert(result.ctrlPoolLen < result.ctrlPool.length);
            result.ctrlPool[result.ctrlPoolLen] = parseControl(input, pos, result);
            result.ctrlPool[result.ctrlPoolLen].mode = wm.mode;
            result.ctrlPool[result.ctrlPoolLen].origin = projectOrigin;
            sc.event = result.ctrlPool[result.ctrlPoolLen].event;
            result.ctrlPoolLen++;
            sc.controlEnd = result.ctrlPoolLen;
            // A project holding a control is what says where its ritual
            // performs, so a repo-keyed project needs a path to name on disk.
            assert(projectOrigin.length == 0 || projectPath.length > 0,
                "a project naming a repo needs a path saying where that repo is on disk");
            bindInlineRituals(result, sc, projectPath);
            result.scopes[result.scopeCount] = sc;
            result.scopeCount++;
        } else if (wm.base == "permission") {
            // Permission directly in project — wrap in scope with path "/"
            skipWS(input, pos);
            expect(input, pos, '{');
            assert(result.scopeCount < result.scopes.length);
            ParsedScope sc;
            sc.paths[0] = "/"; sc.pathCount = 1;
            sc.permStart = result.permPoolLen;
            assert(result.permPoolLen < result.permPool.length);
            result.permPool[result.permPoolLen] = parsePermission(input, pos);
            result.permPool[result.permPoolLen].mode = wm.mode;
            result.permPoolLen++;
            sc.permEnd = result.permPoolLen;
            result.scopes[result.scopeCount] = sc;
            result.scopeCount++;
        } else {
            skipWS(input, pos);
            expect(input, pos, ':');
            skipWS(input, pos);
            auto val = readValue(input, pos);
            switch (key) {
                case "path": projectPath = val; break;
                case "origin": projectOrigin = val; break;
                case "max_goto": projectMaxGoto = cast(size_t) parseInt(val); break;
                case "files":
                    if (val is null) {
                        // List syntax: files: ["a", "b", ...]
                        while (pos < input.length) {
                            skipWS(input, pos);
                            if (pos < input.length && input[pos] == ']') { pos++; break; }
                            auto item = readValue(input, pos);
                            assert(fCount < files.length, "Too many files in project");
                            files[fCount] = item;
                            fCount++;
                            skipWS(input, pos);
                            if (pos < input.length && input[pos] == ',') pos++;
                        }
                    }
                    break;
                default: assert(0, "Unknown project field");
            }
        }
    }
    assert(0, "Unterminated project block");
}

void parseEnvBlock(ref string input, ref size_t pos,
    ref string[16] keys, ref string[16] values, ref ubyte count)
{
    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }
        if (input[pos] == '}') { pos++; return; }

        auto key = readWord(input, pos);
        skipWS(input, pos);
        expect(input, pos, ':');
        skipWS(input, pos);
        auto val = readValue(input, pos);
        assert(count < 16, "Too many env variables");
        keys[count] = key;
        values[count] = val;
        count++;
    }
    assert(0, "Unterminated env block");
}

void parseHandlerParamsBlock(ref string input, ref size_t pos,
    ref string[8] keys, ref string[8] values, ref ubyte count)
{
    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }
        if (input[pos] == '}') { pos++; return; }

        auto key = readWord(input, pos);
        skipWS(input, pos);
        expect(input, pos, ':');
        skipWS(input, pos);
        auto val = readValue(input, pos);
        assert(count < 8, "handler_params: too many pairs (max 8)");
        keys[count] = key;
        values[count] = val;
        count++;
    }
    assert(0, "Unterminated handler_params block");
}

void parseControlEnvBlock(ref string input, ref size_t pos,
    ref string[8] keys, ref string[8] values, ref ubyte count)
{
    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }
        if (input[pos] == '}') { pos++; return; }

        auto key = readWord(input, pos);
        skipWS(input, pos);
        expect(input, pos, ':');
        skipWS(input, pos);
        auto val = readValue(input, pos);
        assert(count < 8, "control env: too many pairs (max 8)");
        keys[count] = key;
        values[count] = val;
        count++;
    }
    assert(0, "Unterminated control env block");
}

// An inline ritual has no project block, so the scope it fired under is the
// only thing left that says where it performs and what it is called.
private void bindInlineRituals(ref ParseResult result, ref ParsedScope sc,
                               string projectPath = "") {
    foreach (ci; sc.controlStart .. sc.controlEnd) {
        auto idx = result.ctrlPool[ci].inlineRitualIdx;
        if (idx == 0) continue;

        // A project that holds the control says where it performs. Only a
        // control living outside one falls back to the scope it fired under.
        string where = projectPath;
        if (where.length == 0) {
            // A negation says where the control does not fire and nothing about
            // where the ritual performs, so only a real path can be the root.
            size_t root = sc.pathCount;
            size_t roots = 0;
            foreach (i; 0 .. sc.pathCount) {
                if (sc.paths[i].length == 0 || sc.paths[i][0] == '!') continue;
                if (roots == 0) root = i;
                roots++;
            }
            assert(roots == 1,
                "a control carrying `ritual { }` needs exactly one path that is not a negation");
            where = sc.paths[root];
        }

        auto name = result.ctrlPool[ci].name;
        assert(name.length > 0, "a control carrying `ritual { }` needs a name to perform it under");
        result.rituals[idx - 1].name = name;
        result.rituals[idx - 1].projectPath = where;
        result.ctrlPool[ci].ritual = name;
    }
}

public ParsedControl parseControl(ref string input, ref size_t pos, ref ParseResult result) {
    ParsedControl c;
    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }
        if (input[pos] == '}') { pos++; return c; }

        auto key = readWord(input, pos);
        skipWS(input, pos);

        if (key == "strop") {
            expect(input, pos, '{');
            Strop s = parseStropBlock(input, pos);
            assert(result.stropPoolLen < result.stropPool.length, "Strop pool overflow — bump MAX_STROP_POOL");
            result.stropPool[result.stropPoolLen] = s;
            c.stropIdx = result.stropPoolLen + 1;
            result.stropPoolLen++;
            continue;
        }

        // `ritual: "name"` performs one declared elsewhere. `ritual { }` carries
        // its own, and takes the control's name and the scope's path at close.
        if (key == "ritual") {
            if (pos < input.length && input[pos] == '{') {
                expect(input, pos, '{');
                assert(result.ritualCount < result.rituals.length, "Ritual overflow");
                result.rituals[result.ritualCount] = parseRitual(input, pos, "", "");
                c.inlineRitualIdx = result.ritualCount + 1;
                result.ritualCount++;
                continue;
            }
            expect(input, pos, ':');
            skipWS(input, pos);
            c.ritual = readValue(input, pos);
            continue;
        }

        if (key == "handler_params") {
            expect(input, pos, '{');
            parseHandlerParamsBlock(input, pos, c.paramKeys, c.paramValues, c.paramCount);
            continue;
        }

        if (key == "env") {
            expect(input, pos, '{');
            parseControlEnvBlock(input, pos, c.envKeys, c.envValues, c.envCount);
            continue;
        }

        expect(input, pos, ':');
        skipWS(input, pos);
        auto val = readValue(input, pos);

        switch (key) {
            case "name":            c.name = val; break;
            case "event":           c.event = val; break;
            case "cmd":
                if (val is null) {
                    while (pos < input.length) {
                        skipWS(input, pos);
                        if (pos < input.length && input[pos] == ']') { pos++; break; }
                        auto item = readValue(input, pos);
                        assert(c.cmdCount < 8, "Control cmd list overflow");
                        c.cmds[c.cmdCount++] = item;
                        skipWS(input, pos);
                        if (pos < input.length && input[pos] == ',') pos++;
                    }
                } else {
                    c.cmds[0] = val; c.cmdCount = 1;
                }
                break;
            // "tool" removed — use control.w/r/x/m/a syntax instead
            case "arg":             c.arg = val; break;
            case "omit":            c.omit = val; break;
            case "omit_line":       c.omitLine = val; break;
            case "clamp":           c.clamp = val; break;
            case "filepath":        c.filepath = val; break;
            case "userprompt":
                if (val is null) {
                    while (pos < input.length) {
                        skipWS(input, pos);
                        if (pos < input.length && input[pos] == ']') { pos++; break; }
                        auto item = readValue(input, pos);
                        assert(c.userpromptCount < 8);
                        c.userprompts[c.userpromptCount++] = item;
                        skipWS(input, pos);
                        if (pos < input.length && input[pos] == ',') pos++;
                    }
                } else {
                    c.userprompts[0] = val; c.userpromptCount = 1;
                }
                break;
            case "rewrite":
                if (val is null) {
                    while (pos < input.length) {
                        skipWS(input, pos);
                        if (pos < input.length && input[pos] == ']') { pos++; break; }
                        auto item = readValue(input, pos);
                        assert(c.rewriteCount < 32);
                        c.rewrites[c.rewriteCount++] = item;
                        skipWS(input, pos);
                        if (pos < input.length && input[pos] == ',') pos++;
                    }
                } else {
                    c.rewrites[0] = val; c.rewriteCount = 1;
                }
                break;
            case "substitute_for_read":
                if (val is null) {
                    while (pos < input.length) {
                        skipWS(input, pos);
                        if (pos < input.length && input[pos] == ']') { pos++; break; }
                        auto item = readValue(input, pos);
                        assert(c.substituteForReadCount < 8);
                        c.substituteForRead[c.substituteForReadCount++] = item;
                        skipWS(input, pos);
                        if (pos < input.length && input[pos] == ',') pos++;
                    }
                } else {
                    c.substituteForRead[0] = val; c.substituteForReadCount = 1;
                }
                break;
            case "substitute_for_cmd": c.substituteForCmd = val; break;
            case "msg":             c.msg = val; break;
            case "mcp_arg":         c.mcpArg = val; break;
            case "content":
                if (val is null) {
                    while (pos < input.length) {
                        skipWS(input, pos);
                        if (pos < input.length && input[pos] == ']') { pos++; break; }
                        auto item = readValue(input, pos);
                        assert(c.contentCount < 8);
                        c.contents[c.contentCount++] = item;
                        skipWS(input, pos);
                        if (pos < input.length && input[pos] == ',') pos++;
                    }
                } else {
                    c.contents[0] = val; c.contentCount = 1;
                }
                break;
            case "bg":              c.bg = (val == "true"); break;
            case "tmo":             c.tmo = parseInt(val); break;
            case "check_handler":   c.checkHandler = val; break;
            case "exec":            c.exec = val; break;
            case "pushed_paths":    c.pushedPath = val; break;
            case "delay_handler":   c.delayHandler = val; break;
            case "deliver_handler": c.deliverHandler = val; break;
            case "defer_msg":       c.deferMsg = val; break;
            case "defer_sec":       c.deferSec = parseInt(val); break;
            case "interval":        c.interval = parseInt(val); break;
            case "comment_run":     c.commentRun = parseInt(val); break;
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

void parseQntx(ref string input, ref size_t pos, ref ParseResult result) {
    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }
        if (input[pos] == '}') { pos++; return; }

        auto key = readWord(input, pos);
        if (key == "node") {
            skipWS(input, pos);
            expect(input, pos, '{');
            assert(result.qntxNodeCount < result.qntxNodes.length, "QNTX node overflow");
            result.qntxNodes[result.qntxNodeCount] = parseQntxNode(input, pos);
            result.qntxNodeCount++;
        } else {
            assert(0, "Unknown qntx field — expected 'node'");
        }
    }
    assert(0, "Unterminated qntx block");
}

// A ritual body holds only references — never definitions — so a name
// followed by a block is unambiguous: it is that reference, with values.
ParsedRitual parseRitual(ref string input, ref size_t pos, string name, string projectPath,
                         string projectName = "") {
    ParsedRitual r;
    r.name = name;
    r.projectName = projectName;
    r.projectPath = projectPath;
    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }
        if (input[pos] == '}') { pos++; return r; }

        auto refName = readWord(input, pos);

        // A word followed by a colon is a field on the ritual. A bare word is
        // a rites group. Nothing else can appear here.
        {
            auto save = pos;
            skipWS(input, pos);
            if (pos < input.length && input[pos] == ':') {
                pos++;
                skipWS(input, pos);
                auto val = readValue(input, pos);
                if (refName == "system") r.system = val;
                else if (refName == "tree") r.tree = val;
                else r.badKey = refName;
                continue;
            }
            pos = save;
        }

        assert(r.refCount < r.refs.length, "Ritual reference overflow");
        ParsedRiteRef rr;
        rr.name = refName;

        skipWS(input, pos);
        if (pos < input.length && input[pos] == '{') {
            pos++;
            while (pos < input.length) {
                skipWS(input, pos);
                if (pos >= input.length) break;
                if (input[pos] == '#') { skipLine(input, pos); continue; }
                if (input[pos] == '}') { pos++; break; }

                auto k = readWord(input, pos);
                skipWS(input, pos);
                expect(input, pos, ':');
                skipWS(input, pos);
                assert(rr.valueCount < rr.keys.length, "Ritual value overflow");
                rr.keys[rr.valueCount] = k;
                rr.values[rr.valueCount] = readValue(input, pos);
                rr.valueCount++;
            }
        }

        r.refs[r.refCount] = rr;
        r.refCount++;
    }
    assert(0, "Unterminated ritual block");
}

// Inside a rites group every word is a rite name, so nothing here is
// reserved. The verb set is closed instead, one level down.
ParsedRites parseRites(ref string input, ref size_t pos, string groupName) {
    ParsedRites g;
    g.name = groupName;
    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }
        if (input[pos] == '}') { pos++; return g; }

        auto name = readWord(input, pos);
        skipWS(input, pos);

        // `params:` is the one word here that is not a rite. A colon
        // after it is what says so — a rite is always followed by `{`.
        if (pos < input.length && input[pos] == ':') {
            pos++;
            skipWS(input, pos);
            assert(name == "params", "Unknown rites field");
            expect(input, pos, '[');
            while (pos < input.length) {
                skipWS(input, pos);
                if (pos < input.length && input[pos] == ']') { pos++; break; }
                // readWord runs past `]` and `,`, which are terminators here.
                auto start = pos;
                while (pos < input.length && input[pos] != ']' && input[pos] != ','
                        && input[pos] != ' ' && input[pos] != '\t'
                        && input[pos] != '\n' && input[pos] != '\r')
                    pos++;
                assert(pos > start, "Empty param name");
                assert(g.paramCount < g.params.length, "Param overflow");
                g.params[g.paramCount] = input[start .. pos];
                g.paramCount++;
                skipWS(input, pos);
                if (pos < input.length && input[pos] == ',') pos++;
            }
            continue;
        }

        expect(input, pos, '{');
        assert(g.riteCount < g.rites.length, "Rite overflow in group");
        auto rite = parseRite(input, pos, name);
        // Silence about catch means 1 — the honest no. A rite that catches
        // nothing would halt on the very code that means "not yet".
        if (rite.catchCount == 0) {
            rite.catches[0] = 1;
            rite.catchCount = 1;
        }
        g.rites[g.riteCount] = rite;
        g.riteCount++;
    }
    assert(0, "Unterminated rites block");
}

ParsedRite parseRite(ref string input, ref size_t pos, string name) {
    ParsedRite r;
    r.name = name;
    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }
        if (input[pos] == '}') { pos++; return r; }

        auto key = readWord(input, pos);
        skipWS(input, pos);
        expect(input, pos, ':');
        skipWS(input, pos);

        // `catch` takes one code or a list of them; readValue returns null
        // for a list and leaves pos past the opening bracket.
        if (key == "catch") {
            auto val = readValue(input, pos);
            if (val is null) {
                while (pos < input.length) {
                    skipWS(input, pos);
                    if (pos < input.length && input[pos] == ']') { pos++; break; }
                    auto start = pos;
                    while (pos < input.length && input[pos] != ']' && input[pos] != ','
                            && input[pos] != ' ' && input[pos] != '\t'
                            && input[pos] != '\n' && input[pos] != '\r')
                        pos++;
                    assert(pos > start, "Empty catch code");
                    assert(r.catchCount < r.catches.length, "Catch overflow");
                    r.catches[r.catchCount] = parseInt(input[start .. pos]);
                    r.catchCount++;
                    skipWS(input, pos);
                    if (pos < input.length && input[pos] == ',') pos++;
                }
            } else {
                assert(r.catchCount < r.catches.length, "Catch overflow");
                r.catches[r.catchCount] = parseInt(val);
                r.catchCount++;
            }
            continue;
        }

        auto val = readValue(input, pos);
        switch (key) {
            case "eval": r.eval = val; break;
            case "run":  r.run = val; break;
            case "dispatch": r.dispatch = val; break;
            case "inputs":   r.inputs = val; break;
            // Recorded, not asserted: betterC has no GC, so the message that
            // names the rite and the field is built in validateRituals.
            case "cmd":  r.badKey = "cmd"; break;
            case "msg":  r.msg = val; break;
            case "mic":  r.mic = val; break;
            case "goto": r.goto_ = val; break;
            case "pass": r.pass = parseInt(val); break;
            case "grace": r.grace = parseInt(val); break;
            case "wait": r.wait = parseInt(val); break;
            case "to":
                r.to = parseReceiver(val);
                assert(r.to != Receiver.None,
                       "to: names no receiver — parent, human or host");
                break;
            default: r.badKey = key; break;
        }
    }
    assert(0, "Unterminated rite block");
}

ParsedQntxNode parseQntxNode(ref string input, ref size_t pos) {
    ParsedQntxNode n;
    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }
        if (input[pos] == '}') { pos++; return n; }

        auto key = readWord(input, pos);
        skipWS(input, pos);
        expect(input, pos, ':');
        skipWS(input, pos);
        auto val = readValue(input, pos);
        switch (key) {
            case "url": n.url = val; break;
            default: assert(0, "Unknown node field");
        }
    }
    assert(0, "Unterminated node block");
}

void parseAttestation(ref string input, ref size_t pos, ref ParseResult result) {
    assert(result.attestationCount < result.attestations.length, "Attestation overflow");
    ParsedAttestation a;
    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }
        if (input[pos] == '}') {
            pos++;
            result.attestations[result.attestationCount] = a;
            result.attestationCount++;
            return;
        }

        auto key = readWord(input, pos);
        skipWS(input, pos);
        expect(input, pos, ':');
        skipWS(input, pos);

        if (key == "attributes") {
            // Capture raw JSON block between { and matching }
            assert(pos < input.length && input[pos] == '{', "Expected '{' for attributes");
            size_t start = pos;
            int depth = 0;
            while (pos < input.length) {
                if (input[pos] == '{') depth++;
                else if (input[pos] == '}') { depth--; if (depth == 0) { pos++; break; } }
                else if (input[pos] == '"') { pos++; while (pos < input.length && input[pos] != '"') pos++; }
                pos++;
            }
            a.attributes = input[start .. pos];
        } else {
            auto val = readValue(input, pos);
            switch (key) {
                case "subject": a.subject = val; break;
                case "predicate": a.predicate = val; break;
                case "context": a.context = val; break;
                default: assert(0, "Unknown attestation field");
            }
        }
    }
    assert(0, "Unterminated attestation block");
}

