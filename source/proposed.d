module proposed;

// "YOU NEED TO CREATE 1 CONTROL, THAT CONTROL STOPS YOU FROM EDITING THE CONTROLS."
// "we catch what the model wanted to put in there"
// "and place it as a commented block"
// "in my obsidian"
// "i still want the intelligence"
// "so i want everything, (keep the governance) and more (know how it wanted to modify its own governance)"
//
// 「[Fable 5.2] An agent refused a write to a control (a .pbt) does not lose what it wrote: the」
// 「[Fable 5.2] text is kept as an attestation, control:proposed, and appended, every line」
// 「[Fable 5.2] commented, to one note of the vault the control's repository is bound in, at」
// 「[Fable 5.2] the binding's place. The operator reads it there and authors what they will.」

import zbuf : ZBuf;
import db : sqlite3;

// The note, at the place the control's repository is bound at.
enum NOTE = "Ways the agents wanted to author their own rules.md";

// What a kept proposal is attested as.
enum PROPOSED_PREDICATE = "control:proposed";

// The most of one proposal that is kept: what a hook reads of a write.
enum PROPOSAL_MOST = 32_768;

// What a block is built in: a proposal, each line two bytes longer, and its heading.
struct Block {
    char[2 * PROPOSAL_MOST + 4096] data = 0;
    size_t len;
    void reset() { len = 0; }
    void put(const(char)[] s) { foreach (c; s) if (len < data.length) data[len++] = c; }
    const(char)[] slice() const return { return data[0 .. len]; }
}

// A control, by its name: the vault's note of one (X.pbt.md) is not one.
bool isControl(const(char)[] path) {
    return path.length > 4 && path[$ - 4 .. $] == ".pbt";
}

// Every line of text with "# " before it, so it is read and never runs.
void commentedInto(R)(const(char)[] text, ref R dest) {
    size_t at = 0;
    while (at < text.length) {
        auto end = at;
        while (end < text.length && text[end] != '\n') end++;
        dest.put(end > at ? "# " : "#");
        dest.put(text[at .. end]);
        dest.put("\n");
        at = end + 1;
    }
}

// One proposal as the note holds it: when, which control, whose session, and
// the text commented inside a fence.
void blockInto(R)(ref R dest, const(char)[] stamp, const(char)[] session,
                  const(char)[] repo, const(char)[] inRepo, const(char)[] text) {
    dest.put("\n## ");
    dest.put(stamp);
    dest.put(" · ");
    dest.put(inRepo);
    dest.put("\n\n");
    dest.put(repo);
    dest.put(", session ");
    dest.put(session);
    dest.put("\n\n```\n");
    commentedInto(text, dest);
    dest.put("```\n");
}

// The vault and place a file of a repository is bound at, from the lines
// ground keeps of its node's bindings (touch.d): the repository whole, or the
// folder the file is in. The longest path bound wins.
bool placeOf(const(char)[] lines, const(char)[] repo, const(char)[] inRepo,
             out const(char)[] vault, ref ZBuf place) {
    place.reset();
    bool found = false;
    size_t best = 0;
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
        if (part[2] != repo) continue;
        auto bound = part[4];
        bool whole = bound == ".";
        bool under = inRepo.length > bound.length + 1 && inRepo[0 .. bound.length] == bound
            && inRepo[bound.length] == '/';
        if (!whole && !under) continue;
        auto weight = whole ? 1 : bound.length + 1;
        if (found && weight <= best) continue;
        found = true;
        best = weight;
        vault = part[0];
        place.reset();
        place.put(part[1]);
    }
    return found;
}

// ---- where a vault is on this machine ----

// A vault's directory here, from the lines ground keeps: <name> TAB <root>.
// Empty when ground has not seen the vault on this machine.
const(char)[] rootOf(const(char)[] lines, const(char)[] name) {
    size_t at = 0;
    while (at < lines.length) {
        auto end = at;
        while (end < lines.length && lines[end] != '\n') end++;
        auto line = lines[at .. end];
        at = end + 1;
        size_t tab = 0;
        while (tab < line.length && line[tab] != '\t') tab++;
        if (tab == line.length) continue;
        if (line[0 .. tab] == name) return line[tab + 1 .. $];
    }
    return "";
}

