module scratchdir_test;

// CTFE tests — failure shows as a compile error.

import scratchdir : isScratch, tmpRootInto;

// The override names a directory, and Claude Code puts its own per-uid one
// under it. Anything shared with another uid is not this session's scratch.
char[64] rooted(const(char)[] tmpdir, uint uid)() {
    char[64] buf = 0;
    tmpRootInto(tmpdir, uid, buf[]);
    return buf;
}

enum ROOTED = "/var/tmp/mine/claude-501";
static assert(tmpRootInto("/var/tmp/mine", 501, new char[64]) == ROOTED.length);
static assert(rooted!("/var/tmp/mine", 501)()[0 .. ROOTED.length] == ROOTED);

// A uid of zero is a uid, not a missing one.
enum ROOT0 = "/tmp/claude-0";
static assert(rooted!("/tmp", 0)()[0 .. ROOT0.length] == ROOT0);

// No override is no root, because the default is a platform fact ground was
// never told. A root nothing sits under is what an empty answer means.
static assert(tmpRootInto("", 501, new char[64]) == 0);

// A destination too small is no answer rather than a truncated path, which
// would name a directory that is not the one the session was given.
static assert(tmpRootInto("/var/tmp/mine", 501, new char[8]) == 0);

enum TMP = "/private/tmp/claude-501";
enum JOB = "/home/golem/.claude/jobs/7a46144f";

// The write that was mangled. A background session's temp file is scratch, and
// it is nowhere near the front of the path.
static assert(isScratch("/home/golem/.claude/jobs/7a46144f/tmp/live/proj/am.toml", TMP, JOB));

// A foreground session's scratchpad, which the old prefix list already caught.
static assert(isScratch("/private/tmp/claude-501/-a-b-ground/09684c24/scratchpad/probe.sh", TMP, JOB));

// The job directory holds state that outlives a turn. Only its tmp/ is scratch.
static assert(!isScratch("/home/golem/.claude/jobs/7a46144f/state.json", TMP, JOB));

// A repository is not scratch, whatever it is called.
static assert(!isScratch("/a/b/source/main.d", TMP, JOB));
static assert(!isScratch("/a/b/tmp/x.d", TMP, JOB));
static assert(!isScratch("/a/tmp-not-really/x.d", TMP, JOB));

// The directory itself, with nothing under it, is not a file being written.
static assert(!isScratch(TMP, TMP, JOB));
static assert(!isScratch(JOB ~ "/tmp", TMP, JOB));

// A root ground was not told is a root nothing sits under.
static assert(!isScratch("/private/tmp/claude-501/x", "", ""));
static assert(!isScratch("", TMP, JOB));
