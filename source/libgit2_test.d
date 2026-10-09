module libgit2_test;

// "i will be able to trace back to the exact conversation, even years back"
// What the walk answers for a file is what `git log -1 --format=%ct -- <file>`
// answers for it, read off a real repository, merges and all.

import core.stdc.stdlib : system, getenv;
import core.stdc.stdio : FILE;
extern (C) char* mkdtemp(char* template_);
extern (C) FILE* popen(const(char)* command, const(char)* mode);
extern (C) int pclose(FILE* stream);

// No GC under betterC, so every path and command is set into a buffer.
struct Buf {
    char[4096] b = 0;
    size_t n;
    void put(const(char)[] s) { foreach (c; s) if (n < b.length - 1) b[n++] = c; }
    const(char)[] text() const return { return b[0 .. n]; }
    const(char)* z() return { b[n] = 0; return b.ptr; }
}

void sh(A...)(A parts) {
    Buf c;
    c.put("( ");
    foreach (p; parts) c.put(p);
    c.put(" )");
    auto bare = c.n;
    c.put(" >/dev/null 2>&1");
    if (system(c.z()) == 0) return;
    c.n = bare;
    cast(void) system(c.z());
    assert(false, c.text());
}

Buf gitOut(A...)(const(char)[] tree, A args) {
    import core.stdc.stdio : fread;
    Buf c;
    c.put("git -C '");
    c.put(tree);
    c.put("' ");
    foreach (a; args) c.put(a);
    auto f = popen(c.z(), "r");
    Buf o;
    o.n = fread(o.b.ptr, 1, o.b.length - 1, f);
    pclose(f);
    while (o.n > 0 && o.b[o.n - 1] == '\n') o.n--;
    return o;
}

private long number(const(char)[] s) {
    long v;
    foreach (c; s) { if (c < '0' || c > '9') break; v = v * 10 + (c - '0'); }
    return v;
}

// A commit at a second of its own, so every answer names one commit.
private void commitAt(const(char)[] repo, const(char)[] when, const(char)[] message) {
    sh("GIT_COMMITTER_DATE='", when, "' GIT_AUTHOR_DATE='", when, "' git -C '", repo,
       "' commit -q -m '", message, "'");
}

Buf scratch(const(char)[] name) {
    Buf root;
    auto base = getenv("TMPDIR");
    size_t n;
    if (base !is null) while (base[n]) n++;
    const(char)[] dir = base is null ? "/tmp" : base[0 .. n];
    if (dir.length > 0 && dir[$ - 1] == '/') dir = dir[0 .. $ - 1];
    root.put(dir);
    root.put("/ground-");
    root.put(name);
    root.put("-XXXXXX");
    assert(mkdtemp(cast(char*) root.z()) !is null);
    return root;
}

// History with a merge from a side branch, a merge that changes a file itself,
// and a deletion; then staged on top of it a change, a new file, a rename, a
// removal and a file that became a symlink.
Buf fixture() {
    auto root = scratch("trail");
    auto r = root.text();

    sh("git init -q -b main '", r, "'");
    sh("git -C '", r, "' config user.name ground");
    sh("git -C '", r, "' config user.email ground@example.invalid");

    sh("mkdir -p '", r, "/sub'");
    sh("printf 'one\\n' > '", r, "/a.d'");
    sh("printf 'one\\n' > '", r, "/gone.d'");
    sh("printf 'one\\none\\none\\none\\n' > '", r, "/sub/deep.d'");
    sh("printf 'one\\n' > '", r, "/evil.d'");
    sh("printf 'one\\n' > '", r, "/plain.d'");
    sh("git -C '", r, "' add -A");
    commitAt(r, "2026-01-01T00:00:01Z", "c1");

    sh("printf 'two\\n' >> '", r, "/a.d'");
    sh("git -C '", r, "' rm -q gone.d");
    sh("git -C '", r, "' add -A");
    commitAt(r, "2026-01-01T00:00:02Z", "c2");

    sh("git -C '", r, "' checkout -q -b side");
    sh("printf 'side\\n' > '", r, "/side.d'");
    sh("git -C '", r, "' add side.d");
    commitAt(r, "2026-01-01T00:00:03Z", "c3");
    sh("git -C '", r, "' checkout -q main");
    sh("printf 'main\\n' >> '", r, "/sub/deep.d'");
    sh("git -C '", r, "' add -A");
    commitAt(r, "2026-01-01T00:00:04Z", "c4");

    sh("git -C '", r, "' merge -q --no-ff --no-commit side");
    sh("printf 'evil\\n' >> '", r, "/evil.d'");
    sh("git -C '", r, "' add evil.d");
    commitAt(r, "2026-01-01T00:00:05Z", "merge");

    sh("printf 'three\\n' >> '", r, "/a.d'");
    sh("printf 'new\\n' > '", r, "/new.d'");
    sh("git -C '", r, "' add a.d new.d");
    sh("git -C '", r, "' mv sub/deep.d sub/moved.d");
    sh("git -C '", r, "' rm -q -- evil.d");
    sh("rm '", r, "/plain.d'");
    sh("ln -s a.d '", r, "/plain.d'");
    sh("git -C '", r, "' add plain.d");
    return root;
}

