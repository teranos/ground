module touch;

// teranos/ground#275
// "DO THAT ISSUE PLEASE"
// "AND BASH AS WELL WHEN IT TOUCHES A FILE"
//
// A row for a tool's use said where the session started and not the file it
// touched. For a Read, an Edit and a Write, and for a Bash command that names
// a file, the row's contexts carry one more for each file, as git writes a
// path at a commit:
//
//     file:<owner>/<repo>@<commit>:<path in the repository>
//
// The repository is the file's own, asked of git for the file's path: a
// worktree answers with the origin of the tree it was cut from, a submodule
// with its own. The commit is the one the working tree was at. A file in no
// repository, or in one with no origin, carries none.

import zbuf : ZBuf;

// What the context begins with.
enum TOUCHED = "file:";

// How many files one row names: a command can name many, and a row is one line.
enum MOST = 16;

// One file as its repository holds it.
struct Touched {
    char[256] repoBuf = 0;
    size_t repoLen;
    char[41] commitBuf = 0;
    size_t commitLen;
    char[2048] pathBuf = 0;
    size_t pathLen;
    const(char)[] repo() const return { return repoBuf[0 .. repoLen]; }
    const(char)[] commit() const return { return commitBuf[0 .. commitLen]; }
    const(char)[] path() const return { return pathBuf[0 .. pathLen]; }
}

// The file at an absolute path, as its repository holds it. False when it is
// in no repository, the repository has no origin, or HEAD names no commit.
bool touched(const(char)[] file, ref Touched out_) {
    import core.sys.posix.stdlib : realpath;
    import libgit2 : Repo;
    import git : originOf;

    out_.repoLen = out_.commitLen = out_.pathLen = 0;
    if (__ctfe) return false;
    if (file.length == 0 || file[0] != '/' || file.length >= 4000) return false;

    // The file's own path, links resolved, as the working tree's top is.
    char[4096] asked = 0;
    foreach (i, c; file) asked[i] = c;
    char[4096] resolved = 0;
    const(char)[] whole = file;
    if (realpath(&asked[0], &resolved[0]) !is null) {
        size_t n = 0;
        while (resolved[n] != 0) n++;
        whole = resolved[0 .. n];
    }
    size_t slash = whole.length;
    while (slash > 0 && whole[slash - 1] != '/') slash--;
    if (slash <= 1) return false;
    auto dir = whole[0 .. slash - 1];

    __gshared Repo g;
    if (!g.open(dir)) return false;
    scope (exit) g.close();
    auto root = g.root();
    if (root is null || root.length == 0) return false;
    if (whole.length <= root.length + 1 || whole[0 .. root.length] != root || whole[root.length] != '/') return false;
    auto id = g.headId();
    if (id is null) return false;
    auto origin = originOf(dir);
    if (origin.length == 0 || origin.length > out_.repoBuf.length) return false;
    auto inRepo = whole[root.length + 1 .. $];
    if (inRepo.length > out_.pathBuf.length) return false;

    foreach (i, c; origin) out_.repoBuf[i] = c;
    out_.repoLen = origin.length;
    foreach (i, c; id) out_.commitBuf[i] = c;
    out_.commitLen = id.length;
    foreach (i, c; inRepo) out_.pathBuf[i] = c;
    out_.pathLen = inRepo.length;
    return true;
}

// One more context of the row, written inside the JSON array as it stands
// open: `","file:owner/repo@commit:path`.
private void putContext(ref ZBuf contexts, ref const Touched t) {
    contexts.put(`","`);
    contexts.put(TOUCHED);
    contexts.put(t.repo());
    contexts.put("@");
    contexts.put(t.commit());
    contexts.put(":");
    enum hex = "0123456789abcdef";
    foreach (c; t.path()) {
        if (c == '"' || c == '\\') { char[2] e = ['\\', c]; contexts.put(e[]); }
        else if (c < 0x20) { char[6] u = ['\\', 'u', '0', '0', hex[c >> 4], hex[c & 0xf]]; contexts.put(u[]); }
        else { char[1] one = [c]; contexts.put(one[]); }
    }
}

