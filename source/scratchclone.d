module scratchclone;

// "LISTEN TO ME, I WANT TO BAN GIT CLONES IN SCRATCHPADS"
// "WE DONT BLOCK THE AGENT, WE SILENTLY REWRITE AND NOTIFY THE AGENT AFTER, WE DONT MAKE THE AGENT DO ANOTHER GUESS"
//
// 「[Opus 5.5] A repository cloned or cut into the scratchpad is outside where the session」
// 「[Opus 5.5] works, and its own CLAUDE.md never reaches the agent working in it: on」
// 「[Opus 5.5] 2026-11-18 a session changed ground from a worktree in its scratchpad and」
// 「[Opus 5.5] broke the ORDER ground's CLAUDE.md sets. The destination is moved before」
// 「[Opus 5.5] the command runs: a clone to the session's working directory, a worktree」
// 「[Opus 5.5] beside its repository, as the person's own stand. Nothing is refused; the」
// 「[Opus 5.5] agent is told where it went.」

import scratchdir : isScratch;
import matcher : extractLeadingCd, isGitInvocation, strip;

// 「[Opus 5.5] What one look did: whether a destination moved, the command as it now」
// 「[Opus 5.5] stands, and the two places, for the agent to be told.」
struct Moved {
    bool moved;
    bool worktree;
    size_t len;
    char[1024] fromBuf = 0;
    size_t fromLen;
    char[1024] toBuf = 0;
    size_t toLen;
    const(char)[] from() const return { return fromBuf[0 .. fromLen]; }
    const(char)[] to() const return { return toBuf[0 .. toLen]; }
}

private struct Tok { size_t at, end; const(char)[] word; }

// 「[Opus 5.5] A segment's words, a quoted one whole and without its quotes.」
private size_t words(const(char)[] seg, Tok[] toks) {
    size_t n = 0, i = 0;
    while (i < seg.length && n < toks.length) {
        while (i < seg.length && seg[i] == ' ') i++;
        if (i >= seg.length) break;
        auto at = i;
        if (seg[i] == '"' || seg[i] == '\'') {
            auto q = seg[i];
            auto j = i + 1;
            while (j < seg.length && seg[j] != q) j++;
            toks[n++] = Tok(at, j < seg.length ? j + 1 : j, seg[i + 1 .. j]);
            i = j + 1;
            continue;
        }
        while (i < seg.length && seg[i] != ' ') i++;
        toks[n++] = Tok(at, i, seg[at .. i]);
    }
    return n;
}

private bool among(const(char)[] w, const(string)[] set) {
    foreach (s; set) if (w == s) return true;
    return false;
}

private bool has(const(char)[] w, char c) {
    foreach (x; w) if (x == c) return true;
    return false;
}

// 「[Opus 5.5] The options that take the next word as their value (git-clone(1),」
// 「[Opus 5.5] git-worktree(1)): that word is no destination.」
private immutable string[] CLONE_VALUED = ["-b", "--branch", "-o", "--origin", "-u", "--upload-pack",
    "--reference", "--reference-if-able", "--separate-git-dir", "--depth", "--shallow-since",
    "--shallow-exclude", "-c", "--config", "--template", "--filter", "-j", "--jobs",
    "--server-option", "--bundle-uri", "--revision"];
private immutable string[] WORKTREE_VALUED = ["-b", "-B", "--reason"];

// 「[Opus 5.5] The directory git clone makes when none is named: the repository's last」
// 「[Opus 5.5] part, without .git.」
private const(char)[] humanish(const(char)[] url) {
    while (url.length > 0 && url[$ - 1] == '/') url = url[0 .. $ - 1];
    if (url.length > 4 && url[$ - 4 .. $] == ".git") url = url[0 .. $ - 4];
    size_t s = 0;
    foreach (i, c; url) if (c == '/' || c == ':') s = i + 1;
    return url[s .. $];
}

private const(char)[] lastPart(const(char)[] p) {
    while (p.length > 1 && p[$ - 1] == '/') p = p[0 .. $ - 1];
    size_t s = 0;
    foreach (i, c; p) if (c == '/') s = i + 1;
    return p[s .. $];
}

