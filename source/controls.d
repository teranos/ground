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

// Groups controls by project scope.
// Empty path = fires everywhere. Non-empty = cwd must contain the path.
struct Scope {
    string path;
    const(Control)[] controls;
}

static immutable universal = [
    control("no-skip-hooks", cmd("git"), omit("--no-verify"),
        msg("Git hooks must not be bypassed, ever..")),
];

static immutable qntx = [
    control("go-test-args", cmd("go test"), arg(`-tags "rustsqlite,qntxwasm" -short`),
        msg("Build tags and -short are required for go test in QNTX")),
];

static immutable allScopes = [
    Scope("", universal),
    Scope("/QNTX", qntx),
];
