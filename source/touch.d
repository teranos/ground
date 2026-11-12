module touch;

// 「[Fable 5.2] teranos/ground#275」
// "DO THAT ISSUE PLEASE"
// "AND BASH AS WELL WHEN IT TOUCHES A FILE"
//
// 「[Fable 5.2] A row for a tool's use said where the session started and not the file it」
// 「[Fable 5.2] touched. For a Read, an Edit and a Write, and for a Bash command that names」
// 「[Fable 5.2] a file, the row's contexts carry one more for each file, as git writes a」
// 「[Fable 5.2] path at a commit:」
//
//     「[Fable 5.2] file:<owner>/<repo>@<commit>:<path in the repository>」
//
// 「[Fable 5.2] The repository is the file's own, asked of git for the file's path: a」
// 「[Fable 5.2] worktree answers with the origin of the tree it was cut from, a submodule」
// 「[Fable 5.2] with its own. The commit is the one the working tree was at. A file in no」
// 「[Fable 5.2] repository, or in one with no origin, carries none.」
//
// "WE SHOULD CONSIDER A OBSIDIAN VAULT ITS OWN THING"
//
// 「[Fable 5.2] A note of an Obsidian vault is the vault's, whether or not the vault is a」
// 「[Fable 5.2] repository as well: the directory that holds `.obsidian`, by its name.」
//
//     「[Fable 5.2] vault:<vault>:<path in the vault>」
//
// "ON THE SAME ABSTRACTION LEVEL AS REPO, AND/OR KNOW ABOUT BINDINGS"
//
// 「[Fable 5.2] A vault stands beside a repository, and a folder or a note of one can be」
// 「[Fable 5.2] bound to a folder or a note of the other at the node (QNTX vault bind). A」
// 「[Fable 5.2] note in a bound place is also the repository's file it is bound to, on the」
// 「[Fable 5.2] branch the binding names:」
//
//     「[Fable 5.2] file:<owner>/<repo>@<branch>:<path in the repository>」
//
// 「[Fable 5.2] Ground keeps what its node says is bound, asked where a session starts.」

import zbuf : ZBuf;

// 「[Fable 5.2] What the context begins with.」
enum TOUCHED = "file:";

// 「[Fable 5.2] How many files one row names: a command can name many, and a row is one line.」
enum MOST = 16;

// 「[Fable 5.2] One file as its repository holds it.」
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