// Whether a path names a file that is there.
private bool isFile(const(char)[] path) {
    import core.sys.posix.sys.stat : stat, stat_t, S_IFMT, S_IFREG;
    if (path.length == 0 || path.length >= 4000) return false;
    char[4096] z = 0;
    foreach (i, c; path) z[i] = c;
    stat_t st;
    return stat(&z[0], &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG;
}

// The files a shell command names: each word of it that, read from where the
// command runs, is a file that is there. `cd <dir>` moves where the words
// after it are read from. What a command reaches without naming it, a glob or
// a file a script opens, is not known from the command and is not said.
size_t namedFiles(const(char)[] command, const(char)[] cwd, ref ZBuf files) {
    import core.stdc.stdlib : getenv;
    files.reset();
    size_t count = 0;

    __gshared ZBuf base;
    base.reset();
    base.put(cwd);
    __gshared ZBuf full;

    // A word read from the base: absolute as it is, ~/ from the home.
    void resolve(const(char)[] word) {
        full.reset();
        if (word.length > 1 && word[0] == '~' && word[1] == '/') {
            auto h = getenv("HOME\0".ptr);
            if (h is null) return;
            size_t n = 0;
            while (h[n] != 0) n++;
            full.put(h[0 .. n]);
            full.put(word[1 .. $]);
        } else if (word.length > 0 && word[0] == '/') {
            full.put(word);
        } else {
            full.put(base.slice());
            full.put("/");
            full.put(word);
        }
    }

    bool ends(char c) {
        return c == ' ' || c == '\t' || c == '\n' || c == ';' || c == '&' || c == '|' || c == '<' || c == '>' || c == '(' || c == ')';
    }

    bool cdNext = false;
    size_t at = 0;
    while (at < command.length && count < MOST) {
        if (ends(command[at])) { at++; continue; }
        // One word, a pair of quotes around it or inside it taken off.
        char[4096] word = 0;
        size_t w = 0;
        char quote = 0;
        while (at < command.length) {
            auto c = command[at];
            if (quote != 0) {
                if (c == quote) quote = 0;
                else if (w < word.length) word[w++] = c;
                at++;
                continue;
            }
            if (c == '\'' || c == '"') { quote = c; at++; continue; }
            if (ends(c)) break;
            if (w < word.length) word[w++] = c;
            at++;
        }
        const(char)[] said = word[0 .. w];
        if (said.length == 0) continue;
        if (cdNext) {
            cdNext = false;
            resolve(said);
            if (full.len > 0) {
                base.reset();
                base.put(full.slice());
            }
            continue;
        }
        if (said == "cd") { cdNext = true; continue; }
        if (said[0] == '-') continue;
        // What stands after the equals sign of an assignment is a path too.
        foreach (i, ch; said) {
            if (ch == '/') break;
            if (ch == '=' && i + 1 < said.length) { said = said[i + 1 .. $]; break; }
        }
        resolve(said);
        if (full.len == 0 || !isFile(full.slice())) continue;
        // Once each.
        bool seen = false;
        size_t f = 0;
        auto all = files.slice();
        while (f < all.length) {
            auto end = f;
            while (all[end] != 0) end++;
            if (all[f .. end] == full.slice()) { seen = true; break; }
            f = end + 1;
        }
        if (seen) continue;
        files.put(full.slice());
        files.putChar('\0');
        count++;
    }
    return count;
}

// The row's contexts for the files this event's tool touches. Written into
// the array while it stands open, so nothing is written for an event that is
// no tool's, a tool that touches no file, or a file in no repository.
void putTouched(ref ZBuf contexts, const(char)[] eventName, const(char)[] cwd, const(char)[] payload) {
    import parse : extractToolName, extractFilePath, extractCommand, extractJsonString;
    if (eventName != "PreToolUse" && eventName != "PostToolUse" && eventName != "PostToolUseFailure") return;
    if (payload.length == 0) return;
    auto tool = extractToolName(payload);
    if (tool is null) return;

    __gshared Touched one;
    if (tool == "Read" || tool == "Edit" || tool == "Write" || tool == "MultiEdit" || tool == "NotebookEdit") {
        auto file = extractFilePath(payload);
        if (file is null) {
            __gshared char[4096] buf = 0;
            file = extractJsonString(payload, `"notebook_path"`, &buf[0], buf.length);
        }
        if (file is null) return;
        if (touched(file, one)) putContext(contexts, one);
        return;
    }
    if (tool != "Bash") return;
    auto command = extractCommand(payload);
    if (command is null) return;
    __gshared ZBuf files;
    namedFiles(command, cwd, files);
    auto all = files.slice();
    size_t at = 0;
    while (at < all.length) {
        auto end = at;
        while (all[end] != 0) end++;
        if (touched(all[at .. end], one)) putContext(contexts, one);
        at = end + 1;
    }
}