// 「[Opus 5.5] A path as the shell standing at `base` reads it, into dest.」
private size_t resolved(const(char)[] p, const(char)[] base, const(char)[] home, char[] dest) {
    size_t o = 0;
    void put(const(char)[] s) { foreach (c; s) if (o < dest.length) dest[o++] = c; }
    if (p.length > 0 && p[0] == '/') put(p);
    else if (p == "~") put(home);
    else if (p.length > 1 && p[0] == '~' && p[1] == '/') { put(home); put(p[1 .. $]); }
    else { if (base.length == 0) return 0; put(base); put("/"); put(p); }
    return o;
}

// 「[Opus 5.5] `exists` says whether a path is taken; `worktreeHome` names where the」
// 「[Opus 5.5] repository a place belongs to stands (the directory holding it). Both are」
// 「[Opus 5.5] asked of the filesystem at run time and of the test at compile time.」
Moved outOfScratch(alias exists, alias worktreeHome)(const(char)[] command, const(char)[] cwd,
        const(char)[] workDir, const(char)[] home, const(char)[] tmpRoot, const(char)[] jobDir, char[] dest) {
    Moved m;
    size_t o = 0;
    void put(const(char)[] s) { foreach (c; s) if (o < dest.length) dest[o++] = c; }

    auto shell = cwd;
    size_t start = 0, i = 0;
    while (i <= command.length) {
        bool sep = false;
        size_t skip = 0;
        if (i == command.length) sep = true;
        else if (command[i] == '|' || command[i] == ';' || command[i] == '\n') { sep = true; skip = 1; }
        else if (i + 1 < command.length && command[i] == '&' && command[i + 1] == '&') { sep = true; skip = 2; }
        if (!sep) { i++; continue; }

        auto raw = command[start .. i];
        auto seg = strip(raw);
        auto segAt = start + (seg.length > 0 ? cast(size_t)(seg.ptr - raw.ptr) : 0);
        auto cd = extractLeadingCd(seg);
        if (cd.length > 0) shell = cd;

        if (!m.moved && isGitInvocation(seg)) {
            Tok[64] toks;
            auto n = words(seg, toks[]);
            size_t k = 1;
            auto base = shell;
            char[1024] baseBuf = 0;
            while (k + 1 < n && (toks[k].word == "-C" || toks[k].word == "-c")) {
                if (toks[k].word == "-C") {
                    auto bl = resolved(toks[k + 1].word, shell, home, baseBuf[]);
                    base = baseBuf[0 .. bl];
                }
                k += 2;
            }
            bool clone = k < n && toks[k].word == "clone";
            bool tree = k + 1 < n && toks[k].word == "worktree" && toks[k + 1].word == "add";
            if (clone || tree) {
                k += clone ? 1 : 2;
                size_t[2] pos;
                size_t np = 0;
                bool rest = false;
                while (k < n && np < 2) {
                    auto w = toks[k].word;
                    if (!rest && w == "--") { rest = true; k++; continue; }
                    if (!rest && w.length > 0 && w[0] == '-') {
                        auto valued = clone ? among(w, CLONE_VALUED) : among(w, WORKTREE_VALUED);
                        k += (valued && !has(w, '=')) ? 2 : 1;
                        continue;
                    }
                    pos[np++] = k++;
                }
                // 「[Opus 5.5] A clone names the repository first and maybe a directory; a」
                // 「[Opus 5.5] worktree names its path first.」
                bool named = clone ? np == 2 : np >= 1;
                bool any = clone ? np >= 1 : np >= 1;
                if (any) {
                    auto given = named ? toks[pos[clone ? 1 : 0]].word : humanish(toks[pos[0]].word);
                    char[1024] fromBuf = 0;
                    auto fl = resolved(given, base, home, fromBuf[]);
                    auto from = fromBuf[0 .. fl];
                    if (fl > 0 && isScratch(from, tmpRoot, jobDir)) {
                        // 「[Opus 5.5] The session's own directory, not where its shell stands: on」
                        // 「[Opus 5.5] 2026-11-18 the first live clone landed inside the ground checkout」
                        // 「[Opus 5.5] the shell had cd'd into.」
                        auto where = clone ? workDir : worktreeHome(base);
                        auto name = lastPart(from);
                        char[1024] probe = 0;
                        size_t pl = 0;
                        void probeOf(size_t suffix) {
                            pl = 0;
                            foreach (c; where) probe[pl++] = c;
                            probe[pl++] = '/';
                            foreach (c; name) probe[pl++] = c;
                            if (suffix > 1) { probe[pl++] = '-'; probe[pl++] = cast(char)('0' + suffix); }
                        }
                        probeOf(1);
                        if (where.length > 0 && !isScratch(probe[0 .. pl], tmpRoot, jobDir)) {
                            size_t s = 1;
                            while (exists(probe[0 .. pl]) && s < 9) probeOf(++s);
                            if (!exists(probe[0 .. pl])) {
                                m.moved = true;
                                m.worktree = tree;
                                foreach (c; from) m.fromBuf[m.fromLen++] = c;
                                foreach (c; probe[0 .. pl]) m.toBuf[m.toLen++] = c;
                                bool spaced = has(m.to(), ' ');
                                void putTo() { if (spaced) put("'"); put(m.to()); if (spaced) put("'"); }
                                if (named) {
                                    auto t = toks[pos[clone ? 1 : 0]];
                                    put(command[0 .. segAt + t.at]);
                                    putTo();
                                    put(command[segAt + t.end .. $]);
                                } else {
                                    auto t = toks[pos[0]];
                                    put(command[0 .. segAt + t.end]);
                                    put(" ");
                                    putTo();
                                    put(command[segAt + t.end .. $]);
                                }
                                m.len = o;
                                return m;
                            }
                        }
                    }
                }
            }
        }
        if (i == command.length) break;
        start = i + skip;
        i += skip > 0 ? skip : 1;
    }
    return m;
}

