module hooks;

enum HookEvent {
    SessionStart,       // arch context
    UserPromptSubmit,   // keyword reminders
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
    PreCompact,         // TODO: capture session state before compaction so it survives context loss
                        //   trigger (manual/auto), custom_instructions — ties into SessionStart re-injection
    Setup,              // TODO: runs on --init/--init-only/--maintenance before session starts
                        //   undocumented upstream (shipped 2.1.10, absent from hooks reference)
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
    string value;
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
Trigger stop() { return Trigger("Stop"); }
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
    Msg msg;
    Bg bg;
    Tmo tmo;
}

// Arg amendment control
Control control(string name, Cmd c, Arg a, Msg m) {
    return Control(name, c, a, Omit(""), Trigger(""), FilePath(""), m, Bg(false), Tmo(0));
}

// Omit amendment control
Control control(string name, Cmd c, Omit o, Msg m) {
    return Control(name, c, Arg(""), o, Trigger(""), FilePath(""), m, Bg(false), Tmo(0));
}

// Msg-only control — matches but doesn't amend.
Control control(string name, Cmd c, Msg m) {
    return Control(name, c, Arg(""), Omit(""), Trigger(""), FilePath(""), m, Bg(false), Tmo(0));
}

// Msg-only control with background execution.
Control control(string name, Cmd c, Bg b, Msg m) {
    return Control(name, c, Arg(""), Omit(""), Trigger(""), FilePath(""), m, b, Tmo(0));
}

// Msg-only control with background execution and timeout.
Control control(string name, Cmd c, Bg b, Tmo t, Msg m) {
    return Control(name, c, Arg(""), Omit(""), Trigger(""), FilePath(""), m, b, t);
}

// Trail control — queries attestation trail on a triggered event.
Control control(string name, Trigger t, Msg m) {
    return Control(name, Cmd(""), Arg(""), Omit(""), t, FilePath(""), m, Bg(false), Tmo(0));
}

// File-path control — matches when file_path contains the pattern.
Control control(string name, FilePath fp, Msg m) {
    return Control(name, Cmd(""), Arg(""), Omit(""), Trigger(""), fp, m, Bg(false), Tmo(0));
}

// Groups controls by scope and decision.
// Empty path = fires everywhere. Non-empty = cwd must contain the path.
// Decision: "allow" auto-approves, "ask" shows the permission prompt.
struct Scope {
    string path;
    string decision;
    const(Control)[] controls;
}
