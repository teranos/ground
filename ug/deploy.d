module deploy;

// Which build this host last saw, and when it first saw it.
// Rules read from collet's Deploy.note.

// The row is one process per frame, so whether a build changed is a question
// only disk can answer, and a deploy outlives any session.

enum CYAN  = "\033[36m";
enum RESET = "\033[0m";

// How long a newly seen build stays on the row.
enum WINDOW = 60;

// How much of the hash is shown. Enough to read, enough to look up.
enum SHOWN = 7;

// What the state file held.
struct Seen {
    const(char)[] commit;
    long at;
    bool ok;
}

// One line: the commit, a space, the unix second it was first seen.
Seen parseSeen(const(char)[] text) {
    return Seen(null, 0, false);
}

size_t formatSeen(const(char)[] commit, long at, char[] dest) {
    return 0;
}

// What the row should do about this build.
struct Verdict {
    bool show;
    bool write;
}

// A commit with no record counts as changed, so the first frame after install
// announces what is already deployed — unseen by this host is new.
Verdict noteDeploy(Seen prev, const(char)[] commit, long now) {
    return Verdict(false, false);
}

size_t markerInto(const(char)[] commit, char[] dest) {
    return 0;
}
