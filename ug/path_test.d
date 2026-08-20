module path_test;

// CTFE tests — failure shows as a compile error.

import path : pathInto;

char[256] drawn(const(char)[] cwd, const(char)[] project, const(char)[] home)() {
    char[256] buf = '.';
    pathInto(cwd, project, home, buf[]);
    return buf;
}

size_t len(const(char)[] cwd, const(char)[] project, const(char)[] home)() {
    char[256] buf = '.';
    return pathInto(cwd, project, home, buf[]);
}

enum GROVE = "/Users/x/SBVH/sbvh-nl/grove";
enum HOME = "/Users/x";

// At the project root, the project's own name — which is what both captures
// were taken at, and why a basename passed for this until now.
static assert(len!(GROVE, GROVE, HOME)() == 5);
static assert(drawn!(GROVE, GROVE, HOME)()[0 .. 5] == "grove");

// Inside the project, the project's name and the rest of the way down. A
// basename here says `ug` and loses which repo it belongs to.
static assert(drawn!(GROVE ~ "/ug", GROVE, HOME)()[0 .. 8] == "grove/ug");
static assert(drawn!(GROVE ~ "/a/b", GROVE, HOME)()[0 .. 9] == "grove/a/b");

// Outside the project but under home, a tilde.
static assert(drawn!("/Users/x/tmp", GROVE, HOME)()[0 .. 5] == "~/tmp");
static assert(drawn!(HOME, GROVE, HOME)()[0 .. 1] == "~");

// Outside both, the whole path, because nothing shorter is true.
static assert(drawn!("/etc/nix", GROVE, HOME)()[0 .. 8] == "/etc/nix");

// No project declared falls through to the home rule.
static assert(drawn!("/Users/x/tmp", "", HOME)()[0 .. 5] == "~/tmp");

// No home either leaves the path as it is.
static assert(drawn!("/Users/x/tmp", "", "")()[0 .. 12] == "/Users/x/tmp");

// A worktree beside the project matches the prefix test, so collet draws it
// as though it were inside: `starts_with?` sees no directory boundary. Matched
// rather than corrected — parity first.
static assert(drawn!(GROVE ~ "-willow-1", GROVE, HOME)()[0 .. 16] == "grove/-willow-1.");
