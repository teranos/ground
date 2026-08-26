module git;

import zbuf : ZBuf;
import core.stdc.stdio : fread, fopen, fclose, FILE;

extern (C) {
    FILE* popen(const(char)* command, const(char)* mode);
    int pclose(FILE* stream);
}

// Extract last two path components from cwd.
// A path like $HOME/SBVH/teranos/tmp/ground becomes tmp/ground
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

// One answer per process. scopeMatches asks once per scope and a hook has
// many, so the walk happens on the first and nowhere after it.
private __gshared char[512] rootAsked = 0;
private __gshared size_t rootAskedLen = 0;
private __gshared char[512] rootFound = 0;
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

    __gshared char[512] walk = 0;
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
            __gshared char[512] gdBuf = 0;
            auto gn = fread(&gdBuf[0], 1, gdBuf.length - 1, f);
            fclose(f);
            auto main = repoFromGitdir(gdBuf[0 .. gn]);
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

// The repository a remote URL names, however the URL spells it. ssh and https
// forms of the same repo differ in scheme, host separator and the .git suffix,
// and none of that is the identity.
const(char)[] originIdentity(const(char)[] url) {
    size_t end = url.length;
    while (end > 0 && (url[end - 1] == '\n' || url[end - 1] == '\r'
                       || url[end - 1] == ' ' || url[end - 1] == '\t')) end--;
    if (end >= 4 && url[end - 4 .. end] == ".git") end -= 4;
    while (end > 0 && url[end - 1] == '/') end--;
    if (end == 0) return "";

    // The repo is the last segment; the owner is the one before it, and a
    // scp-style remote separates them from the host with ':' rather than '/'.
    size_t repoStart = end;
    while (repoStart > 0 && url[repoStart - 1] != '/' && url[repoStart - 1] != ':') repoStart--;
    if (repoStart == 0 || repoStart == end) return "";

    size_t ownerStart = repoStart - 1;
    while (ownerStart > 0 && url[ownerStart - 1] != '/' && url[ownerStart - 1] != ':') ownerStart--;
    if (ownerStart == repoStart - 1) return "";

    return url[ownerStart .. end];
}

unittest {
    // The two ways the same repo is cloned.
    assert(originIdentity("git@github.com:teranos/QNTX.git") == "teranos/QNTX");
    assert(originIdentity("https://github.com/teranos/QNTX.git") == "teranos/QNTX");
    assert(originIdentity("https://github.com/teranos/QNTX") == "teranos/QNTX");

    // git writes a trailing newline into config, and it is not the identity.
    assert(originIdentity("git@github.com:teranos/QNTX.git\n") == "teranos/QNTX");
    assert(originIdentity("git@github.com:teranos/QNTX/") == "teranos/QNTX");

    // A sibling repo is a different identity, which is the whole point.
    assert(originIdentity("git@github.com:teranos/QNTX-App.git") == "teranos/QNTX-App");
    assert(originIdentity("git@github.com:sbvh-nl/q.sbvh.nl.git") == "sbvh-nl/q.sbvh.nl");

    // Nothing to name is empty, not a guess.
    assert(originIdentity("") == "");
    assert(originIdentity("QNTX") == "");
    assert(originIdentity(".git") == "");
}

// One answer per process, like repoRoot — every scope asks, and the config is
// one file that does not change under a hook.
private __gshared char[512] originAsked = 0;
private __gshared size_t originAskedLen = 0;
private __gshared char[256] originFound = 0;
private __gshared size_t originFoundLen = 0;
private __gshared bool originCached = false;

// The repo this place is a checkout of. A worktree answers with the tree it was
// cut from, so every checkout of one repository gives the same answer.
const(char)[] originOf(const(char)[] cwd) {
    if (__ctfe) return "";

    if (cwd.length == 0 || cwd.length >= originAsked.length) return "";
    if (originCached && originAskedLen == cwd.length
        && originAsked[0 .. originAskedLen] == cwd)
        return originFound[0 .. originFoundLen];

    foreach (i, c; cwd) originAsked[i] = c;
    originAskedLen = cwd.length;
    originCached = true;
    originFoundLen = 0;

    auto root = repoRoot(cwd);
    if (root.length == 0) return "";

    __gshared ZBuf pathBuf;
    pathBuf.reset();
    pathBuf.put(root);
    pathBuf.put("/.git/config");
    auto f = fopen(pathBuf.ptr(), "r");
    if (f is null) return "";

    __gshared char[8192] cfg = 0;
    auto n = fread(&cfg[0], 1, cfg.length - 1, f);
    fclose(f);
    if (n == 0) return "";

    auto url = urlOfOrigin(cfg[0 .. n]);
    auto id = originIdentity(url);
    if (id.length == 0 || id.length > originFound.length) return "";
    foreach (i, c; id) originFound[i] = c;
    originFoundLen = id.length;
    return originFound[0 .. originFoundLen];
}

// The url of the origin remote in a git config, or empty when it declares none.
// Sections run until the next one opens, so a url outside origin is not it.
const(char)[] urlOfOrigin(const(char)[] cfg) {
    enum header = "[remote \"origin\"]";
    size_t i = 0;
    bool inOrigin = false;

    while (i < cfg.length) {
        size_t lineEnd = i;
        while (lineEnd < cfg.length && cfg[lineEnd] != '\n') lineEnd++;
        auto line = trimBoth(cfg[i .. lineEnd]);
        i = lineEnd + 1;

        if (line.length == 0) continue;
        if (line[0] == '[') {
            inOrigin = line.length >= header.length && line[0 .. header.length] == header;
            continue;
        }
        if (!inOrigin) continue;

        enum key = "url";
        if (line.length <= key.length || line[0 .. key.length] != key) continue;
        auto rest = trimBoth(line[key.length .. $]);
        if (rest.length == 0 || rest[0] != '=') continue;
        return trimBoth(rest[1 .. $]);
    }
    return "";
}

