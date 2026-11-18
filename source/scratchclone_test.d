module scratchclone_test;

// "LISTEN TO ME, I WANT TO BAN GIT CLONES IN SCRATCHPADS"
// "WE DONT BLOCK THE AGENT, WE SILENTLY REWRITE AND NOTIFY THE AGENT AFTER, WE DONT MAKE THE AGENT DO ANOTHER GUESS"
//
// CTFE tests — failure shows as a compile error.

import scratchclone : outOfScratch, Moved;

enum TMP = "/private/tmp/claude-501";
enum PAD = TMP ~ "/-u-teranos/3462bc4e/scratchpad";
enum JOB = "";
enum CWD = "/u/teranos";
enum HOME = "/u";

bool none(const(char)[] path) { return false; }
bool taken(const(char)[] path) { return path == CWD ~ "/ground"; }
const(char)[] beside(const(char)[] at) { return CWD; }

struct Out { char[512] buf = 0; Moved m; const(char)[] text() const return { return buf[0 .. m.len]; } }

Out run(alias exists = none)(const(char)[] command, const(char)[] cwd = CWD, const(char)[] work = CWD) {
    Out o;
    o.m = outOfScratch!(exists, beside)(command, cwd, work, HOME, TMP, JOB, o.buf[]);
    return o;
}

// 「[Opus 5.5] A clone into the scratchpad lands in the session's working directory, under」
// 「[Opus 5.5] the name it was given.」
static assert(run("git clone https://github.com/teranos/ground " ~ PAD ~ "/ground").m.moved);
static assert(run("git clone https://github.com/teranos/ground " ~ PAD ~ "/ground").text()
    == "git clone https://github.com/teranos/ground /u/teranos/ground");
static assert(run("git clone https://github.com/teranos/ground " ~ PAD ~ "/ground").m.to() == "/u/teranos/ground");
static assert(run("git clone https://github.com/teranos/ground " ~ PAD ~ "/ground").m.from() == PAD ~ "/ground");

// 「[Opus 5.5] Options before and between are kept, and one that takes a value is not」
// 「[Opus 5.5] mistaken for the destination.」
static assert(run("git clone --depth 1 -b main git@github.com:teranos/ground.git " ~ PAD ~ "/g2").text()
    == "git clone --depth 1 -b main git@github.com:teranos/ground.git /u/teranos/g2");

// 「[Opus 5.5] Into a scratchpad the shell stands in, with no directory named: the name git」
// 「[Opus 5.5] would have made, put where the session works.」
static assert(run("cd " ~ PAD ~ " && git clone https://github.com/teranos/QNTX.git").text()
    == "cd " ~ PAD ~ " && git clone https://github.com/teranos/QNTX.git /u/teranos/QNTX");
static assert(run("cd " ~ PAD ~ " && git clone https://github.com/teranos/QNTX.git kept").text()
    == "cd " ~ PAD ~ " && git clone https://github.com/teranos/QNTX.git /u/teranos/kept");

// 「[Opus 5.5] A name already there is not cloned over: the next free one is taken.」
static assert(run!taken("git clone https://github.com/teranos/ground " ~ PAD ~ "/ground").m.to() == "/u/teranos/ground-2");

// 「[Opus 5.5] A worktree cut into the scratchpad stands beside its repository instead.」
static assert(run("git worktree add " ~ PAD ~ "/ground-effort -b effort-set-by-hand-stays origin/main", "/u/teranos/ground").text()
    == "git worktree add /u/teranos/ground-effort -b effort-set-by-hand-stays origin/main");
static assert(run("git -C /u/teranos/ground worktree add -q " ~ PAD ~ "/onk -B x origin/main").text()
    == "git -C /u/teranos/ground worktree add -q /u/teranos/onk -B x origin/main");

// 「[Opus 5.5] Anywhere else, nothing is touched.」
static assert(!run("git clone https://github.com/teranos/ground /u/teranos/ground").m.moved);
static assert(!run("git clone https://github.com/teranos/ground").m.moved);
static assert(!run("git worktree add ../ground-x main", "/u/teranos/ground").m.moved);
static assert(!run("git status").m.moved);
static assert(!run("cp -R /u/teranos/ground " ~ PAD ~ "/ground").m.moved);
static assert(!run("git worktree list").m.moved);

// 「[Opus 5.5] A session that itself stands in its scratchpad has nowhere better to put it.」
static assert(!run("git clone https://github.com/teranos/ground " ~ PAD ~ "/ground", PAD, PAD).m.moved);

// 「[Opus 5.5] The shell stood in a checkout; the clone goes where the session works, not」
// 「[Opus 5.5] inside that checkout.」
static assert(run("git clone https://github.com/teranos/sacred-error " ~ PAD ~ "/sacred-error", "/u/teranos/ground", "/u/teranos").m.to()
    == "/u/teranos/sacred-error");
