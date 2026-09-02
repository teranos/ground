module hooks;

// A control is a named rule and a message: what it matches on, and what the
// operator reads at the moment it matches. The event it declares is the set
// that collects it, so a control nobody collects never runs, however well it
// matches.

enum HookEvent {
    SessionStart,       // scoped controls via sessionstart(), optional check functions, arch context
                        // TODO: watchPaths (arms FileChanged), initialUserMessage, sessionTitle, reloadSkills
    MessageDisplay,     // TODO (CC .152): fires as assistant text is displayed; hook can transform or
                        //   hide it. use case: redact secrets from assistant output, warn on risky
                        //   commands about to be shown, format ground errors distinctively
    UserPromptSubmit,   // scoped keyword controls via userprompt(), case-insensitive matching
    PreToolUse,         // command amendment, file-path controls, scoped decisions
                        // TODO: updatedInput for non-Bash tools (file_path, pattern, offset, etc.)
    PermissionRequest,  // TODO: auto-allow/deny permission dialogs
    PermissionDenied,   // TODO: fires when auto mode classifier denies a tool call; retry:true lets the model retry
    PostToolUse,        // attested, response captured, CI nudge on git push, review nudge
                        //   cmd and filepath matching for advisory context
                        // TODO: tool-name filtering — restrict controls to specific tools (e.g. Edit only, not Read)
                        // TODO: decision:block with reason — corrective feedback after tool runs
                        // TODO: exit 2 — stderr fed back to Claude as feedback
                        // TODO: suppressOutput:true hides stdout; updatedToolOutput rewrites the result
    PostToolUseFailure, // trigger-matched hints on failure (e.g. wrong directory)
    Notification,       // a halted performance, said once per session. No decision control:
                        //   exit 2 shows stderr to the user and is the only reply it accepts
                        //   fires on permission_prompt, idle_prompt, agent_needs_input, agent_completed
    SubagentStart,      // TODO: agent-type scoped controls — inject context or adjust decisions per type
                        //   payload: agent_type, agent_id, session_id, cwd
                        //   time-scoped modes could auto-approve agent spawning during event windows
    SubagentStop,       // attested only — no handler
                        //   payload: agent_id, agent_type, last_assistant_message
    Stop,               // deferred messages, lazy-verify, CI nudge
                        //   stop_hook_active:false = first stop, controls run.
                        //   stop_hook_active:true = re-stop after prior block, skip to avoid loop.
    StopFailure,        // recorded raw by stopfailure.d. Cannot block, so nothing here retries the turn
    TeammateIdle,       // TODO: quality gates before teammate stops — exit 2 to continue, continue:false to halt
    TaskCreated,        // TODO: fires when a task is being created
                        //   payload: task_id, task_subject, task_description, teammate_name, team_name
                        //   CAN block: exit 2 = feedback to model, continue:false = halt teammate
                        //   use case: enforce naming, inject context, gate delegation
    TaskCompleted,      // TODO: enforce completion criteria — exit 2 blocks with feedback, continue:false halts
    ConfigChange,       // TODO: block unwanted config changes mid-session (exit 2, except policy_settings)
    CwdChanged,         // TODO: fires when cwd changes — payload: old_cwd, new_cwd
                        //   cannot block, side-effects only. CLAUDE_ENV_FILE available.
                        //   replaces PostToolUse cd hack for directory-enter controls
                        //   added v2.1.83, requires Claude Code upgrade from current v2.0.37
    FileChanged,        // TODO: fires when a watched file changes on disk
                        //   payload: file_path, change_type (created/modified/deleted)
                        //   matcher: literal filenames with | separator (e.g. ".envrc|.env"), not regex
                        //   cannot block, side-effects only. CLAUDE_ENV_FILE available.
                        //   use case: auto make install when .pbt changes externally, am.toml reload
    WorktreeCreate,     // TODO: agent worktree creation — stdout prints path, non-zero exit fails creation
    WorktreeRemove,     // TODO: agent worktree cleanup
    PreCompact,         // branch context via precompact() trigger
                        // TODO: capture session state before compaction so it survives context loss
    PostCompact,        // TODO: fires after compaction completes
                        //   payload: trigger ("manual" or "auto"), cannot block
                        //   matcher: "manual" or "auto"
                        //   use case: verify critical context survived, diff pre vs post
    Setup,              // TODO: runs on --init/--init-only/--maintenance before session starts
                        //   undocumented upstream (shipped 2.1.10, absent from hooks reference)
    InstructionsLoaded, // fires when CLAUDE.md or .claude/rules/*.md is loaded
    Elicitation,        // TODO: fires when MCP server requests user input during a tool call
    ElicitationResult,  // TODO: fires after user responds to MCP elicitation
    SessionEnd,         // TODO: session wrap-up — final attestation, summarize what happened
}

