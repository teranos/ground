module gitdir;

// Where a repository is. A .git that is a directory is the tree itself. A
// .git that is a file names either a worktree's tree, which is the repository,
// or a submodule's own object store, which makes the submodule one.

import zbuf : ZBuf;
import core.stdc.stdio : fread, fopen, fclose, FILE;

// Shared git discovery — walks up from cwd to find .git, returns repo root length
// and opens .git/HEAD for branch reading.
__gshared char[1024] gitdirBuf = 0;

FILE* findGitHead(const(char)[] cwd, out size_t repoRootLen) {
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
            __gshared char[1024] gdBuf = 0;
            auto gn = fread(&gdBuf[0], 1, gdBuf.length - 1, f);
            fclose(f);
            f = null;
            // A submodule's gitdir is relative to the submodule, so it is
            // resolved against the directory holding the file.
            __gshared char[1024] gd = 0;
            auto target = gitdirInto(gitdirBuf[0 .. cwdLen], gdBuf[0 .. gn], gd[]);
            if (target.length > 0) {
                pathBuf.reset();
                pathBuf.put(target);
                pathBuf.put("/HEAD");
                f = fopen(pathBuf.ptr(), "r");
                if (f !is null) break;
            }
        }

        // Walk up one directory
        while (cwdLen > 0 && gitdirBuf[cwdLen - 1] != '/') cwdLen--;
        if (cwdLen > 0) cwdLen--; // skip the '/'
    }

    repoRootLen = cwdLen;
    return f;
}

// A worktree's .git names the tree it belongs to. Everything before the
// worktrees directory is the repository, which is what a project is.
enum WORKTREES = "/.git/worktrees/";

// The repository a worktree's gitdir line points at, or empty when the line
// names something else. A submodule is not a worktree and is not guessed at.
const(char)[] repoFromGitdir(const(char)[] line) {
    enum prefix = "gitdir: ";
    if (line.length <= prefix.length) return "";
    if (line[0 .. prefix.length] != prefix) return "";

    size_t end = line.length;
    while (end > 0 && (line[end - 1] == '\n' || line[end - 1] == '\r')) end--;
    auto dir = line[prefix.length .. end];

    if (dir.length < WORKTREES.length) return "";
    foreach (i; 0 .. dir.length - WORKTREES.length + 1) {
        if (dir[i .. i + WORKTREES.length] != WORKTREES) continue;
        return dir[0 .. i];
    }
    return "";
}

// A submodule's .git is a file pointing into the parent's modules directory.
// It is its own repository, with its own origin, so it is not the parent.
bool isModuleGitdir(const(char)[] line) {
    import matcher : indexOf;
    enum prefix = "gitdir: ";
    if (line.length <= prefix.length || line[0 .. prefix.length] != prefix) return false;
    return indexOf(line, ".git/modules/") >= 0;
}

// The directory a .git file points at, absolute. git writes a submodule's
// relative to the submodule, so `dir` is what a relative one is under.
const(char)[] gitdirInto(const(char)[] dir, const(char)[] line, char[] dest) {
    enum prefix = "gitdir: ";
    if (line.length <= prefix.length || line[0 .. prefix.length] != prefix) return "";
    size_t end = line.length;
    while (end > prefix.length && (line[end - 1] == '\n' || line[end - 1] == '\r')) end--;
    auto target = line[prefix.length .. end];
    if (target.length == 0) return "";

    size_t o = 0;
    bool put(const(char)[] s) {
        if (o + s.length > dest.length) return false;
        foreach (c; s) dest[o++] = c;
        return true;
    }
    if (target[0] != '/') {
        if (!put(dir) || !put("/")) return "";
    }
    if (!put(target)) return "";
    return dest[0 .. o];
}

// Where a repository's config is: under .git when that is a directory, and at
// the gitdir the .git file names when the repository is a submodule.
const(char)[] configPathInto(const(char)[] root, char[] dest) {
    if (__ctfe) return "";

    size_t o = 0;
    bool put(const(char)[] s) {
        if (o + s.length > dest.length) return false;
        foreach (c; s) dest[o++] = c;
        return true;
    }

    __gshared ZBuf pathBuf;
    pathBuf.reset();
    pathBuf.put(root);
    pathBuf.put("/.git");
    auto f = fopen(pathBuf.ptr(), "r");
    if (f !is null) {
        __gshared char[1024] gdBuf = 0;
        auto gn = fread(&gdBuf[0], 1, gdBuf.length - 1, f);
        fclose(f);
        auto line = gdBuf[0 .. gn];
        if (isModuleGitdir(line)) {
            __gshared char[1024] gd = 0;
            auto target = gitdirInto(root, line, gd[]);
            if (target.length == 0) return "";
            if (!put(target) || !put("/config")) return "";
            return dest[0 .. o];
        }
    }

    if (!put(root) || !put("/.git/config")) return "";
    return dest[0 .. o];
}

