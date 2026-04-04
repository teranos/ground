module git;

import zbuf : ZBuf;
import core.stdc.stdio : fread, fopen, fclose, FILE;

// Extract last two path components from cwd.
// "/Users/s.b.vanhouten/SBVH/teranos/tmp/ground" → "tmp/ground"
const(char)[] cwdTail(const(char)[] path) {
    if (path.length == 0) return "unknown";
    // Find last slash
    size_t last = path.length;
    while (last > 0 && path[last - 1] != '/') last--;
    if (last == 0) return path;
    // Find second-to-last slash
    size_t prev = last - 1;
    while (prev > 0 && path[prev - 1] != '/') prev--;
    return path[prev .. $];
}

// Build subject as "parent/repo:branch" for attestations and loom UDP.
// Uses the git repo root (not raw cwd) so subdirectories don't change the subject.
void buildSubject(ref ZBuf buf, const(char)[] cwd, const(char)[] branch) {
    buf.reset();
    size_t repoRootLen;
    auto f = findGitHead(cwd, repoRootLen);
    if (f !is null) {
        fclose(f);
        buf.put(cwdTail(gitdirBuf[0 .. repoRootLen]));
    } else {
        buf.put(cwdTail(cwd));
    }
    buf.put(":");
    buf.put(branch);
}

// --- Branch name ---

// Shared git discovery — walks up from cwd to find .git, returns repo root length
// and opens .git/HEAD for branch reading.
__gshared char[512] gitdirBuf = 0;

private FILE* findGitHead(const(char)[] cwd, out size_t repoRootLen) {
    __gshared ZBuf pathBuf;

    // Read .git/HEAD directly — avoids ~46ms popen subprocess
    // Walk up from cwd to find .git (handles subdirectories of a repo)
    // .git can be a directory (normal) or a file (worktrees: "gitdir: /path/...")

    if (cwd.length == 0 || cwd.length >= gitdirBuf.length) { repoRootLen = 0; return null; }
    foreach (i, c; cwd) gitdirBuf[i] = c;
    size_t cwdLen = cwd.length;

    FILE* f = null;
    while (cwdLen > 0) {
        // Try cwd/.git/HEAD (normal repo)
        pathBuf.reset();
        pathBuf.put(gitdirBuf[0 .. cwdLen]);
        pathBuf.put("/.git/HEAD");
        f = fopen(pathBuf.ptr(), "r");
        if (f !is null) break;

        // Try cwd/.git as a file (worktrees)
        pathBuf.reset();
        pathBuf.put(gitdirBuf[0 .. cwdLen]);
        pathBuf.put("/.git");
        f = fopen(pathBuf.ptr(), "r");
        if (f !is null) {
            __gshared char[512] gdBuf = 0;
            auto gn = fread(&gdBuf[0], 1, gdBuf.length - 1, f);
            fclose(f);
            f = null;
            enum gdPrefix = "gitdir: ";
            if (gn > gdPrefix.length && gdBuf[0 .. gdPrefix.length] == gdPrefix) {
                size_t end = gn;
                while (end > 0 && (gdBuf[end - 1] == '\n' || gdBuf[end - 1] == '\r'))
                    end--;
                if (end > gdPrefix.length) {
                    pathBuf.reset();
                    pathBuf.put(gdBuf[gdPrefix.length .. end]);
                    pathBuf.put("/HEAD");
                    f = fopen(pathBuf.ptr(), "r");
                    if (f !is null) break;
                }
            }
        }

        // Walk up one directory
        while (cwdLen > 0 && gitdirBuf[cwdLen - 1] != '/') cwdLen--;
        if (cwdLen > 0) cwdLen--; // skip the '/'
    }

    repoRootLen = cwdLen;
    return f;
}

const(char)[] getBranch(const(char)[] cwd) {
    __gshared char[256] branchBuf = 0;

    size_t repoRootLen;
    auto f = findGitHead(cwd, repoRootLen);
    if (f is null) return "unknown";

    auto n = fread(&branchBuf[0], 1, branchBuf.length - 1, f);
    fclose(f);

    if (n == 0) return "unknown";

    // .git/HEAD contains "ref: refs/heads/<branch>\n"
    enum prefix = "ref: refs/heads/";
    if (n > prefix.length && branchBuf[0 .. prefix.length] == prefix) {
        size_t end = n;
        while (end > 0 && (branchBuf[end - 1] == '\n' || branchBuf[end - 1] == '\r'))
            end--;
        if (end > prefix.length)
            return branchBuf[prefix.length .. end];
    }

    return "unknown";
}
