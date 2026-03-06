module controls;

enum HookEvent {
    SessionStart,       // #5: arch context
    UserPromptSubmit,   // #6: keyword reminders
    PreToolUse,
    PermissionRequest,  // TODO(#7)
    PostToolUse,        // #8: attested, response captured, CI nudge on git push. TODO: #25 tool-name matching, #26 corrective feedback, #27 MCP output
    PostToolUseFailure, // TODO(#9)
    Notification,       // TODO(#10)
    SubagentStart,      // TODO(#11)
    SubagentStop,       // TODO(#12)
    Stop,               // #13: ax controls
    TeammateIdle,       // TODO(#14)
    TaskCompleted,      // TODO(#15)
    ConfigChange,       // TODO(#16)
    WorktreeCreate,     // TODO(#17)
    WorktreeRemove,     // TODO(#18)
    PreCompact,         // TODO(#19): attested, no controls yet
    Setup,              // TODO(#21): undocumented upstream
    SessionEnd,         // TODO(#20)
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

struct Ax {
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
Ax ax(string s) { return Ax(s); }
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
    Ax ax;
    FilePath filepath;
    Msg msg;
    Bg bg;
    Tmo tmo;
}

// Arg amendment control
Control control(string name, Cmd c, Arg a, Msg m) {
    return Control(name, c, a, Omit(""), Trigger(""), Ax(""), FilePath(""), m, Bg(false), Tmo(0));
}

// Omit amendment control
Control control(string name, Cmd c, Omit o, Msg m) {
    return Control(name, c, Arg(""), o, Trigger(""), Ax(""), FilePath(""), m, Bg(false), Tmo(0));
}

// Msg-only control — matches but doesn't amend.
Control control(string name, Cmd c, Msg m) {
    return Control(name, c, Arg(""), Omit(""), Trigger(""), Ax(""), FilePath(""), m, Bg(false), Tmo(0));
}

// Msg-only control with background execution.
Control control(string name, Cmd c, Bg b, Msg m) {
    return Control(name, c, Arg(""), Omit(""), Trigger(""), Ax(""), FilePath(""), m, b, Tmo(0));
}

// Msg-only control with background execution and timeout.
Control control(string name, Cmd c, Bg b, Tmo t, Msg m) {
    return Control(name, c, Arg(""), Omit(""), Trigger(""), Ax(""), FilePath(""), m, b, t);
}

// Ax control — queries attestation trail on a triggered event.
Control control(string name, Trigger t, Ax a, Msg m) {
    return Control(name, Cmd(""), Arg(""), Omit(""), t, a, FilePath(""), m, Bg(false), Tmo(0));
}

// File-path control — matches when file_path contains the pattern.
Control control(string name, FilePath fp, Msg m) {
    return Control(name, Cmd(""), Arg(""), Omit(""), Trigger(""), Ax(""), fp, m, Bg(false), Tmo(0));
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

// QNTX node db — attestations are written here on every control match.
// If unavailable, graunde still functions (matching, gating, amending) — just no attestations.
// TODO: Count One — DB_PATH and EXT_PATH should be user-configurable, not hardcoded
enum DB_PATH = "/Users/s.b.vanhouten/SBVH/teranos/tmp3/QNTX/.qntx/tmp32.db\0";
enum EXT_PATH = "/Users/s.b.vanhouten/SBVH/teranos/tmp3/QNTX/target/x86_64-apple-darwin/release/libqntx_ax_ext\0";