private const(char)[] trimBoth(const(char)[] s) {
    size_t a = 0;
    while (a < s.length && (s[a] == ' ' || s[a] == '\t' || s[a] == '\r')) a++;
    size_t b = s.length;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r')) b--;
    return s[a .. b];
}

unittest {
    enum cfg = "[core]\n\trepositoryformatversion = 0\n"
             ~ "[remote \"origin\"]\n\turl = git@github.com:teranos/QNTX.git\n"
             ~ "\tfetch = +refs/heads/*:refs/remotes/origin/*\n";
    assert(urlOfOrigin(cfg) == "git@github.com:teranos/QNTX.git");
    assert(originIdentity(urlOfOrigin(cfg)) == "teranos/QNTX");

    // A url in another remote is that remote's, and origin is what was asked.
    enum other = "[remote \"upstream\"]\n\turl = git@github.com:someone/else.git\n"
               ~ "[remote \"origin\"]\n\turl = git@github.com:teranos/QNTX.git\n";
    assert(urlOfOrigin(other) == "git@github.com:teranos/QNTX.git");

    // A repo with no origin names none.
    assert(urlOfOrigin("[core]\n\tbare = false\n") == "");
    assert(urlOfOrigin("") == "");
}

unittest {
    // A push that was rejected leaves the two refs apart, and ground performed
    // for it anyway — a deploy of a commit the remote never received.
    assert(landedFromRefs("abc123\nabc123\n"));
    assert(!landedFromRefs("abc123\ndef456\n"));

    // One line is the remote ref missing, which is a branch never pushed.
    assert(!landedFromRefs("abc123\n"));
    assert(!landedFromRefs(""));
    assert(!landedFromRefs("\n\n"));
}

unittest {
    assert(branchFromHead("ref: refs/heads/main\n") == "main");

    // A branch name is a path, and the whole of it is the name.
    assert(branchFromHead("ref: refs/heads/claude/glyphs-x\n") == "claude/glyphs-x");

    // Detached: a commit is not a branch, and answering one is a lie a caller
    // cannot see through — `unknown` reads as a branch all the way to SSM.
    assert(branchFromHead("4c9f5402b1392e14d4d39817321f329b12976289\n") is null);

    assert(branchFromHead("") is null);
    assert(branchFromHead("ref: refs/heads/\n") is null);
}

// HEAD names a branch by ref, or holds a bare commit when detached. Null is the
// answer when there is no branch to give — a caller cannot see through a name,
// and unknown reads as a branch the whole way downstream.
const(char)[] branchFromHead(const(char)[] head) {
    enum prefix = "ref: refs/heads/";
    if (head.length <= prefix.length) return null;
    if (head[0 .. prefix.length] != prefix) return null;

    size_t end = head.length;
    while (end > 0 && (head[end - 1] == '\n' || head[end - 1] == '\r')) end--;
    if (end <= prefix.length) return null;
    return head[prefix.length .. end];
}

// Two revisions, one per line: the branch and its remote-tracking ref. Equal
// means the push landed. Anything else — one line, none, a difference — is a
// remote that does not have what this tree has.
bool landedFromRefs(const(char)[] out_) {
    const(char)[] first, second;
    size_t start = 0;
    size_t seen = 0;
    foreach (i, c; out_) {
        if (c != '\n') continue;
        auto line = out_[start .. i];
        while (line.length > 0 && (line[$ - 1] == '\r' || line[$ - 1] == ' ')) line = line[0 .. $ - 1];
        start = i + 1;
        if (line.length == 0) continue;
        if (seen == 0) first = line;
        else if (seen == 1) second = line;
        seen++;
    }
    return seen == 2 && first == second;
}

// Whether the remote already has what this branch has. Runs once per push, so
// the subprocess getBranch avoids is affordable here.
bool pushLanded(const(char)[] root, const(char)[] branch) {
    if (__ctfe || root.length == 0 || branch.length == 0) return false;

    // popen is /bin/sh, so a quote in either value is sh source. Neither is
    // worth escaping for: answer no and let the caller say the push did not land.
    foreach (c; root) if (c == '\'') return false;
    foreach (c; branch) if (c == '\'') return false;

    __gshared ZBuf cmd;
    cmd.reset();
    // for-each-ref and not rev-parse: --verify takes one revision, and a ref
    // that is not there prints nothing rather than failing the whole command.
    cmd.put("git -C '");
    cmd.put(root);
    cmd.put("' for-each-ref --format='%(objectname)' 'refs/heads/");
    cmd.put(branch);
    cmd.put("' 'refs/remotes/origin/");
    cmd.put(branch);
    cmd.put("' 2>/dev/null");

    auto pipe = popen(cmd.ptr(), "r");
    if (pipe is null) return false;
    __gshared char[256] outBuf = 0;
    auto n = fread(&outBuf[0], 1, outBuf.length - 1, pipe);
    pclose(pipe);
    return landedFromRefs(outBuf[0 .. n]);
}

const(char)[] getBranch(const(char)[] cwd) {
    __gshared char[256] branchBuf = 0;

    size_t repoRootLen;
    auto f = findGitHead(cwd, repoRootLen);
    if (f is null) return null;

    auto n = fread(&branchBuf[0], 1, branchBuf.length - 1, f);
    fclose(f);

    return branchFromHead(branchBuf[0 .. n]);
}