// ~/.local/share/ground/vaults: each vault ground has seen a note of, and its
// directory on this machine. A vault is the directory that holds .obsidian
// (touch.d), so ground learns one the first time a session touches a note of it.
const(char)* vaultsFile() {
    import db : storeDir;
    __gshared ZBuf path;
    path.reset();
    auto dir = storeDir();
    if (dir is null) return null;
    path.put(dir);
    path.put("/vaults");
    return path.ptr();
}

private size_t readInto(const(char)* path, char[] dest) {
    import core.stdc.stdio : fopen, fread, fclose;
    if (path is null) return 0;
    auto f = fopen(path, "r");
    if (f is null) return 0;
    auto n = fread(dest.ptr, 1, dest.length, f);
    fclose(f);
    return n;
}

// A vault seen at root: written down once.
void learnVault(const(char)[] name, const(char)[] root) {
    import core.stdc.stdio : fopen, fwrite, fclose;
    if (name.length == 0 || root.length == 0) return;
    __gshared char[16384] kept = 0;
    auto at = vaultsFile();
    if (at is null) return;
    auto n = readInto(at, kept[]);
    if (rootOf(kept[0 .. n], name) == root) return;
    auto f = fopen(at, "a");
    if (f is null) return;
    fwrite(name.ptr, 1, name.length, f);
    fwrite("\t".ptr, 1, 1, f);
    fwrite(root.ptr, 1, root.length, f);
    fwrite("\n".ptr, 1, 1, f);
    fclose(f);
}

// ---- keeping one ----

// The proposal appended to the note of the vault its repository is bound in.
// The note's path, or empty when the repository is bound nowhere or the vault
// has not been seen on this machine.
const(char)[] keepIn(const(char)[] bindings, const(char)[] vaults, const(char)[] repo,
                     const(char)[] inRepo, const(char)[] text, const(char)[] session,
                     const(char)[] stamp) {
    import core.stdc.stdio : fopen, fwrite, fclose, ftell, fseek, SEEK_END;

    const(char)[] vault;
    __gshared ZBuf place;
    if (!placeOf(bindings, repo, inRepo, vault, place)) return "";
    auto root = rootOf(vaults, vault);
    if (root.length == 0) return "";

    __gshared char[8192] path = 0;
    size_t n = 0;
    void put(const(char)[] s) { foreach (c; s) if (n < path.length - 1) path[n++] = c; }
    put(root);
    put("/");
    put(place.slice());
    put("/");
    put(NOTE);
    path[n] = 0;

    auto f = fopen(path.ptr, "a");
    if (f is null) return "";
    fseek(f, 0, SEEK_END);
    if (ftell(f) == 0) {
        enum head = "What agents tried to write into the controls and were refused. "
            ~ "Each is as it was written, commented out; none of it runs.\n";
        fwrite(head.ptr, 1, head.length, f);
    }
    __gshared Block b;
    b.reset();
    blockInto(b, stamp, session, repo, inRepo, text);
    fwrite(b.data.ptr, 1, b.len, f);
    fclose(f);
    return path[0 .. n];
}

// Text as it stands inside a JSON string: the quote, the backslash and every
// control character, a newline among them, escaped.
private void jsonInto(const(char)[] s, char[] dst, ref size_t n) {
    enum hex = "0123456789abcdef";
    void put(const(char)[] t) { foreach (c; t) if (n < dst.length) dst[n++] = c; }
    foreach (c; s) {
        switch (c) {
            case '"': put(`\"`); break;
            case '\\': put(`\\`); break;
            case '\n': put(`\n`); break;
            case '\r': put(`\r`); break;
            case '\t': put(`\t`); break;
            default:
                if (cast(ubyte) c < 0x20) {
                    char[6] u = ['\\', 'u', '0', '0', hex[(c >> 4) & 0xf], hex[c & 0xf]];
                    put(u[]);
                } else {
                    char[1] one = [c];
                    put(one[]);
                }
        }
    }
}

