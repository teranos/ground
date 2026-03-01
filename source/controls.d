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

Cmd cmd(string s) { return Cmd(s); }
Arg arg(string s) { return Arg(s); }
Omit omit(string s) { return Omit(s); }

struct Control {
    string name;
    Cmd cmd;
    Arg arg;
    Omit omit;
}

Control control(string name, Cmd c, Arg a) {
    return Control(name, c, a, Omit(""));
}

Control control(string name, Cmd c, Omit o) {
    return Control(name, c, Arg(""), o);
}

static immutable allControls = [
    control("go-test-args", cmd("go test"), arg(`-tags "rustsqlite,qntxwasm" -short`)),
    control("no-skip-hooks", cmd("git"), omit("--no-verify")),
];