struct Cmd {
    string[8] _buf;
    ubyte len;
    string value() const { return len > 0 ? _buf[0] : ""; }
    const(string)[] values() const return { return _buf[0 .. len]; }
}

struct Arg {
    string value;
}

struct Omit {
    string value;
}

struct OmitLine {
    string value;
}

// Floor-clamp a numeric flag value. Spec: "<prefix>N>=<min>" —
// e.g. "tail -N>=40". When matched, raises a too-small N to <min>.
// See matcher.applyClamp for semantics.
struct Clamp {
    string value;
}

struct Trigger {
    string[16] _buf;
    ubyte len;
    const(string)[] values() const return { return _buf[0 .. len]; }
}

struct FilePath {
    string value;
}

struct PushedPath {
    string value;
}

struct Mode {
    string value;
}

struct Msg {
    string value;
}

struct McpArg {
    string value;
}

struct Content {
    string[8] _buf;
    ubyte len;
    const(string)[] values() const return { return _buf[0 .. len]; }
    string value() const { return len > 0 ? _buf[0] : ""; }
}

// The utilities that mean "I was trying to read a file". Ground reads it and
// hands it over instead of running the command.
struct SubstituteForRead {
    string[8] _buf;
    ubyte len;
    const(string)[] values() const return { return _buf[0 .. len]; }
}

// The command the author meant, run in place of the one that was typed. The
// matched segment is replaced whole, so nothing of the original carries over.
struct SubstituteForCmd {
    string value;
}

// Strings that must not reach a file. Each entry is what to find and what to
// put there instead, separated by a pipe, as matcher lists are.
struct Rewrites {
    string[32] _buf;
    ubyte len;
    const(string)[] values() const return { return _buf[0 .. len]; }
}

// The find side and the put side of one entry.
const(char)[] rewriteFrom(const(char)[] pair) {
    foreach (i, c; pair) if (c == '|') return pair[0 .. i];
    return pair;
}

const(char)[] rewriteTo(const(char)[] pair) {
    foreach (i, c; pair) if (c == '|') return pair[i + 1 .. $];
    return "";
}

struct Bg {
    bool value;
}

struct Tmo {
    int value; // milliseconds
}

// Deferred PostToolUse controls — write to DB after a tool runs, deliver on Stop.
//
//   defer(300, "Reminder message")                   — fixed delay, static message
//   defer(&myDelay, &myDeliver, "Prefix: ")          — dynamic delay + live query on delivery
//
// See controls.d for ci-check-defer (dynamic) and review-nudge (fixed) examples.
alias DelayFn = int function(const(char)[] cwd);
alias DeliverFn = const(char)[] function(const(char)[] cwd);

struct Defer {
    int delaySec;         // fixed delay (used when delayFn is null)
    DelayFn delayFn;      // dynamic delay computation (null = use delaySec)
    DeliverFn deliverFn;  // runs at delivery time, output becomes the message (null = deliver msg as-is)
    string msg;           // deferred message (full message if no deliverFn, ignored if deliverFn set)
}


Cmd cmd(string s) { Cmd c; c._buf[0] = s; c.len = 1; return c; }
Arg arg(string s) { return Arg(s); }
Omit omit(string s) { return Omit(s); }
Clamp clamp(string s) { return Clamp(s); }
struct UserPrompt {
    string[8] _buf;
    ubyte len;
    const(string)[] values() const return { return _buf[0 .. len]; }
    string value() const { return len > 0 ? _buf[0] : ""; }
}