// The proposal as a row of the store, control:proposed: the control's path and
// the text as written. True only when the row is there to be read.
bool keepInStore(sqlite3* db, const(char)[] file, const(char)[] text, const(char)[] session,
                 const(char)[] cwd) {
    import db : attestEvent, sqlite3_stmt, sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_step,
        sqlite3_finalize, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    __gshared char[6 * PROPOSAL_MOST + 8192] payload = 0;
    size_t n = 0;
    void put(const(char)[] s) { foreach (c; s) if (n < payload.length) payload[n++] = c; }
    put(`{"path":"`);
    jsonInto(file, payload[], n);
    put(`","text":"`);
    jsonInto(text, payload[], n);
    put(`"}`);
    attestEvent(db, PROPOSED_PREDICATE, cwd, session, payload[0 .. n]);

    enum q = "SELECT 1 FROM attestations WHERE json_extract(predicates, '$[0]') = 'control:proposed' "
        ~ "AND json_extract(contexts, '$[0]') = 'session:' || ?1 "
        ~ "AND json_extract(attributes, '$.path') = ?2 AND json_extract(attributes, '$.text') = ?3 LIMIT 1\0";
    sqlite3_stmt* st;
    if (sqlite3_prepare_v2(db, q.ptr, -1, &st, null) != SQLITE_OK) return false;
    sqlite3_bind_text(st, 1, session.ptr, cast(int) session.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, file.ptr, cast(int) file.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, text.ptr, cast(int) text.length, SQLITE_TRANSIENT);
    auto there = sqlite3_step(st) == SQLITE_ROW;
    sqlite3_finalize(st);
    return there;
}

// A refused write to a control, kept: attested, and put in the vault. What the
// refusal says after its own words, so the agent knows it was kept and where.
const(char)[] keepProposal(const(char)[] file, const(char)[] text, const(char)[] session,
                           const(char)[] cwd) {
    import touch : touched, Touched, bindingsFile;
    import db : openDb, sqlite3_close, formatTimestamp;

    __gshared ZBuf said;
    said.reset();
    if (text.length > PROPOSAL_MOST) text = text[0 .. PROPOSAL_MOST];

    // The store first: the proposal is data whether or not a vault takes it.
    {
        auto db = openDb();
        if (db !is null) {
            if (keepInStore(db, file, text, session, cwd)) said.put(" What you wrote is kept as a proposal");
            sqlite3_close(db);
        }
    }

    // The control may not exist yet, and its folder may be a link into the
    // repository that holds it: the folder is resolved, the name kept.
    __gshared char[4200] resolvedFile = 0;
    {
        import core.sys.posix.stdlib : realpath;
        size_t slash = file.length;
        while (slash > 0 && file[slash - 1] != '/') slash--;
        if (slash > 1 && file.length < 4000) {
            char[4096] dir = 0;
            foreach (i, c; file[0 .. slash - 1]) dir[i] = c;
            char[4096] whole = 0;
            if (realpath(&dir[0], &whole[0]) !is null) {
                size_t n = 0;
                while (whole[n] != 0) { resolvedFile[n] = whole[n]; n++; }
                resolvedFile[n++] = '/';
                foreach (c; file[slash .. $]) resolvedFile[n++] = c;
                file = resolvedFile[0 .. n];
            }
        }
    }

    __gshared Touched t;
    __gshared char[65536] bindings = 0;
    __gshared char[16384] vaults = 0;
    auto bn = readInto(bindingsFile(), bindings[]);
    auto vn = readInto(vaultsFile(), vaults[]);
    if (touched(file, t)) {
        // A binding made since the session started is not in what ground kept
        // of them: the node is asked again before the repository is called unbound.
        {
            const(char)[] v;
            __gshared ZBuf pl;
            if (!placeOf(bindings[0 .. bn], t.repo(), t.path(), v, pl)) {
                import touch : keepBindings;
                import nodeconfig : nodeHere;
                auto here = nodeHere();
                if (here.sandUrl.length > 0) {
                    cast(void) keepBindings(here.sandUrl);
                    bn = readInto(bindingsFile(), bindings[]);
                }
            }
        }
        auto note = keepIn(bindings[0 .. bn], vaults[0 .. vn], t.repo(), t.path(), text, session,
                           formatTimestamp());
        if (note.length > 0) {
            said.put(said.len > 0 ? ", and for the operator to read in " : " What you wrote is kept for the operator to read in ");
            said.put(note);
        }
    }
    if (said.len > 0) said.put(". Do not write it elsewhere.");
    return said.slice();
}