// 「[Fable 5.2] The file at an absolute path, as its repository holds it. False when it is」
// 「[Fable 5.2] in no repository, the repository has no origin, or HEAD names no commit.」
bool touched(const(char)[] file, ref Touched out_) {
    import core.sys.posix.stdlib : realpath;
    import libgit2 : Repo;
    import git : originOf;

    out_.repoLen = out_.commitLen = out_.pathLen = 0;
    if (__ctfe) return false;
    if (file.length == 0 || file[0] != '/' || file.length >= 4000) return false;

    // 「[Fable 5.2] The file's own path, links resolved, as the working tree's top is.」
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

// 「[Fable 5.2] What a vault's context begins with.」
enum VAULT = "vault:";

// 「[Fable 5.2] The vault a file at an absolute path is a note of: the nearest directory」
// 「[Fable 5.2] above it that holds `.obsidian`. Its name and the file's path inside it」
// 「[Fable 5.2] are slices of file. False when no directory above the file is a vault.」
bool vaultOf(const(char)[] file, out const(char)[] name, out const(char)[] inVault) {
    import core.sys.posix.sys.stat : stat, stat_t, S_IFMT, S_IFDIR;
    if (__ctfe) return false;
    if (file.length == 0 || file[0] != '/' || file.length >= 4000) return false;
    char[4096] probe = 0;
    size_t end = file.length;
    while (true) {
        while (end > 0 && file[end - 1] != '/') end--;
        if (end <= 1) return false;
        end--; // file[0 .. end] is a directory above the file
        size_t n = 0;
        foreach (c; file[0 .. end]) probe[n++] = c;
        foreach (c; "/.obsidian") probe[n++] = c;
        probe[n] = 0;
        stat_t st;
        if (stat(&probe[0], &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR) {
            size_t start = end;
            while (start > 0 && file[start - 1] != '/') start--;
            name = file[start .. end];
            inVault = file[end + 1 .. $];
            return name.length > 0 && inVault.length > 0;
        }
    }
}

// 「[Fable 5.2] A path as it stands inside a JSON string.」
private void putPath(ref ZBuf contexts, const(char)[] path) {
    enum hex = "0123456789abcdef";
    foreach (c; path) {
        if (c == '"' || c == '\\') { char[2] e = ['\\', c]; contexts.put(e[]); }
        else if (c < 0x20) { char[6] u = ['\\', 'u', '0', '0', hex[c >> 4], hex[c & 0xf]]; contexts.put(u[]); }
        else { char[1] one = [c]; contexts.put(one[]); }
    }
}

// 「[Fable 5.2] ---- what is bound ----」

// 「[Fable 5.2] Where ground keeps what its node says is bound: one binding a line,」
// 「[Fable 5.2] <vault> TAB <place in the vault> TAB <owner>/<repo> TAB <branch> TAB <path>.」
const(char)* bindingsFile() {
    import core.stdc.stdlib : getenv;
    __gshared ZBuf path;
    path.reset();
    auto h = getenv("HOME\0".ptr);
    if (h is null) return null;
    size_t n = 0;
    while (h[n] != 0) n++;
    path.put(h[0 .. n]);
    path.put("/.local/share/ground/vault-bindings");
    return path.ptr();
}

// 「[Fable 5.2] The bindings in what a node answers at /api/vault, as the lines ground」
// 「[Fable 5.2] keeps. A binding is written there as」
// 「[Fable 5.2] github.com/<owner>/<repo>@<branch>:<path>=<place>. How many were read.」
size_t bindingsFrom(const(char)[] answer, ref ZBuf lines) {
    import effort : rootAt, memberOf, skipSpace, skipString, skipValue;
    lines.reset();
    size_t count = 0;
    auto root = rootAt(answer);
    if (root >= answer.length) return 0;
    auto vaults = memberOf(answer, root, "vaults");
    if (!vaults.ok || vaults.valAt >= answer.length || answer[vaults.valAt] != '[') return 0;
    size_t v = skipSpace(answer, vaults.valAt + 1);
    while (v < answer.length && answer[v] == '{') {
        auto vEnd = skipValue(answer, v);
        auto name = memberOf(answer, v, "name");
        auto folders = memberOf(answer, v, "folders");
        if (name.ok && folders.ok && answer[name.valAt] == '"' && answer[folders.valAt] == '[') {
            auto vault = answer[name.valAt + 1 .. name.valEnd - 1];
            size_t i = skipSpace(answer, folders.valAt + 1);
            while (i < answer.length && answer[i] == '"') {
                auto end = skipString(answer, i);
                auto said = answer[i + 1 .. end - 1];
                enum host = "github.com/";
                // 「[Fable 5.2] owner/repo @ branch : path = place」
                size_t at = 0, colon = 0, equals = 0;
                foreach (k, c; said) {
                    if (c == '@' && at == 0) at = k;
                    else if (c == ':' && at > 0 && colon == 0) colon = k;
                    else if (c == '=' && colon > 0 && equals == 0) equals = k;
                }
                if (said.length > host.length && said[0 .. host.length] == host && at > host.length && colon > at + 1 && equals > colon + 1 && equals + 1 < said.length) {
                    lines.put(vault);
                    lines.put("\t");
                    lines.put(said[equals + 1 .. $]);
                    lines.put("\t");
                    lines.put(said[host.length .. at]);
                    lines.put("\t");
                    lines.put(said[at + 1 .. colon]);
                    lines.put("\t");
                    lines.put(said[colon + 1 .. equals]);
                    lines.put("\n");
                    count++;
                }
                i = skipSpace(answer, end);
                if (i < answer.length && answer[i] == ',') i = skipSpace(answer, i + 1);
            }
        }
        v = skipSpace(answer, vEnd);
        if (v < answer.length && answer[v] == ',') v = skipSpace(answer, v + 1);
    }
    return count;
}

// 「[Fable 5.2] The repository's file a note is bound to, from the lines ground keeps: the」
// 「[Fable 5.2] binding of the note itself, or of the nearest folder above it. Its」
// 「[Fable 5.2] repository, its branch, and its path into dest. False when the note is in」
// 「[Fable 5.2] no bound place.」
bool boundTo(const(char)[] lines, const(char)[] vault, const(char)[] inVault,
             out const(char)[] repo, out const(char)[] branch, ref ZBuf dest) {
    dest.reset();
    size_t best = 0;
    bool found = false;
    size_t at = 0;
    while (at < lines.length) {
        auto end = at;
        while (end < lines.length && lines[end] != '\n') end++;
        auto line = lines[at .. end];
        at = end + 1;
        const(char)[][5] part;
        size_t p = 0, start = 0;
        foreach (k, c; line) {
            if (c != '\t') continue;
            if (p < 4) part[p++] = line[start .. k];
            start = k + 1;
        }
        if (p != 4) continue;
        part[4] = line[start .. $];
        auto place = part[1];
        if (part[0] != vault || place.length == 0) continue;
        bool whole = place == inVault;
        bool above = inVault.length > place.length + 1 && inVault[0 .. place.length] == place && inVault[place.length] == '/';
        if (!whole && !above) continue;
        if (found && place.length <= best) continue;
        found = true;
        best = place.length;
        repo = part[2];
        branch = part[3];
        dest.reset();
        // 「[Fable 5.2] A folder bound to the top of a repository is bound to `.`.」
        if (part[4] != ".") dest.put(part[4]);
        if (above) {
            if (dest.len > 0) dest.put("/");
            dest.put(inVault[place.length + 1 .. $]);
        }
    }
    return found && dest.len > 0;
}

// 「[Fable 5.2] What the node says is bound, asked and kept. What went wrong, or nothing.」
const(char)[] keepBindings(const(char)[] node) {
    import core.stdc.stdio : fopen, fwrite, fclose, rename, remove;
    import http : httpGet, ToNode;
    __gshared ZBuf url, lines, fresh, why;
    __gshared char[65536] answer;
    why.reset();
    auto at = bindingsFile();
    if (at is null || node.length == 0) return "";
    url.reset();
    url.put(node);
    url.put("/api/vault");
    auto r = httpGet(url.slice(), ToNode(), answer[], 2);
    if (r.status != 200) {
        // 「[Fable 5.2] A node that keeps no vault answers so, and nothing is bound.」
        if (r.status == 404) return "";
        why.put(url.slice());
        why.put(r.status > 0 ? " did not answer what is bound" : " was not reached for what is bound");
        return why.slice();
    }
    bindingsFrom(answer[0 .. r.len], lines);
    size_t n = 0;
    while (at[n] != 0) n++;
    fresh.reset();
    fresh.put(at[0 .. n]);
    fresh.put(".new");
    auto f = fopen(fresh.ptr(), "w");
    bool kept = f !is null && fwrite(lines.ptr(), 1, lines.len, f) == lines.len;
    if (f !is null && fclose(f) != 0) kept = false;
    if (kept) kept = rename(fresh.ptr(), at) == 0;
    if (!kept) {
        remove(fresh.ptr());
        why.put("what the node says is bound was not kept at ");
        why.put(at[0 .. n]);
    }
    return why.slice();
}

// 「[Fable 5.2] The row's contexts for one file: its vault when it is a note of one, with」
// 「[Fable 5.2] the repository's file it is bound to; and its own repository when it is in」
// 「[Fable 5.2] one.」
private void putFile(ref ZBuf contexts, const(char)[] file) {
    const(char)[] vault, inVault;
    if (vaultOf(file, vault, inVault)) {
        contexts.put(`","`);
        contexts.put(VAULT);
        putPath(contexts, vault);
        contexts.put(":");
        putPath(contexts, inVault);

        import core.stdc.stdio : fopen, fread, fclose;
        __gshared char[65536] kept;
        __gshared ZBuf path;
        auto at = bindingsFile();
        auto f = at is null ? null : fopen(at, "r");
        if (f !is null) {
            auto got = fread(kept.ptr, 1, kept.length, f);
            fclose(f);
            const(char)[] repo, branch;
            if (boundTo(kept[0 .. got], vault, inVault, repo, branch, path)) {
                contexts.put(`","`);
                contexts.put(TOUCHED);
                putPath(contexts, repo);
                contexts.put("@");
                putPath(contexts, branch);
                contexts.put(":");
                putPath(contexts, path.slice());
            }
        }
    }
    __gshared Touched one;
    if (touched(file, one)) putContext(contexts, one);
}

// 「[Fable 5.2] One more context of the row, written inside the JSON array as it stands」
// 「[Fable 5.2] open: `","file:owner/repo@commit:path`.」
private void putContext(ref ZBuf contexts, ref const Touched t) {
    contexts.put(`","`);
    contexts.put(TOUCHED);
    contexts.put(t.repo());
    contexts.put("@");
    contexts.put(t.commit());
    contexts.put(":");
    putPath(contexts, t.path());
}

// 「[Fable 5.2] Whether a path names a file that is there.」
private bool isFile(const(char)[] path) {
    import core.sys.posix.sys.stat : stat, stat_t, S_IFMT, S_IFREG;
    if (path.length == 0 || path.length >= 4000) return false;
    char[4096] z = 0;
    foreach (i, c; path) z[i] = c;
    stat_t st;
    return stat(&z[0], &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG;
}

// 「[Fable 5.2] The files a shell command names: each word of it that, read from where the」
// 「[Fable 5.2] command runs, is a file that is there. `cd <dir>` moves where the words」
// 「[Fable 5.2] after it are read from. What a command reaches without naming it, a glob or」
// 「[Fable 5.2] a file a script opens, is not known from the command and is not said.」
size_t namedFiles(const(char)[] command, const(char)[] cwd, ref ZBuf files) {
    import core.stdc.stdlib : getenv;
    files.reset();
    size_t count = 0;

    __gshared ZBuf base;
    base.reset();
    base.put(cwd);
    __gshared ZBuf full;

    // 「[Fable 5.2] A word read from the base: absolute as it is, ~/ from the home.」
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
        // 「[Fable 5.2] One word, a pair of quotes around it or inside it taken off.」
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
        // 「[Fable 5.2] What stands after the equals sign of an assignment is a path too.」
        foreach (i, ch; said) {
            if (ch == '/') break;
            if (ch == '=' && i + 1 < said.length) { said = said[i + 1 .. $]; break; }
        }
        resolve(said);
        if (full.len == 0 || !isFile(full.slice())) continue;
        // 「[Fable 5.2] Once each.」
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

// 「[Fable 5.2] The row's contexts for the files this event's tool touches. Written into」
// 「[Fable 5.2] the array while it stands open, so nothing is written for an event that is」
// 「[Fable 5.2] no tool's, a tool that touches no file, or a file in no repository.」
void putTouched(ref ZBuf contexts, const(char)[] eventName, const(char)[] cwd, const(char)[] payload) {
    import parse : extractToolName, extractFilePath, extractCommand, extractJsonString;
    if (eventName != "PreToolUse" && eventName != "PostToolUse" && eventName != "PostToolUseFailure") return;
    if (payload.length == 0) return;
    auto tool = extractToolName(payload);
    if (tool is null) return;

    if (tool == "Read" || tool == "Edit" || tool == "Write" || tool == "MultiEdit" || tool == "NotebookEdit") {
        auto file = extractFilePath(payload);
        if (file is null) {
            __gshared char[4096] buf = 0;
            file = extractJsonString(payload, `"notebook_path"`, &buf[0], buf.length);
        }
        if (file is null) return;
        putFile(contexts, file);
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
        putFile(contexts, all[at .. end]);
        at = end + 1;
    }
}
