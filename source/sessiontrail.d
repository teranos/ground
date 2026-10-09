module sessiontrail;

// "when documentation get's edited by you … when that get's comitted, that in the commit itself is inserted the session id"
// "the way provenance governs quotes, but i want to expand it to agent prose as well"

// A commit carries a `session:` trailer for every session that edited a staged
// file since that file was last committed. Ground writes them; nobody types one.

import db : sqlite3;

private struct Word {
    const(char)[] raw;    // as typed, quotes and all
    const(char)[] value;  // with one pair of surrounding quotes taken off
    size_t end;           // where it ends in the command
}

// The next shell word from `at`, or a raw of length 0 at the end.
private Word nextWord(const(char)[] cmd, size_t at) {
    while (at < cmd.length && (cmd[at] == ' ' || cmd[at] == '\t')) at++;
    size_t start = at;
    char quote = 0;
    while (at < cmd.length) {
        auto c = cmd[at];
        if (quote != 0) { if (c == quote) quote = 0; at++; continue; }
        if (c == '\'' || c == '"') { quote = c; at++; continue; }
        if (c == ' ' || c == '\t' || c == ';' || c == '&' || c == '|') break;
        at++;
    }
    auto raw = cmd[start .. at];
    auto value = raw;
    if (value.length >= 2 && (value[0] == '\'' || value[0] == '"') && value[$ - 1] == value[0])
        value = value[1 .. $ - 1];
    return Word(raw, value, at);
}

private struct Found {
    bool ok;
    const(char)[] tree;   // what -C named, or empty
    size_t afterCommit;   // where `commit` ends
}

// `git`, its own options, then `commit` as a word of its own.
private Found findCommit(const(char)[] cmd) {
    Found f;
    size_t at = 0;
    for (;;) {
        // `;`, `&&` and `|` end one command and start the next.
        while (at < cmd.length && (cmd[at] == ';' || cmd[at] == '&' || cmd[at] == '|'
                                   || cmd[at] == ' ' || cmd[at] == '\t')) at++;
        auto w = nextWord(cmd, at);
        if (w.raw.length == 0) return f;
        at = w.end;
        if (w.value != "git") continue;
        const(char)[] tree;
        for (;;) {
            auto o = nextWord(cmd, at);
            if (o.raw.length == 0) break;
            at = o.end;
            if (o.value == "-C" || o.value == "-c") {
                auto arg = nextWord(cmd, at);
                at = arg.end;
                if (o.value == "-C") tree = arg.value;
                continue;
            }
            if (o.value.length > 0 && o.value[0] == '-') continue;
            if (o.value == "commit") return Found(true, tree, o.end);
            break;
        }
    }
}

bool isCommit(const(char)[] cmd) { return findCommit(cmd).ok; }

// The tree the commit is made in.
const(char)[] treeOf(const(char)[] cmd, const(char)[] cwd) {
    auto f = findCommit(cmd);
    return f.ok && f.tree.length > 0 ? f.tree : cwd;
}

// The command with a `--trailer 'session: <id>'` per session, right after
// `commit`. No sessions is the command as typed.
const(char)[] withTrailers(const(char)[] cmd, const(char[])[] sessions) {
    auto f = findCommit(cmd);
    if (!f.ok || sessions.length == 0) return cmd;
    __gshared char[65536] buf = 0;
    size_t n;
    bool fits = true;
    void put(const(char)[] s) { foreach (c; s) { if (n < buf.length) buf[n++] = c; else fits = false; } }
    put(cmd[0 .. f.afterCommit]);
    foreach (s; sessions) {
        put(" --trailer 'session: ");
        put(s);
        put("'");
    }
    put(cmd[f.afterCommit .. $]);
    return fits ? buf[0 .. n] : cmd;
}

struct Editors {
    char[64][32] ids = 0;
    size_t[32] lens;
    long[32] lastAt;          // the session's last edit, unix seconds
    char[160][32] labels = 0; // what its trailer says, once described
    size_t[32] labelLens;
    size_t count;
    bool over;
    const(char)[] at(size_t i) const return { return ids[i][0 .. lens[i]]; }
    const(char)[] label(size_t i) const return {
        return labelLens[i] > 0 ? labels[i][0 .. labelLens[i]] : at(i);
    }
    const(char)[] labelOf(const(char)[] id) const return {
        foreach (i; 0 .. count) if (at(i) == id) return label(i);
        return null;
    }
    bool has(const(char)[] id) const {
        foreach (i; 0 .. count) if (at(i) == id) return true;
        return false;
    }
    void add(const(char)[] id, long when = 0) {
        if (id.length == 0) return;
        foreach (i; 0 .. count) {
            if (at(i) != id) continue;
            if (when > lastAt[i]) lastAt[i] = when;
            return;
        }
        if (count >= ids.length || id.length > ids[0].length) { over = true; return; }
        foreach (i, c; id) ids[count][i] = c;
        lens[count] = id.length;
        lastAt[count] = when;
        count++;
    }
}