// Every file the walk is asked about answers what git log answers.
unittest {
    import libgit2 : Repo;
    auto root = fixture();
    auto r = root.text();

    Repo g;
    assert(g.open(r), g.why());
    scope (exit) g.close();

    static immutable string[7] names = ["a.d", "new.d", "gone.d", "side.d", "evil.d",
                                        "sub/deep.d", "plain.d"];
    foreach (name; names) {
        auto cli = gitOut(r, "log -1 --format=%ct -- '", name, "'");
        auto last = g.lastTouched(name);
        assert(last.ok, g.why());
        assert(last.since == number(cli.text()), name);
    }

    // Read off the fixture, so the comparison above is known to cover each case.
    assert(g.lastTouched("new.d").since == 0, "never committed: no commit to name");
    assert(g.lastTouched("side.d").since == 1767225603, "the merge follows the side that brought it");
    assert(g.lastTouched("evil.d").since == 1767225605, "the merge itself changed it");
    assert(g.lastTouched("gone.d").since == 1767225602, "the commit that deleted it");
}

// The root is what rev-parse --show-toplevel names, asked from inside it.
unittest {
    import libgit2 : Repo;
    auto root = fixture();
    auto r = root.text();
    Buf inside;
    inside.put(r);
    inside.put("/sub");

    Repo g;
    assert(g.open(inside.text()), g.why());
    scope (exit) g.close();
    auto cli = gitOut(inside.text(), "rev-parse --show-toplevel");
    assert(g.root() == cli.text(), g.root());
}

// What is staged is what git diff --cached --name-only lists, in its order.
unittest {
    import libgit2 : Repo;
    auto root = fixture();
    auto r = root.text();

    Repo g;
    assert(g.open(r), g.why());
    scope (exit) g.close();

    __gshared char[4096] names = 0;
    auto got = g.staged(names[]);
    assert(got !is null, g.why());
    auto cli = gitOut(r, "diff --cached --name-only");
    assert(got == cli.text(), got);
}

// A repository with nothing committed: every file answers 0, and everything
// in the index is staged, as git says of it.
unittest {
    import libgit2 : Repo;
    auto root = scratch("unborn");
    auto r = root.text();
    sh("git init -q -b main '", r, "'");
    sh("printf 'one\\n' > '", r, "/a.d'");
    sh("git -C '", r, "' add a.d");

    Repo g;
    assert(g.open(r), g.why());
    scope (exit) g.close();
    auto last = g.lastTouched("a.d");
    assert(last.ok, g.why());
    assert(last.since == 0);

    __gshared char[256] names = 0;
    auto got = g.staged(names[]);
    assert(got !is null, g.why());
    assert(got == gitOut(r, "diff --cached --name-only").text(), got);
}

// Outside any repository there is nothing to open, and git's own words say why.
unittest {
    import libgit2 : Repo;
    auto root = scratch("bare-dir");
    Repo g;
    assert(!g.open(root.text()));
    assert(g.why().length > 0);
}

