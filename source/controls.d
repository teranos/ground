module controls;

struct Cmd {
    string value;
}

struct Arg {
    string value;
}

struct Omit {
    string value;
}

struct Msg {
    string value;
}

Cmd cmd(string s) { return Cmd(s); }
Arg arg(string s) { return Arg(s); }
Omit omit(string s) { return Omit(s); }
Msg msg(string s) { return Msg(s); }

struct Control {
    string name;
    Cmd cmd;
    Arg arg;
    Omit omit;
    Msg msg;
}

Control control(string name, Cmd c, Arg a, Msg m) {
    return Control(name, c, a, Omit(""), m);
}

Control control(string name, Cmd c, Omit o, Msg m) {
    return Control(name, c, Arg(""), o, m);
}

// Msg-only control — matches but doesn't amend.
Control control(string name, Cmd c, Msg m) {
    return Control(name, c, Arg(""), Omit(""), m);
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
        msg("Check main for unpushed commits and push them first. After creating the branch, push it and open a draft PR with a minimal description.")),
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
// TODO: Count One — DB_PATH should be user-configurable, not hardcoded
enum DB_PATH = "/Users/s.b.vanhouten/SBVH/teranos/tmp3/QNTX/.qntx/tmp32.db\0";