// "yes, add the model and also the effort that was used"
// Each session's trailer names the model and effort in force at its last edit.
void describe(sqlite3* db, ref Editors found) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_bind_int64, sqlite3_column_text, sqlite3_stmt,
                SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;

    enum sql = "SELECT model, effort FROM session_model WHERE session = ?1 AND since <= ?2 "
        ~ "ORDER BY id DESC LIMIT 1\0";
    foreach (i; 0 .. found.count) {
        sqlite3_stmt* stmt;
        if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) { found.over = true; return; }
        auto id = found.at(i);
        sqlite3_bind_text(stmt, 1, id.ptr, cast(int) id.length, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt, 2, found.lastAt[i]);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            size_t n;
            void put(const(char)[] s) { foreach (c; s) if (n < found.labels[i].length) found.labels[i][n++] = c; }
            void putText(int col) {
                auto t = sqlite3_column_text(stmt, col);
                if (t is null) return;
                for (size_t k = 0; t[k] != 0; k++) put((cast(const(char)*) t)[k .. k + 1]);
            }
            put(id);
            put(" (");
            putText(0);
            auto effort = sqlite3_column_text(stmt, 1);
            if (effort !is null && effort[0] != 0) {
                put(", ");
                putText(1);
            }
            put(")");
            found.labelLens[i] = n;
        }
        sqlite3_finalize(stmt);
    }
}

// The path an edit's record names, whole or after decay. The index on it is
// partial on PostToolUse, so a query must say both alike.
enum EDIT_PATH = "coalesce(json_extract(attributes, '$.tool_input.file_path'), json_extract(attributes, '$.file_path'))";
enum EDIT_INDEX = "CREATE INDEX IF NOT EXISTS idx_attestations_edit_path ON attestations(" ~ EDIT_PATH
    ~ ") WHERE json_extract(predicates, '$[0]') = 'PostToolUse'\0";

// Every session that edited `path` after `since`, in unix seconds.
Editors editorsSince(sqlite3* db, const(char)[] path, long since) {
    Editors found;
    collectEditors(db, path, since, found);
    return found;
}

// The same, added to what is already found.
void collectEditors(sqlite3* db, const(char)[] path, long since, ref Editors found) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_bind_int64, sqlite3_column_text, sqlite3_stmt,
                SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;

    enum sql = "SELECT substr(json_extract(contexts, '$[0]'), 9), "
        ~ "MAX(CAST(strftime('%s', timestamp) AS INTEGER)) FROM attestations "
        ~ "WHERE json_extract(predicates, '$[0]') = 'PostToolUse' AND " ~ EDIT_PATH ~ " = ?1 "
        ~ "AND json_extract(attributes, '$.tool_name') IN ('Edit', 'Write', 'NotebookEdit') "
        ~ "AND timestamp > strftime('%Y-%m-%dT%H:%M:%SZ', ?2, 'unixepoch') GROUP BY 1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) { found.over = true; return; }
    sqlite3_bind_text(stmt, 1, path.ptr, cast(int) path.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 2, since);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        auto t = sqlite3_column_text(stmt, 0);
        if (t is null) continue;
        size_t len = 0;
        while (t[len] != 0) len++;
        import db : sqlite3_column_int64;
        found.add((cast(const(char)*) t)[0 .. len], sqlite3_column_int64(stmt, 1));
    }
    sqlite3_finalize(stmt);
}

// How many paths one asking of the store carries.
enum EDITORS_AT_ONCE = 256;