// What a check decided, and what it actually saw.
//
// A bare bool could only report THAT a control fired, never what the code
// observed — so a handler that could not evaluate its condition had to
// collapse "I could not determine" into "the condition is true", and the
// user then read the pbt-authored msg as the reason. That msg asserts a
// cause the handler never measured.
//
// `observed` is the escape hatch the ERROR AXIOM's truthfulness clause
// requires: non-null means the authored msg would misstate this firing, and
// this text — what the code actually measured — is delivered instead.
// Handlers that genuinely evaluated their condition leave it null and the
// authored msg stands.
struct CheckResult {
    bool fired;         // the control should act
    string observed;    // null = authored msg is accurate; else use this text
}

// Convenience for the common cases, so handlers read as verdicts.
CheckResult fires()     { return CheckResult(true,  null); }
CheckResult passes()    { return CheckResult(false, null); }

alias CheckFn = CheckResult function(const(char)[] cwd, const(char)[] input);

struct SessionStartTrigger {
    CheckFn check;     // null = always fire
    DeliverFn deliver; // null = use static msg
}

Trigger stop() { return Trigger.init; }
Trigger stop(string s) { Trigger t; t._buf[0] = s; t.len = 1; return t; }
Trigger precompact() { Trigger t; t._buf[0] = "PreCompact"; t.len = 1; return t; }
Trigger posttool(string s) { Trigger t; t._buf[0] = s; t.len = 1; return t; }

UserPrompt userprompt(string s) { UserPrompt u; u._buf[0] = s; u.len = 1; return u; }
SessionStartTrigger sessionstart() { return SessionStartTrigger(null); }
SessionStartTrigger sessionstart(CheckFn fn) { return SessionStartTrigger(fn); }
FilePath filepath(string s) { return FilePath(s); }
Msg msg(string s) { return Msg(s); }
Bg bg() { return Bg(true); }
Tmo tmo(int ms) { return Tmo(ms); }
Defer defer(int sec, string msg) {
    return Defer(sec, null, null, msg);
}
Defer defer(DelayFn fn, DeliverFn deliver, string msg) {
    return Defer(0, fn, deliver, msg);
}

struct Control {
    string name;
    Mode mode;
    Cmd cmd;
    Arg arg;
    Omit omit;
    OmitLine omitLine;
    Clamp clamp;
    Trigger trigger;
    FilePath filepath;
    PushedPath pushedPath;
    UserPrompt userprompt;
    SessionStartTrigger sessionstart;
    Msg msg;
    McpArg mcpArg;
    Content content;
    SubstituteForRead substituteForRead;
    SubstituteForCmd substituteForCmd;
    Rewrites rewrites;
    Bg bg;
    Tmo tmo;
    Defer defer;
    string[8] paramKeys;
    string[8] paramValues;
    ubyte paramCount;
    string[8] envKeys;
    string[8] envValues;
    ubyte envCount;
    string exec;
    // The repo this control belongs to, from the project holding it. Set, the
    // control fires for every checkout of that repo and nowhere else.
    string origin;
    string ritual; // the ritual this control performs, by name. Empty = none.
    size_t stropIdx; // 0 = no strop; else 1-based index into controls.globalStropPool.
    int interval; // minimum seconds between fires (0 = no limit)
    int commentRun; // fire at this many consecutive comment lines (0 = off)
}

Control control(string name, Cmd c, Arg a, Msg m) {
    Control ctrl; ctrl.name = name; ctrl.cmd = c; ctrl.arg = a; ctrl.msg = m; return ctrl;
}

Control control(string name, Cmd c, Omit o, Msg m) {
    Control ctrl; ctrl.name = name; ctrl.cmd = c; ctrl.omit = o; ctrl.msg = m; return ctrl;
}

// Clamp controls: silent floor-raise of a numeric flag. No msg —
// the rewrite is corrective, not advisory; the longer output speaks
// for itself.
Control control(string name, Cmd c, Clamp cl) {
    Control ctrl; ctrl.name = name; ctrl.cmd = c; ctrl.clamp = cl; return ctrl;
}