unittest {
    enum line = "gitdir: /Users/x/teranos/ground/.git/worktrees/ground-chapter-1";
    assert(repoFromGitdir(line) == "/Users/x/teranos/ground");

    // git writes a trailing newline, and it is not part of the path.
    assert(repoFromGitdir(line ~ "\n") == "/Users/x/teranos/ground");

    // A submodule points into modules, not worktrees. Nothing is inferred.
    assert(repoFromGitdir("gitdir: /Users/x/proj/.git/modules/sub") == "");

    assert(repoFromGitdir("") == "");
    assert(repoFromGitdir("gitdir: ") == "");
    assert(repoFromGitdir("/Users/x/teranos/ground") == "");
}

unittest {
    // A submodule's .git file points into the parent's modules, and the
    // submodule is its own repository: the root is the directory holding the
    // file, not the parent and not nothing.
    assert(isModuleGitdir("gitdir: ../.git/modules/sub\n"));
    assert(isModuleGitdir("gitdir: /Users/x/proj/.git/modules/sub"));
    assert(!isModuleGitdir("gitdir: /Users/x/proj/.git/worktrees/w"));
    assert(!isModuleGitdir(""));

    // Where its config lives: the gitdir, which git writes relative to the
    // submodule itself.
    char[512] buf = 0;
    assert(gitdirInto("/Users/x/proj/sub", "gitdir: ../.git/modules/sub\n", buf[])
           == "/Users/x/proj/sub/../.git/modules/sub");
    assert(gitdirInto("/Users/x/proj/sub", "gitdir: /Users/x/proj/.git/modules/sub", buf[])
           == "/Users/x/proj/.git/modules/sub");
    assert(gitdirInto("/Users/x/proj/sub", "nope", buf[]) == "");
}

// One answer per process. scopeMatches asks once per scope and a hook has
// many, so the walk happens on the first and nowhere after it.
private __gshared char[1024] rootAsked = 0;
private __gshared size_t rootAskedLen = 0;
private __gshared char[1024] rootFound = 0;
private __gshared size_t rootFoundLen = 0;
private __gshared bool rootCached = false;

// The repository this place belongs to, which for a worktree is the tree it
// was cut from. Empty when no repository stands above it.
const(char)[] repoRoot(const(char)[] cwd) {
    // A build has no filesystem to ask, so a scope evaluated at compile time
    // knows only the place it was given.
    if (__ctfe) return "";

    __gshared ZBuf pathBuf;

    if (cwd.length == 0 || cwd.length >= rootAsked.length) return "";
    if (rootCached && rootAskedLen == cwd.length
        && rootAsked[0 .. rootAskedLen] == cwd)
        return rootFound[0 .. rootFoundLen];

    foreach (i, c; cwd) rootAsked[i] = c;
    rootAskedLen = cwd.length;
    rootCached = true;
    rootFoundLen = 0;

    __gshared char[1024] walk = 0;
    foreach (i, c; cwd) walk[i] = c;
    size_t len = cwd.length;

    while (len > 0) {
        // A directory means this is the tree itself.
        pathBuf.reset();
        pathBuf.put(walk[0 .. len]);
        pathBuf.put("/.git/HEAD");
        auto f = fopen(pathBuf.ptr(), "r");
        if (f !is null) {
            fclose(f);
            foreach (i; 0 .. len) rootFound[i] = walk[i];
            rootFoundLen = len;
            return rootFound[0 .. rootFoundLen];
        }

        // A file means a worktree, and its one line names the tree.
        pathBuf.reset();
        pathBuf.put(walk[0 .. len]);
        pathBuf.put("/.git");
        f = fopen(pathBuf.ptr(), "r");
        if (f !is null) {
            __gshared char[1024] gdBuf = 0;
            auto gn = fread(&gdBuf[0], 1, gdBuf.length - 1, f);
            fclose(f);
            auto line = gdBuf[0 .. gn];
            // A submodule is the tree itself: its .git file names where its
            // own objects live, not a tree it was cut from.
            if (isModuleGitdir(line)) {
                foreach (i; 0 .. len) rootFound[i] = walk[i];
                rootFoundLen = len;
                return rootFound[0 .. rootFoundLen];
            }
            auto main = repoFromGitdir(line);
            if (main.length > 0 && main.length <= rootFound.length) {
                foreach (i, c; main) rootFound[i] = c;
                rootFoundLen = main.length;
            }
            return rootFound[0 .. rootFoundLen];
        }

        while (len > 0 && walk[len - 1] != '/') len--;
        if (len > 0) len--;
    }

    return "";
}
