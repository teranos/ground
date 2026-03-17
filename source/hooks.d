module hooks;

enum HookEvent {
    SessionStart,       // scoped controls via sessionstart(), optional check functions, arch context
    UserPromptSubmit,   // scoped keyword controls via userprompt(), case-insensitive matching
    PreToolUse,         // command amendment, file-path controls, scoped decisions
                        // TODO: updatedInput for non-Bash tools (file_path, pattern, offset, etc.)
    PermissionRequest,  // TODO: auto-allow/deny permission dialogs
    PostToolUse,        // attested, response captured, CI nudge on git push, review nudge
                        // TODO: tool-name matching — fires for all tools (Edit, Write, Read, Glob,
                        //   Grep, Agent, WebFetch, WebSearch, MCP) but only Bash matched by string
                        // TODO: decision:block with reason — corrective feedback after tool runs
                        //   (e.g. after Write to .d file, remind to run tests)
                        // TODO: updatedMCPToolOutput — replace MCP tool output (requires MCP in use)
                        // TODO: exit 2 — stderr fed back to Claude as feedback
                        // TODO: continue:false — halt Claude entirely after a tool completes
                        // TODO: suppressOutput:true — hide stdout from verbose mode
    PostToolUseFailure, // TODO: additionalContext on failure — give Claude context about what went wrong
    Notification,       // TODO: additionalContext on notification — can't block/modify
                        //   matchers: permission_prompt, idle_prompt, auth_success, elicitation_dialog
    SubagentStart,      // TODO: additionalContext injected into subagent's context on spawn
    SubagentStop,       // TODO: decision:block with reason — same pattern as Stop
    Stop,               // trail controls, deferred messages, lazy-verify, CI nudge
    TeammateIdle,       // TODO: quality gates before teammate stops — exit 2 to continue, continue:false to halt
    TaskCompleted,      // TODO: enforce completion criteria — exit 2 blocks with feedback, continue:false halts
    ConfigChange,       // TODO: block unwanted config changes mid-session (exit 2, except policy_settings)
    WorktreeCreate,     // TODO: agent worktree creation — stdout prints path, non-zero exit fails creation
    WorktreeRemove,     // TODO: agent worktree cleanup
    PreCompact,         // branch context via precompact() trigger
                        // TODO: capture session state before compaction so it survives context loss
    Setup,              // TODO: runs on --init/--init-only/--maintenance before session starts
                        //   undocumented upstream (shipped 2.1.10, absent from hooks reference)
    InstructionsLoaded, // fires when CLAUDE.md or .claude/rules/*.md is loaded
    SessionEnd,         // TODO: session wrap-up — final attestation, summarize what happened
}

struct Cmd {
    string value;
}

struct Arg {
    string value;
}

struct Omit {
    string value;
}

struct Trigger {
    string[2] _buf;
    ubyte len;
    const(string)[] values() const return { return _buf[0 .. len]; }
}

struct FilePath {
    string value;
}

struct Msg {
    string value;
}

struct Bg {
    bool value;
}

struct Tmo {
    int value; // milliseconds
}


Cmd cmd(string s) { return Cmd(s); }
Arg arg(string s) { return Arg(s); }
Omit omit(string s) { return Omit(s); }
struct UserPrompt {
    string value;
}

alias CheckFn = bool function(const(char)[] cwd);

struct SessionStartTrigger {
    CheckFn check; // null = always fire
}

Trigger stop() { return Trigger.init; }
Trigger stop(string s) { Trigger t; t._buf[0] = s; t.len = 1; return t; }
Trigger stop(string[2] ss) { Trigger t; t._buf = ss; t.len = 2; return t; }
Trigger precompact() { Trigger t; t._buf[0] = "PreCompact"; t.len = 1; return t; }

UserPrompt userprompt(string s) { return UserPrompt(s); }
SessionStartTrigger sessionstart() { return SessionStartTrigger(null); }
SessionStartTrigger sessionstart(CheckFn fn) { return SessionStartTrigger(fn); }
FilePath filepath(string s) { return FilePath(s); }
Msg msg(string s) { return Msg(s); }
Bg bg() { return Bg(true); }
Tmo tmo(int ms) { return Tmo(ms); }

struct Control {
    string name;
    Cmd cmd;
    Arg arg;
    Omit omit;
    Trigger trigger;
    FilePath filepath;
    UserPrompt userprompt;
    SessionStartTrigger sessionstart;
    Msg msg;
    Bg bg;
    Tmo tmo;
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

// Groups controls by scope and decision.
// Empty path = fires everywhere. Non-empty = cwd must contain the path.
// "!" prefix inverts: "!/QNTX" means cwd must NOT contain "/QNTX".
// Decision: "allow" auto-approves, "ask" shows the permission prompt.
struct Scope {
    string path;
    string decision;
    const(Control)[] controls;
}

bool scopeMatches(const(char)[] scopePath, const(char)[] cwd) {
    if (scopePath.length == 0) return true;
    if (scopePath[0] == '!') {
        import matcher : contains;
        return !contains(cwd, scopePath[1 .. $]);
    }
    import matcher : contains;
    return contains(cwd, scopePath);
}
