module hooks;

enum HookEvent {
    SessionStart,       // scoped controls via sessionstart(), optional check functions, arch context
    UserPromptSubmit,   // scoped keyword controls via userprompt(), case-insensitive matching
    PreToolUse,         // command amendment, file-path controls, scoped decisions
                        // TODO: updatedInput for non-Bash tools (file_path, pattern, offset, etc.)
    PermissionRequest,  // TODO: auto-allow/deny permission dialogs
    PermissionDenied,   // TODO: fires when auto mode classifier denies a tool call
    PostToolUse,        // attested, response captured, CI nudge on git push, review nudge
                        //   cmd and filepath matching for advisory context
                        // TODO: tool-name filtering — restrict controls to specific tools (e.g. Edit only, not Read)
                        // TODO: decision:block with reason — corrective feedback after tool runs
                        // TODO: exit 2 — stderr fed back to Claude as feedback
                        // TODO: suppressOutput:true — hide stdout from verbose mode
    PostToolUseFailure, // trigger-matched hints on failure (e.g. wrong directory)
    Notification,       // TODO: cross-session awareness — session A completes a 4+ min task, idle_prompt
                        //   fires; combine with session B's next Notification to surface the result
    SubagentStart,      // TODO: agent-type scoped controls — inject context or adjust decisions per type
                        //   payload: agent_type, agent_id, session_id, cwd
                        //   time-scoped modes could auto-approve agent spawning during event windows
    SubagentStop,       // attested (full payload incl. last_assistant_message, agent_transcript_path)
                        //   stop_hook_active:false — Claude Code may ignore responses
                        //   payload: agent_id, agent_type, agent_transcript_path, last_assistant_message
                        //   TODO: read agent_transcript_path for quality checks on subagent output
                        //   TODO: verify what response fields are honored
    Stop,               // trail controls, deferred messages, lazy-verify, CI nudge
                        //   stop_hook_active:false = first stop, controls run.
                        //   stop_hook_active:true = re-stop after prior block, skip to avoid loop.
    StopFailure,        // TODO: fires when turn ends due to API error — retry logic, error logging
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

struct Trigger {
    string[16] _buf;
    ubyte len;
    const(string)[] values() const return { return _buf[0 .. len]; }
}

struct FilePath {
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
    string value;
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
struct UserPrompt {
    string[8] _buf;
    ubyte len;
    const(string)[] values() const return { return _buf[0 .. len]; }
    string value() const { return len > 0 ? _buf[0] : ""; }
}

alias CheckFn = bool function(const(char)[] cwd, const(char)[] input);

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
    Trigger trigger;
    FilePath filepath;
    UserPrompt userprompt;
    SessionStartTrigger sessionstart;
    Msg msg;
    McpArg mcpArg;
    Content content;
    Bg bg;
    Tmo tmo;
    Defer defer;
    int interval; // minimum seconds between fires (0 = no limit)
}

Control control(string name, Cmd c, Arg a, Msg m) {
    Control ctrl; ctrl.name = name; ctrl.cmd = c; ctrl.arg = a; ctrl.msg = m; return ctrl;
}

Control control(string name, Cmd c, Omit o, Msg m) {
    Control ctrl; ctrl.name = name; ctrl.cmd = c; ctrl.omit = o; ctrl.msg = m; return ctrl;
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

// Groups controls by scope and decision.
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

bool scopeMatches(S)(const ref S sc, const(char)[] cwd) {
    if (sc.pathCount == 0) return true;
    import matcher : contains;
    foreach (i; 0 .. sc.pathCount) {
        auto p = sc.paths[i];
        if (p.length == 0) continue;
        if (p[0] == '!') {
            if (!contains(cwd, p[1 .. $])) return true;
        } else if (p[0] == '=') {
            // Exact match — cwd must end with this path
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
                if (match) return true;
            }
        } else {
            if (contains(cwd, p)) return true;
        }
    }
    return false;
}