// The files of the last three commits are the names `git log -3 --name-only`
// prints, in its order: a merge names none, a rename names where it went.
unittest {
    import libgit2 : Repo;
    auto root = fixture();
    auto r = root.text();
    commitAt(r, "2026-01-01T00:00:06Z", "staged");

    Repo g;
    assert(g.open(r), g.why());
    scope (exit) g.close();
    __gshared char[4096] got = 0;
    auto names = g.recent(3, got[]);
    assert(names !is null, g.why());

    auto cli = gitOut(r, "log -3 --name-only --pretty=");
    Buf want;
    size_t start;
    foreach (i; 0 .. cli.n + 1) {
        if (i < cli.n && cli.b[i] != '\n') continue;
        auto line = cli.b[start .. i];
        start = i + 1;
        if (line.length == 0) continue;
        if (want.n > 0) want.put("\n");
        want.put(line);
    }
    assert(names == want.text(), names);
}

// The last commit as Jev is shown it is the text the git program printed for
// it: the patch, the short stat, the names and the subject.
unittest {
    import libgit2 : Repo, Shown;
    auto root = fixture();
    auto r = root.text();
    commitAt(r, "2026-01-01T00:00:06Z", "staged, renamed, removed");

    Repo g;
    assert(g.open(r), g.why());
    scope (exit) g.close();
    __gshared char[65536] got = 0;

    auto patch = g.between("HEAD~1", "HEAD", 3, Shown.patch, got[]);
    assert(patch !is null, g.why());
    assert(patch == gitOut(r, "diff HEAD~1 HEAD").text(), patch);

    auto stat = g.between("HEAD~1", "HEAD", 3, Shown.shortStat, got[]);
    assert(stat !is null, g.why());
    assert(stat == gitOut(r, "diff --shortstat HEAD~1 HEAD").text(), stat);

    auto names = g.between("HEAD~1", "HEAD", 3, Shown.names, got[]);
    assert(names !is null, g.why());
    assert(names == gitOut(r, "diff --name-only HEAD~1 HEAD").text(), names);

    assert(g.subject("HEAD") == gitOut(r, "log -1 --format=%s").text(), g.subject("HEAD"));
}

// A commit as `git show --unified=0 --format=` prints it: against its parent,
// a root commit against nothing.
unittest {
    import libgit2 : Repo;
    auto root = fixture();
    auto r = root.text();
    commitAt(r, "2026-01-01T00:00:06Z", "staged, renamed, removed");

    Repo g;
    assert(g.open(r), g.why());
    scope (exit) g.close();
    __gshared char[65536] got = 0;
    static immutable string[3] revs = ["HEAD", "HEAD~2", "main~3"];
    foreach (rev; revs) {
        auto sha = gitOut(r, "rev-parse ", rev);
        auto shown = g.show(sha.text(), got[]);
        assert(shown !is null, g.why());
        assert(shown == gitOut(r, "show --unified=0 --format= ", sha.text()).text(), rev);
    }
    auto first = gitOut(r, "rev-list --max-parents=0 HEAD");
    auto shown = g.show(first.text(), got[]);
    assert(shown == gitOut(r, "show --unified=0 --format= ", first.text()).text(), "the root commit");
}

private bool holds(const(char)[] hay, const(char)[] needle) {
    if (needle.length == 0) return true;
    foreach (i; 0 .. hay.length) if (i + needle.length <= hay.length && hay[i .. i + needle.length] == needle) return true;
    return false;
}

private const(char)[] lastSegment(const(char)[] path) {
    size_t start;
    foreach (i, c; path) if (c == '/') start = i + 1;
    return path[start .. $];
}

