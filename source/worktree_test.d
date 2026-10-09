module worktree_test;

// WorktreeCreate is the one event where exiting 0 with no output is a failure.
// The docs: "Command hook prints path on stdout... Hook failure or missing
// path fails creation" and "Replaces default git behavior".

import worktree : worktreePath, branchOf;

// `git worktree add <path>` is run without -b, so git names the branch after
// the path's last segment.
static assert(branchOf("/home/u/src/proj-probe") == "proj-probe");
static assert(branchOf("/proj-probe") == "proj-probe");
static assert(branchOf("") == "");

// A sibling of the repo: findable, and `git worktree list` names it.
enum p = worktreePath("/home/u/src/proj", "probe");
static assert(p.text() == "/home/u/src/proj-probe");

// A trailing slash on cwd must not double up.
enum slash = worktreePath("/home/u/src/proj/", "probe");
static assert(slash.text() == "/home/u/src/proj-probe");

// A repo at the filesystem root still yields a sibling.
enum root = worktreePath("/proj", "probe");
static assert(root.text() == "/proj-probe");

// An empty string on stdout is the same to Claude Code as printing nothing,
// which fails creation with no reason attached. Refuse instead, and let the
// handler say why.
static assert(worktreePath("/home/u/src/proj", "").len == 0);
static assert(worktreePath("", "probe").len == 0);

// A path that does not fit is not a shorter path, it is a different one: git
// would make a tree somewhere nobody asked for and branchOf would name a
// branch off the cut. Overflow is the same answer as empty — refuse.
// A template, not a function: `~` on enums folds in the frontend, where a
// betterC build has no array append to link against.
private template rep(string s, int n) {
    static if (n <= 0) enum rep = "";
    else enum rep = s ~ rep!(s, n - 1);
}
enum longCwd = "/" ~ rep!("abcdefghij/", 60) ~ "proj";
static assert(longCwd.length == 665);
static assert(worktreePath(longCwd, "probe").len == 0);

// The last name that fits still fits: refusal starts one byte past the buffer.
enum fits = rep!("aaaaaaaaaa", 50) ~ "aaaaa";
static assert(fits.length == 511 - "-probe".length);
static assert(worktreePath(fits, "probe").len == 511);
