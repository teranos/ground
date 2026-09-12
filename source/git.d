module git;

import zbuf : ZBuf;
import core.stdc.stdio : fread, fopen, fclose, FILE;
import hooks : Visibility;
import db : sqlite3;

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

// The host a remote url names: after `scheme://` and `user@`, up to the first
// ':' or '/'. Empty for a local path, which names none.
const(char)[] originHost(const(char)[] url) {
    size_t i = 0;
    foreach (k; 0 .. url.length) {
        if (k + 2 < url.length && url[k] == ':' && url[k + 1] == '/' && url[k + 2] == '/') {
            i = k + 3;
            break;
        }
        if (url[k] == '/' || url[k] == '@') break;
    }

    size_t start = i;
    size_t j = i;
    while (j < url.length && url[j] != ':' && url[j] != '/') {
        if (url[j] == '@') start = j + 1;
        j++;
    }
    return url[start .. j];
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

unittest {
    // The host, however the url spells it. Only GitHub can be asked, so a
    // remote anywhere else has to be seen as somewhere else.
    assert(originHost("git@github.com:teranos/QNTX.git") == "github.com");
    assert(originHost("https://github.com/teranos/QNTX.git") == "github.com");
    assert(originHost("ssh://git@github.com/teranos/QNTX.git") == "github.com");
    assert(originHost("git@gitlab.com:foo/bar.git") == "gitlab.com");
    assert(originHost("https://gitlab.example.org/foo/bar") == "gitlab.example.org");
    assert(originHost("https://github.com:443/teranos/QNTX") == "github.com");

    // A local path names no host.
    assert(originHost("/srv/git/repo.git") == "");
    assert(originHost("") == "");
}

// One answer per process, like repoRoot — every scope asks, and the config is
// one file that does not change under a hook.
private __gshared char[512] urlAsked = 0;
private __gshared size_t urlAskedLen = 0;
private __gshared char[512] urlFound = 0;
private __gshared size_t urlFoundLen = 0;
private __gshared bool urlCached = false;

// The origin url of the repo this place is a checkout of. A worktree answers
// with the tree it was cut from, so every checkout of one repository agrees.
const(char)[] originUrlOf(const(char)[] cwd) {
    if (__ctfe) return "";

    if (cwd.length == 0 || cwd.length >= urlAsked.length) return "";
    if (urlCached && urlAskedLen == cwd.length
        && urlAsked[0 .. urlAskedLen] == cwd)
        return urlFound[0 .. urlFoundLen];

    foreach (i, c; cwd) urlAsked[i] = c;
    urlAskedLen = cwd.length;
    urlCached = true;
    urlFoundLen = 0;

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
    if (url.length == 0 || url.length > urlFound.length) return "";
    foreach (i, c; url) urlFound[i] = c;
    urlFoundLen = url.length;
    return urlFound[0 .. urlFoundLen];
}

// The repo this place is a checkout of, as owner/repo.
const(char)[] originOf(const(char)[] cwd) {
    return originIdentity(originUrlOf(cwd));
}

const(char)[] originHostOf(const(char)[] cwd) {
    return originHost(originUrlOf(cwd));
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
    // "gitignored files should be excempt from the golem rewrite rule"
    // check-ignore prints the path it was asked about when git ignores it, and
    // nothing at all when it does not.
    assert(ignoredFromCheck("controls/dispatch.pbt\n"));
    assert(ignoredFromCheck("/home/u/proj/controls/dispatch.pbt\n"));
    assert(!ignoredFromCheck(""));
    assert(!ignoredFromCheck("\n"));
    assert(!ignoredFromCheck("  \n"));
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

// check-ignore names what it was asked about when git ignores it, and says
// nothing when it does not. One non-blank line is the whole answer.
bool ignoredFromCheck(const(char)[] out_) {
    foreach (c; out_)
        if (c != '\n' && c != '\r' && c != ' ' && c != '\t') return true;
    return false;
}

// Whether git ignores this path. A file git ignores never reaches the remote,
// so a rule protecting what the remote shows has nothing to protect in it.
bool isIgnored(const(char)[] root, const(char)[] path) {
    if (__ctfe || root.length == 0 || path.length == 0) return false;

    // popen is /bin/sh, so a quote in either value is sh source. Answer no:
    // the rewrite then applies, which is the safe side.
    foreach (c; root) if (c == '\'') return false;
    foreach (c; path) if (c == '\'') return false;

    __gshared ZBuf cmd;
    cmd.reset();
    cmd.put("git -C '");
    cmd.put(root);
    cmd.put("' check-ignore -- '");
    cmd.put(path);
    cmd.put("' 2>/dev/null");

    auto pipe = popen(cmd.ptr(), "r");
    if (pipe is null) return false;
    __gshared char[4096] outBuf = 0;
    auto n = fread(&outBuf[0], 1, outBuf.length - 1, pipe);
    pclose(pipe);
    return ignoredFromCheck(outBuf[0 .. n]);
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

// visibilityIn reads GitHub's answer for a repository the way the throttle
// reads the rate limit: one field, no jq. Anything that is not a plain
// `"private": true` or `"private": false` is unknown.
Visibility visibilityIn(const(char)[] json) {
    import matcher : indexOf;
    enum key = `"private":`;
    auto at = indexOf(json, key);
    if (at < 0) return Visibility.Unknown;
    size_t pos = cast(size_t) at + key.length;
    while (pos < json.length && json[pos] == ' ') pos++;
    if (pos + 4 <= json.length && json[pos .. pos + 4] == "true") return Visibility.Private;
    if (pos + 5 <= json.length && json[pos .. pos + 5] == "false") return Visibility.Public;
    return Visibility.Unknown;
}

unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, SQLITE_OK, applySchema;
    sqlite3* testDb;
    assert(sqlite3_open(":memory:\0".ptr, &testDb) == SQLITE_OK);
    assert(applySchema(testDb));

    // Never asked is not known.
    assert(knownVisibility(testDb, "teranos/x") == Visibility.Unknown);

    rememberVisibility(testDb, "teranos/x", Visibility.Public);
    assert(knownVisibility(testDb, "teranos/x") == Visibility.Public);

    // GitHub's latest word replaces the earlier one.
    rememberVisibility(testDb, "teranos/x", Visibility.Private);
    assert(knownVisibility(testDb, "teranos/x") == Visibility.Private);

    // Unknown is not remembered: a network down for one write must not make
    // a repository public for good.
    rememberVisibility(testDb, "teranos/y", Visibility.Unknown);
    assert(knownVisibility(testDb, "teranos/y") == Visibility.Unknown);

    // One origin's answer is not another's.
    assert(knownVisibility(testDb, "teranos/z") == Visibility.Unknown);

    sqlite3_close(testDb);
}

unittest {
    // The env wins over gh, and GH_TOKEN over GITHUB_TOKEN, the order the
    // shell script had.
    assert(firstToken("a", "b", "c") == "a");
    assert(firstToken("", "b", "c") == "b");
    assert(firstToken("", "", "c") == "c");

    // gh prints a trailing newline, and a newline inside a header is a
    // malformed request, not a bad token.
    assert(firstToken("", "", "c\n") == "c");
    assert(firstToken(" \n", "", "c") == "c", "whitespace is not a credential");

    assert(firstToken("", "", "") == "");
}

// repoVisibility is whether the repository at root is public, by its origin.
// Asked of GitHub once per origin with curl and the token gh holds, the way
// a dispatch asks, and remembered in ground's db so the next write costs
// nothing. Unknown is not remembered: a network down for one write must not
// make a repository public for good.
Visibility repoVisibility(const(char)[] root) {
    if (__ctfe || root.length == 0) return Visibility.Unknown;
    auto origin = originOf(root);
    if (origin.length == 0) return Visibility.Unknown;
    // Only GitHub answers. A remote anywhere else is not asked about whatever
    // repository happens to share its name there.
    if (originHostOf(root) != "github.com") return Visibility.Unknown;
    foreach (c; origin) if (c == '\'' || c == '"' || c == ' ') return Visibility.Unknown;

    import db : openDb, sqlite3_close;

    auto store = openDb();
    if (store !is null) {
        auto known = knownVisibility(store, origin);
        if (known != Visibility.Unknown) {
            sqlite3_close(store);
            return known;
        }
    }

    import http : curlGet;
    __gshared ZBuf url;
    url.reset();
    url.put("https://api.github.com/repos/");
    url.put(origin);

    __gshared char[16384] outBuf = 0;
    auto n = curlGet(url.slice(), githubToken(), outBuf[]);
    auto seen = visibilityIn(outBuf[0 .. n]);

    if (store !is null) {
        rememberVisibility(store, origin, seen);
        sqlite3_close(store);
    }
    return seen;
}

// What GitHub last said about an origin, or Unknown when it was never asked.
Visibility knownVisibility(sqlite3* db, const(char)[] origin) {
    import db : sqlite3_stmt, sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_step,
                sqlite3_column_int64, sqlite3_finalize, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    sqlite3_stmt* stmt;
    enum sql = "SELECT visibility FROM repo_visibility WHERE origin = ?1\0";
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return Visibility.Unknown;
    sqlite3_bind_text(stmt, 1, origin.ptr, cast(int) origin.length, SQLITE_TRANSIENT);
    auto known = Visibility.Unknown;
    if (sqlite3_step(stmt) == SQLITE_ROW) known = cast(Visibility) sqlite3_column_int64(stmt, 0);
    sqlite3_finalize(stmt);
    return known;
}

// Unknown is not remembered: a network down for one write must not make a
// repository public for good.
void rememberVisibility(sqlite3* db, const(char)[] origin, Visibility seen) {
    import db : sqlite3_stmt, sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_bind_int64,
                sqlite3_step, sqlite3_finalize, SQLITE_OK, SQLITE_TRANSIENT;
    if (seen == Visibility.Unknown) return;
    sqlite3_stmt* stmt;
    enum sql = "INSERT OR REPLACE INTO repo_visibility (origin, visibility) VALUES (?1, ?2)\0";
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return;
    sqlite3_bind_text(stmt, 1, origin.ptr, cast(int) origin.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 2, cast(long) seen);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

// The first of the three that is a credential once trimmed.
const(char)[] firstToken(const(char)[] ghToken, const(char)[] githubToken, const(char)[] ghAuth) {
    import http : trimToken;
    auto a = trimToken(ghToken);
    if (a.length > 0) return a;
    auto b = trimToken(githubToken);
    if (b.length > 0) return b;
    return trimToken(ghAuth);
}

// GH_TOKEN, then GITHUB_TOKEN, then what gh holds. gh is asked only when the
// env has nothing, since asking it is a process.
const(char)[] githubToken() {
    if (__ctfe) return "";
    import db : getenv;

    static const(char)[] envSlice(const(char)* p) {
        if (p is null) return "";
        size_t n = 0;
        while (p[n] != 0) n++;
        return p[0 .. n];
    }

    auto fromEnv = firstToken(envSlice(getenv("GH_TOKEN\0".ptr)),
                              envSlice(getenv("GITHUB_TOKEN\0".ptr)), "");
    if (fromEnv.length > 0) return fromEnv;

    __gshared char[512] ghBuf = 0;
    auto pipe = popen("gh auth token 2>/dev/null", "r");
    if (pipe is null) return "";
    auto n = fread(&ghBuf[0], 1, ghBuf.length - 1, pipe);
    pclose(pipe);
    return firstToken("", "", ghBuf[0 .. n]);
}