Control control(string name, Cmd c, Msg m) {
    Control ctrl; ctrl.name = name; ctrl.cmd = c; ctrl.msg = m; return ctrl;
}

Control control(string name, Cmd c, Bg b, Msg m) {
    Control ctrl; ctrl.name = name; ctrl.cmd = c; ctrl.bg = b; ctrl.msg = m; return ctrl;
}

Control control(string name, Cmd c, Bg b, Tmo t, Msg m) {
    Control ctrl; ctrl.name = name; ctrl.cmd = c; ctrl.bg = b; ctrl.tmo = t; ctrl.msg = m; return ctrl;
}

Control control(string name, Trigger t, Msg m) {
    Control ctrl; ctrl.name = name; ctrl.trigger = t; ctrl.msg = m; return ctrl;
}

// PreCompact control — msg prefix + cmd to run.
Control control(string name, Trigger t, Msg m, Cmd c) {
    Control ctrl; ctrl.name = name; ctrl.trigger = t; ctrl.msg = m; ctrl.cmd = c; return ctrl;
}

Control control(string name, FilePath fp, Msg m) {
    Control ctrl; ctrl.name = name; ctrl.filepath = fp; ctrl.msg = m; return ctrl;
}

Control control(string name, UserPrompt up, Msg m) {
    Control ctrl; ctrl.name = name; ctrl.userprompt = up; ctrl.msg = m; return ctrl;
}

Control control(string name, SessionStartTrigger ss, Msg m) {
    Control ctrl; ctrl.name = name; ctrl.sessionstart = ss; ctrl.msg = m; return ctrl;
}

// Deferred PostToolUse — cmd match + defer (delay, command, message all in Defer)
Control control(string name, Cmd c, Defer d) {
    Control ctrl; ctrl.name = name; ctrl.cmd = c; ctrl.defer = d; return ctrl;
}

// Deferred PostToolUse — cmd + secondary pattern + defer
Control control(string name, Cmd c, Trigger t, Defer d) {
    Control ctrl; ctrl.name = name; ctrl.cmd = c; ctrl.trigger = t; ctrl.defer = d; return ctrl;
}

// Groups controls by scope and decision. A control can live in one — written
// at top level `parsePbt` wraps it in a scope with path "/".
// Empty path = fires everywhere. Non-empty = cwd must contain the path.
// "!" prefix inverts: "!/QNTX" means cwd must NOT contain "/QNTX".
// Decision: "allow" auto-approves, "ask" shows the permission prompt.
struct Scope {
    string[8] paths;
    ubyte pathCount;
    string[8] edited;
    ubyte editedCount;
    string[8] cmds;
    ubyte cmdCount;
    string decision;
    string mcpTool;
    const(Control)[] controls;
}

// A path names directories, so it ends where one ends. A raw substring made
// QNTX-App contain QNTX, which is why every sibling needed its own negation.
bool pathMatch(const(char)[] path, const(char)[] pattern) {
    if (pattern.length == 0 || pattern.length > path.length) return false;

    // A pattern closing with a separator already ends on a boundary.
    bool closed = pattern[$ - 1] == '/';

    foreach (i; 0 .. path.length - pattern.length + 1) {
        if (path[i .. i + pattern.length] != pattern) continue;
        if (closed) return true;
        auto after = i + pattern.length;
        if (after == path.length || path[after] == '/') return true;
    }
    return false;
}

unittest {
    // What the substring form already got right stays right.
    assert(pathMatch("/home/user/QNTX/src", "/QNTX"));
    assert(pathMatch("/home/user/QNTX", "/QNTX"));
    assert(pathMatch("/home/user/QNTX/ctp/werf", "/ctp/"));
    assert(!pathMatch("/home/user/other", "/QNTX"));

    // The sibling that needed a negation of its own does not match now.
    assert(!pathMatch("/Users/x/teranos/QNTX-App", "/teranos/QNTX"));
    assert(!pathMatch("/Users/x/teranos/QNTX-App/web", "/teranos/QNTX"));
    assert(pathMatch("/Users/x/teranos/QNTX", "/teranos/QNTX"));
    assert(pathMatch("/Users/x/teranos/QNTX/server", "/teranos/QNTX"));

    // A worktree beside the tree is its own directory, so it does not match
    // the project by name. The repository it belongs to is what does.
    assert(!pathMatch("/Users/x/teranos/ground-chapter-1", "/teranos/ground"));
}

