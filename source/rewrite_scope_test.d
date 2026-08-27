module rewrite_scope_test;

// CTFE tests — failure shows as a compile error.

import pretooluse : standingRewrite;

struct FakeControl {
    string[2] rewrites;
    size_t rewriteCount;
    string msg;
}

struct FakeScope {
    string[8] paths;
    ubyte pathCount;
    size_t controlStart, controlEnd;
}

struct FakeParsed {
    FakeScope[1] scopes;
    size_t scopeCount;
    FakeControl[1] ctrlPool;
}

FakeParsed golem() {
    FakeParsed p;
    p.scopes[0].paths[0] = "!/clean";
    p.scopes[0].pathCount = 1;
    p.scopes[0].controlEnd = 1;
    p.scopeCount = 1;
    p.ctrlPool[0].rewrites[0] = "$HOME|/home/golem";
    p.ctrlPool[0].rewrites[1] = "ACME|geology";
    p.ctrlPool[0].rewriteCount = 2;
    p.ctrlPool[0].msg = "taken out";
    return p;
}

static immutable g = golem();

// Where the rule stands, every pair it declares stands with it.
static assert(standingRewrite(g, "/x/teranos/ground", "", 0).pair == "$HOME|/home/golem");
static assert(standingRewrite(g, "/x/teranos/ground", "", 1).pair == "ACME|geology");
static assert(standingRewrite(g, "/x/teranos/ground", "", 0).msg == "taken out");
static assert(standingRewrite(g, "/x/teranos/ground", "", 2).done);

// "the geology rewrite rule shouldnto apply to clean/"
static assert(standingRewrite(g, "/x/clean", "", 0).done);
static assert(standingRewrite(g, "/x/clean/tools", "", 0).done);

// A worktree is the repository it was cut from, so the exclusion follows it.
static assert(standingRewrite(g, "/x/wt", "/x/clean", 0).done);

// A scope that names no path stands everywhere, which is what every rewrite
// control did before it was asked where it was.
FakeParsed everywhere() {
    auto p = golem();
    p.scopes[0].pathCount = 0;
    return p;
}

static immutable e = everywhere();

static assert(standingRewrite(e, "/x/clean", "", 0).pair == "$HOME|/home/golem");