// 「[Opus 5.5] What the agent is told after: where it went and why, so it works there」
// 「[Opus 5.5] without a second guess.」
size_t toldOf(ref const Moved m, char[] dest) {
    size_t o = 0;
    void put(const(char)[] s) { foreach (c; s) if (o < dest.length) dest[o++] = c; }
    put(m.worktree ? "ground cut this worktree at " : "ground cloned this at ");
    put(m.to());
    put(" instead of ");
    put(m.from());
    put(": a repository in the scratchpad is cut off from its own CLAUDE.md. Work in it at ");
    put(m.to());
    put(".");
    return o;
}

// 「[Opus 5.5] This session's temp root: the one CLAUDE_CODE_TMPDIR names, or, with none」
// 「[Opus 5.5] named, the one Claude Code makes under /tmp, as the filesystem resolves /tmp」
// 「[Opus 5.5] (on macOS /private/tmp). On 2026-11-18 the variable was unset and the」
// 「[Opus 5.5] scratchpad stood at /private/tmp/claude-501/<project>/<session>/scratchpad.」
size_t claudeTmpRoot(char[] dest) {
    import core.stdc.stdlib : getenv;
    import core.sys.posix.stdlib : realpath;
    import core.sys.posix.unistd : getuid;
    import scratchdir : tmpRootInto;
    auto env = getenv("CLAUDE_CODE_TMPDIR\0".ptr);
    size_t el = 0;
    if (env !is null) while (env[el] != 0) el++;
    if (el > 0) return tmpRootInto(env[0 .. el], getuid(), dest);
    char[1024] actual = 0;
    if (realpath("/tmp\0".ptr, actual.ptr) is null) return 0;
    size_t rl = 0;
    while (actual[rl] != 0) rl++;
    return tmpRootInto(actual[0 .. rl], getuid(), dest);
}

// 「[Opus 5.5] At run time: the filesystem says what is taken, and a worktree stands in」
// 「[Opus 5.5] the directory that holds its repository.」
bool takenOnDisk(const(char)[] path) {
    import core.sys.posix.sys.stat : stat, stat_t;
    char[1100] z = 0;
    if (path.length >= z.length) return true;
    z[0 .. path.length] = path[];
    stat_t st;
    return stat(z.ptr, &st) == 0;
}

const(char)[] repoHome(const(char)[] at) {
    import gitdir : repoRoot;
    auto root = repoRoot(at);
    if (root.length == 0) return "";
    size_t s = 0;
    foreach (i, c; root) if (c == '/') s = i;
    return root[0 .. s];
}