// `git worktree add <path>`: a branch named for the path, cut from HEAD; or
// that branch checked out when it is already there.
unittest {
    import libgit2 : Repo;
    auto root = fixture();
    auto r = root.text();
    auto top = gitOut(r, "rev-parse --show-toplevel");
    sh("git -C '", r, "' branch pre HEAD~1");

    Repo g;
    assert(g.open(r), g.why());
    scope (exit) g.close();

    Buf fresh;
    fresh.put(top.text());
    fresh.put("-fresh");
    assert(g.addWorktree(fresh.text()), g.why());
    auto list = gitOut(r, "worktree list --porcelain");
    Buf line;
    line.put("worktree ");
    line.put(fresh.text());
    assert(holds(list.text(), line.text()), list.text());
    Buf branch;
    branch.put("branch refs/heads/");
    branch.put(lastSegment(fresh.text()));
    assert(holds(list.text(), branch.text()), list.text());
    assert(gitOut(fresh.text(), "rev-parse HEAD").text() == gitOut(r, "rev-parse HEAD").text());
    assert(gitOut(fresh.text(), "status --porcelain").n == 0, "checked out whole");

    Buf pre;
    auto dir = top.text();
    pre.put(dir[0 .. dir.length - lastSegment(dir).length]);
    pre.put("pre");
    assert(g.addWorktree(pre.text()), g.why());
    assert(gitOut(pre.text(), "rev-parse HEAD").text() == gitOut(r, "rev-parse pre").text(),
           "the branch that was there is the one checked out");
    assert(gitOut(pre.text(), "symbolic-ref HEAD").text() == "refs/heads/pre");
}

// The tree holding nothing: a branch on a parentless commit of the empty
// tree, with the message `ground stage`, checked out where the path says.
unittest {
    import libgit2 : Repo;
    auto root = fixture();
    auto r = root.text();
    auto top = gitOut(r, "rev-parse --show-toplevel");

    Repo g;
    assert(g.open(r), g.why());
    scope (exit) g.close();
    Buf path;
    path.put(top.text());
    path.put("-stage");
    assert(g.addEmptyWorktree(path.text(), "stage-1"), g.why());

    assert(gitOut(r, "rev-parse stage-1^{tree}").text() == "4b825dc642cb6eb9a060e54bf8d69288fbee4904");
    assert(gitOut(r, "log -1 --format=%B stage-1").text() == "ground stage");
    assert(gitOut(r, "rev-list --count stage-1").text() == "1", "no parent");
    assert(gitOut(path.text(), "symbolic-ref HEAD").text() == "refs/heads/stage-1");
    assert(gitOut(path.text(), "ls-files").n == 0, "nothing checked out");

    assert(!g.addEmptyWorktree(path.text(), "stage-1"), "a branch that is there is refused, as git branch refuses it");
}

// `git worktree remove --force`: the tree and its record are gone.
unittest {
    import libgit2 : Repo;
    import core.sys.posix.unistd : access, F_OK;
    auto root = fixture();
    auto r = root.text();
    auto top = gitOut(r, "rev-parse --show-toplevel");

    Repo g;
    assert(g.open(r), g.why());
    scope (exit) g.close();
    Buf path;
    path.put(top.text());
    path.put("-gone");
    assert(g.addWorktree(path.text()), g.why());
    sh("printf 'dirty\\n' >> '", path.text(), "/a.d'");

    assert(g.removeWorktree(path.text()), g.why());
    assert(access(path.z(), F_OK) != 0, "the directory is gone");
    assert(!holds(gitOut(r, "worktree list --porcelain").text(), path.text()), "and so is the record");
}

// The status codes are the ones `git status --porcelain` opens its lines with,
// the same codes as many times each.
unittest {
    import libgit2 : Repo;
    auto root = fixture();
    auto r = root.text();
    sh("printf 'changed\\n' >> '", r, "/side.d'");
    sh("printf 'again\\n' >> '", r, "/a.d'");
    sh("rm '", r, "/sub/moved.d'");
    sh("mkdir -p '", r, "/loose'");
    sh("printf 'x\\n' > '", r, "/loose/one.d'");
    sh("printf 'x\\n' > '", r, "/loose/two.d'");
    sh("printf 'x\\n' > '", r, "/stray.d'");

    Repo g;
    assert(g.open(r), g.why());
    scope (exit) g.close();
    __gshared char[4096] got = 0;
    auto codes = g.statusCodes(got[]);
    assert(codes !is null, g.why());

    auto cli = gitOut(r, "--no-optional-locks status --porcelain");
    size_t[64] mine, theirs;
    static immutable string[16] known = ["??", "A ", "AM", "AD", "M ", "MM", "MD", " M", " D",
                                        "R ", "RM", "RD", "D ", "T ", " T", "TM"];
    size_t kind(const(char)[] code) {
        foreach (i, k; known) if (code == k) return i;
        assert(false, code);
    }
    size_t start;
    foreach (i; 0 .. codes.length + 1) {
        if (i < codes.length && codes[i] != '\n') continue;
        if (i > start) mine[kind(codes[start .. start + 2])]++;
        start = i + 1;
    }
    start = 0;
    foreach (i; 0 .. cli.n + 1) {
        if (i < cli.n && cli.b[i] != '\n') continue;
        if (i > start) theirs[kind(cli.b[start .. start + 2])]++;
        start = i + 1;
    }
    assert(mine == theirs, codes);
}