// The asking for `count` paths, NUL-terminated in `into`.
const(char)[] editorsAllSql(size_t count, char[] into) {
    size_t n;
    void put(const(char)[] s) { foreach (c; s) into[n++] = c; }
    put("WITH p(i, path, since) AS (VALUES ");
    foreach (k; 0 .. count) put(k == 0 ? "(?,?,?)" : ",(?,?,?)");
    put(") SELECT p.i, substr(json_extract(contexts, '$[0]'), 9), "
        ~ "MAX(CAST(strftime('%s', timestamp) AS INTEGER)) FROM p CROSS JOIN attestations "
        ~ "WHERE json_extract(predicates, '$[0]') = 'PostToolUse' AND " ~ EDIT_PATH ~ " = p.path "
        ~ "AND json_extract(attributes, '$.tool_name') IN ('Edit', 'Write', 'NotebookEdit') "
        ~ "AND timestamp > strftime('%Y-%m-%dT%H:%M:%SZ', p.since, 'unixepoch') "
        ~ "GROUP BY 1, 2 ORDER BY 1, 2");
    into[n] = 0;
    return into[0 .. n];
}

// Every session that edited one of `paths` after that path's own `since`, in
// one asking: by path, then by session, the order asking path by path gave.
void collectEditorsAll(sqlite3* db, const(char[])[] paths, const(long)[] sinces, ref Editors found) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_text,
                sqlite3_bind_int64, sqlite3_column_text, sqlite3_column_int64, sqlite3_stmt,
                SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    if (paths.length == 0) return;
    if (paths.length > EDITORS_AT_ONCE || sinces.length != paths.length) { found.over = true; return; }

    __gshared char[EDITORS_AT_ONCE * 8 + 1024] sql = 0;
    editorsAllSql(paths.length, sql[]);

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, &sql[0], -1, &stmt, null) != SQLITE_OK) { found.over = true; return; }
    foreach (k, path; paths) {
        sqlite3_bind_int64(stmt, cast(int) (k * 3 + 1), cast(long) k);
        sqlite3_bind_text(stmt, cast(int) (k * 3 + 2), path.ptr, cast(int) path.length, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt, cast(int) (k * 3 + 3), sinces[k]);
    }
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        auto t = sqlite3_column_text(stmt, 1);
        if (t is null) continue;
        size_t len = 0;
        while (t[len] != 0) len++;
        found.add((cast(const(char)*) t)[0 .. len], sqlite3_column_int64(stmt, 2));
    }
    sqlite3_finalize(stmt);
}

// The sessions behind what is staged in the commit's tree. libgit2 reads the
// tree in this process; no git program runs.
Editors sessionsForCommit(sqlite3* db, const(char)[] command, const(char)[] cwd) {
    import libgit2 : Repo, GIT_ENOTFOUND;
    import exec : emitError;
    Editors found;
    auto tree = treeOf(command, cwd);

    Repo g;
    if (!g.open(tree)) {
        // No repository is no commit: git refuses it on its own.
        if (g.code != GIT_ENOTFOUND)
            emitError("provenance.repo", cast(string) g.why(), 0, 1, "", "provenance", "", cast(string) command, "");
        return found;
    }
    scope (exit) g.close();
    auto root = g.root();
    if (root.length == 0) return found;

    __gshared char[1 << 20] staged = 0;
    auto names = g.staged(staged[]);
    if (names is null) {
        emitError("provenance.staged", cast(string) g.why(), 0, 1, "", "provenance", "", cast(string) command, "");
        found.over = true;
        return found;
    }

    __gshared char[2048][EDITORS_AT_ONCE] pathBufs;
    __gshared const(char)[][EDITORS_AT_ONCE] paths;
    __gshared long[EDITORS_AT_ONCE] sinces;
    size_t held;

    size_t start = 0;
    foreach (i; 0 .. names.length + 1) {
        if (i < names.length && names[i] != '\n') continue;
        auto name = names[start .. i];
        start = i + 1;
        if (name.length == 0) continue;

        auto last = g.lastTouched(name);
        if (!last.ok)
            emitError("provenance.history", cast(string) g.why(), 0, 1, "", "provenance", "", cast(string) name, "");

        size_t pn;
        foreach (c; root) if (pn < pathBufs[held].length) pathBufs[held][pn++] = c;
        if (pn < pathBufs[held].length) pathBufs[held][pn++] = '/';
        foreach (c; name) if (pn < pathBufs[held].length) pathBufs[held][pn++] = c;
        paths[held] = pathBufs[held][0 .. pn];
        sinces[held] = last.since;
        if (++held == EDITORS_AT_ONCE) {
            collectEditorsAll(db, paths[0 .. held], sinces[0 .. held], found);
            held = 0;
        }
    }
    collectEditorsAll(db, paths[0 .. held], sinces[0 .. held], found);
    describe(db, found);
    return found;
}