bool scopeMatches(S)(const ref S sc, const(char)[] cwd) {
    import git : repoRoot;
    return scopeMatchesIn(sc, cwd, repoRoot(cwd));
}

// Where the command runs, and the repository that place belongs to. A worktree
// is the project it was cut from, wherever on disk somebody put it.
bool scopeMatchesIn(S)(const ref S sc, const(char)[] cwd, const(char)[] root) {
    if (sc.pathCount == 0) return true;

    bool here(const(char)[] pattern) {
        if (pathMatch(cwd, pattern)) return true;
        return root.length > 0 && pathMatch(root, pattern);
    }

    // Two-pass: positive paths OR, negative paths AND-filter.
    bool hasPositive = false;
    bool positiveMatch = false;

    foreach (i; 0 .. sc.pathCount) {
        auto p = sc.paths[i];
        if (p.length == 0) continue;
        if (p[0] == '!') {
            // Negative = filter. Standing in the excluded place rejects at once.
            if (here(p[1 .. $])) return false;
        } else if (p[0] == '=') {
            hasPositive = true;
            auto exact = p[1 .. $];
            if (cwd.length >= exact.length) {
                bool match = true;
                foreach (j; 0 .. exact.length) {
                    char a = cwd[cwd.length - exact.length + j];
                    char b = exact[j];
                    if (a >= 'A' && a <= 'Z') a += 32;
                    if (b >= 'A' && b <= 'Z') b += 32;
                    if (a != b) { match = false; break; }
                }
                if (match) positiveMatch = true;
            }
        } else {
            hasPositive = true;
            if (here(p)) positiveMatch = true;
        }
    }

    // If only negatives and none rejected, match everywhere.
    if (!hasPositive) return true;
    return positiveMatch;
}

unittest {
    struct S {
        string[8] paths;
        ubyte pathCount;
    }

    // Positive + negative = AND: must match positive AND not match negative
    S mixed;
    mixed.paths[0] = "/QNTX";
    mixed.paths[1] = "!/ctp/";
    mixed.pathCount = 2;

    // In QNTX root — should match (contains /QNTX, no /ctp/)
    assert(scopeMatches(mixed, "/home/user/QNTX/src") == true);
    // In QNTX/ctp/ — should NOT match (contains /QNTX but also /ctp/)
    assert(scopeMatches(mixed, "/home/user/QNTX/ctp/werf") == false);
    // Outside QNTX entirely — should NOT match
    assert(scopeMatches(mixed, "/home/user/other") == false);

    // Pure positive — OR behavior preserved
    S pos;
    pos.paths[0] = "/QNTX";
    pos.pathCount = 1;
    assert(scopeMatches(pos, "/home/user/QNTX/ctp/werf") == true);
    assert(scopeMatches(pos, "/home/user/other") == false);

    // Pure negative — fires everywhere except match
    S neg;
    neg.paths[0] = "!/ctp/";
    neg.pathCount = 1;
    assert(scopeMatches(neg, "/home/user/QNTX/src") == true);
    assert(scopeMatches(neg, "/home/user/QNTX/ctp/werf") == false);

    // Multiple negatives — all must pass
    S multiNeg;
    multiNeg.paths[0] = "!/ctp/";
    multiNeg.paths[1] = "!/vendor/";
    multiNeg.pathCount = 2;
    assert(scopeMatches(multiNeg, "/home/user/QNTX/src") == true);
    assert(scopeMatches(multiNeg, "/home/user/QNTX/ctp/x") == false);
    assert(scopeMatches(multiNeg, "/home/user/QNTX/vendor/x") == false);
}