// A push landed when the branch and origin's tracking ref name one commit,
// as for-each-ref printed them; a ref that is not there is no landing.
unittest {
    import libgit2 : Repo;
    auto root = fixture();
    auto r = root.text();
    auto bare = scratch("origin");
    sh("git init -q --bare '", bare.text(), "'");
    sh("git -C '", r, "' remote add origin '", bare.text(), "'");

    Repo g;
    assert(g.open(r), g.why());
    scope (exit) g.close();
    assert(!g.refsAgree("refs/heads/main", "refs/remotes/origin/main"), "never pushed");

    sh("git -C '", r, "' push -q origin main");
    assert(g.refsAgree("refs/heads/main", "refs/remotes/origin/main"));

    commitAt(r, "2026-01-01T00:00:06Z", "after");
    assert(!g.refsAgree("refs/heads/main", "refs/remotes/origin/main"), "a commit origin does not have");
}

// A commit's short name is the one git prints for it, at git's own length.
unittest {
    import libgit2 : Repo;
    auto root = fixture();
    auto r = root.text();
    Repo g;
    assert(g.open(r), g.why());
    scope (exit) g.close();
    auto cli = gitOut(r, "for-each-ref --format='%(objectname:short)' refs/heads/main");
    assert(g.shortId("refs/heads/main") == cli.text(), g.shortId("refs/heads/main"));
    assert(g.shortId("refs/heads/none") is null, "a ref that is not there names nothing");
}

// Past 2^14 packed objects git prints eight characters, not seven.
unittest {
    import libgit2 : Repo;
    auto root = fixture();
    auto r = root.text();
    sh("seq 1 16400 | while read i; do printf 'blob\\ndata %d\\n%s\\n' ${#i} \"$i\"; done",
       " | git -C '", r, "' fast-import --quiet");
    Repo g;
    assert(g.open(r), g.why());
    scope (exit) g.close();
    auto cli = gitOut(r, "for-each-ref --format='%(objectname:short)' refs/heads/main");
    assert(cli.n == 8, cli.text());
    assert(g.shortId("refs/heads/main") == cli.text(), g.shortId("refs/heads/main"));
}

// Ignored is what check-ignore says: a tracked file is never ignored, whatever
// a rule says of its name.
unittest {
    import libgit2 : Repo;
    auto root = fixture();
    auto r = root.text();
    sh("printf '*.log\\nbuild/\\n' > '", r, "/.gitignore'");
    sh("printf 'x\\n' > '", r, "/kept.log'");
    sh("git -C '", r, "' add -f kept.log");
    sh("printf 'x\\n' > '", r, "/loose.log'");
    sh("mkdir -p '", r, "/build'");
    sh("printf 'x\\n' > '", r, "/build/out.d'");

    Repo g;
    assert(g.open(r), g.why());
    scope (exit) g.close();
    static immutable string[5] paths = ["loose.log", "kept.log", "a.d", "build/out.d", "never.log"];
    foreach (p; paths) {
        auto cli = gitOut(r, "check-ignore -- '", p, "'");
        assert(g.ignored(p) == (cli.n > 0 ? 1 : 0), p);
    }
    Buf whole;
    whole.put(gitOut(r, "rev-parse --show-toplevel").text());
    whole.put("/loose.log");
    assert(g.ignored(whole.text()) == 1, "an absolute path inside the tree is asked the same");
}
