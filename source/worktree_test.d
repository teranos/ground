module worktree_test;

// WorktreeCreate is the one event where exiting 0 with no output is a failure.
// The docs: "Command hook prints path on stdout... Hook failure or missing
// path fails creation" and "Replaces default git behavior".

import worktree : worktreePath, branchOf, addQuoted, emptyTreeCmd;

// A performance with nothing to inspect gets nothing to inspect. The branch is
// an orphan onto the empty tree, so the checkout holds `.git` and no files.
// Proven against git 2.28, which has no `worktree add --orphan`.
enum empty = emptyTreeCmd("/home/u/src/proj", "/home/u/src/proj-p1", "proj-p1");
static assert(empty.text() ==
    "git -C '/home/u/src/proj' branch 'proj-p1' "
    ~ "$(git -C '/home/u/src/proj' commit-tree "
    ~ "$(git -C '/home/u/src/proj' hash-object -t tree /dev/null) -m 'ground stage') 2>&1"
    ~ " && git -C '/home/u/src/proj' worktree add '/home/u/src/proj-p1' 'proj-p1' 2>&1");

// Every value is quoted, because a path ground built is still a path.
enum quotedName = emptyTreeCmd("/r", "/r-it's", "it's");
static assert(quotedName.ok);

// Nothing to build a command from is a refusal, not an empty command.
static assert(!emptyTreeCmd("", "/r-p1", "p1").ok);
static assert(!emptyTreeCmd("/r", "", "p1").ok);
static assert(!emptyTreeCmd("/r", "/r-p1", "").ok);

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

// git runs through popen, which is /bin/sh, so every value ground interpolates
// is sh source until it is quoted. `'\''` closes, emits a literal quote, and
// reopens — total over any byte string, so no value needs refusing for content.
private auto quoted(const(char)[] s) {
    struct R {
        char[64] buf = 0;
        size_t n;
        bool ok;
        const(char)[] text() const return { return buf[0 .. n]; }
    }
    R r;
    r.ok = addQuoted(r.buf[], r.n, s);
    return r;
}

enum plain = quoted("/home/u/src/proj-probe");
static assert(plain.ok);
static assert(plain.text() == "'/home/u/src/proj-probe'");

enum tick = quoted("it's");
static assert(tick.ok);
static assert(tick.text() == `'it'\''s'`);

// The injection this closes: a name that ends the quote and starts a command.
enum evil = quoted("x'; rm -rf /; echo '");
static assert(evil.ok);
static assert(evil.text() == `'x'\''; rm -rf /; echo '\'''`);

// A newline stays inside the quotes, so sh reads it as a byte, not a separator.
enum nl = quoted("a\nb");
static assert(nl.ok);
static assert(nl.text() == "'a\nb'");

// A value too big to quote is a command ground must not run: truncating here
// severs the closing quote and hands sh something else entirely.
enum tooBig = quoted(rep!("aaaaaaaaaa", 20));
static assert(!tooBig.ok);
