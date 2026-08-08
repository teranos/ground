module worktree_test;

// WorktreeCreate is the one event where exiting 0 with no output is a failure.
// The docs: "Command hook prints path on stdout... Hook failure or missing
// path fails creation" and "Replaces default git behavior".

import worktree : worktreePath;

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
