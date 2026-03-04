module controls;

enum HookEvent {
    SessionStart,       // TODO(#5)
    UserPromptSubmit,   // TODO(#6)
    PreToolUse,
    PermissionRequest,  // TODO(#7)
    PostToolUse,        // TODO(#8): attested, no controls yet
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

struct Msg {
    string value;
}

Cmd cmd(string s) { return Cmd(s); }
Arg arg(string s) { return Arg(s); }
Omit omit(string s) { return Omit(s); }
Trigger stop() { return Trigger("Stop"); }
Ax ax(string s) { return Ax(s); }
Msg msg(string s) { return Msg(s); }

struct Control {
    string name;
    Cmd cmd;
    Arg arg;
    Omit omit;
    Trigger trigger;
    Ax ax;
    Msg msg;
}

// Arg amendment control
Control control(string name, Cmd c, Arg a, Msg m) {
    return Control(name, c, a, Omit(""), Trigger(""), Ax(""), m);
}

// Omit amendment control
Control control(string name, Cmd c, Omit o, Msg m) {
    return Control(name, c, Arg(""), o, Trigger(""), Ax(""), m);
}

// Msg-only control — matches but doesn't amend.
Control control(string name, Cmd c, Msg m) {
    return Control(name, c, Arg(""), Omit(""), Trigger(""), Ax(""), m);
}

// Ax control — queries attestation trail on a triggered event.
Control control(string name, Trigger t, Ax a, Msg m) {
    return Control(name, Cmd(""), Arg(""), Omit(""), t, a, m);
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
    control("stage-checkpoint", cmd("git add"),
        msg("A commit typically follows. Start thinking about the commit message — focus on why, not what.")),
    control("pull-checkpoint", cmd("git pull"),
        msg("Resolve conflicts if present before continuing")),
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

static immutable allScopes = [
    Scope("", "allow", universal),
    Scope("", "ask", checkpoints),
    Scope("/QNTX", "allow", qntx),
];

// QNTX node db — attestations are written here on every control match.
// If unavailable, graunde still functions (matching, gating, amending) — just no attestations.
// TODO: Count One — DB_PATH and EXT_PATH should be user-configurable, not hardcoded
enum DB_PATH = "/Users/s.b.vanhouten/SBVH/teranos/tmp3/QNTX/.qntx/tmp32.db\0";
enum EXT_PATH = "/Users/s.b.vanhouten/SBVH/teranos/tmp3/QNTX/target/x86_64-apple-darwin/release/libqntx_ax_ext\0";
