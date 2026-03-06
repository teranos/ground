module controls;

enum HookEvent {
    SessionStart,       // arch context
    UserPromptSubmit,   // keyword reminders
    PreToolUse,         // command amendment, file-path controls, scoped decisions
                        // TODO: updatedInput for non-Bash tools (file_path, pattern, offset, etc.)
    PermissionRequest,  // TODO: auto-allow/deny permission dialogs
    PostToolUse,        // attested, response captured, CI nudge on git push
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

static immutable universal = [
    control("no-skip-hooks", cmd("git"), omit("--no-verify"),
        msg("Git hooks must not be bypassed, ever..")),
    control("short-commit-message-reminder", cmd("git add"),
        msg("A commit typically follows. Start thinking about the commit message — focus on why, not what.")),
    control("sync-main", cmd("git checkout main"),
        msg("Summarize what happened upstream since the last pull.")),
    control("ci-check", cmd("gh run list"),
        msg("Examine the result and report whether CI passed or failed.")),
];

static immutable checkpoints = [
    control("commit-checkpoint", cmd("git commit"),
        msg("Commit requires manual approval")),
    control("push-checkpoint", cmd("git push"),
        msg("If you haven't pulled since the last commit, pull first and resolve conflicts before pushing")),
    control("tag-checkpoint", cmd("git tag"),
        msg("Check the latest tag first and ensure the new version follows semver")),
    control("pr-checkpoint", cmd("gh pr create"),
        msg("PR creation requires manual approval")),
    control("pr-edit-checkpoint", cmd("gh pr edit"),
        msg("Reference any docs edited or created in this PR")),
    control("branch-checkpoint", cmd("git checkout -b"),
        msg("Check main for unpushed commits and push them first. Update documentation to describe intended behavior. Ask critical design questions. Then open a PR.")),
    control("merge-checkpoint", cmd("gh pr merge"),
        msg("After merge, checkout main and pull to sync local.")),
];

static immutable qntx = [
    control("go-test-args", cmd("go test"), arg(`-tags "rustsqlite,qntxwasm" -short`),
        msg("Build tags and -short are required for go test in QNTX")),
];

// TODO: nix flake reminder — editing CI that touches a flake should prompt to check the flake
// TODO: version bump awareness — per-package in monorepos, needs to know which packages were touched

static immutable qntxFiles = [
    control("web-docs-reminder", filepath("/web/"),
        msg("Read web/CLAUDE.md before editing frontend files.")),
    control("web-ts-banned", filepath("/web/ts/"),
        msg("BANNED in frontend: alert(), confirm(), prompt(), toast(). Button component has built-in error handling (throw from onClick). Check component APIs before implementing.")),
];

static immutable graunde = [
    control("install-after-test", cmd("dub test"), bg(),
        msg("If tests pass, run make install to update the live hook binary.")),
];

// TODO: stale binary correction on Stop — detect when installed binary doesn't match compiled version
// TODO: catch hardcoded URLs in error messages that claim to report runtime values
// TODO: catch entity IDs used as subjects — IDs belong in attributes, not subjects
// TODO: ego-death — confident claims about niche/untrained topics trigger grace and humility

static immutable allScopes = [
    Scope("", "allow", universal),
    Scope("", "ask", checkpoints),
    Scope("/graunde", "allow", graunde),
    Scope("/QNTX", "allow", qntx),
];

static immutable fileScopes = [
    Scope("/QNTX", "allow", qntxFiles),
];

// DB paths live in sqlite.d — QNTX node db preferred, standalone fallback.
