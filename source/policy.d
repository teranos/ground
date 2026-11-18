module policy;

// "Which policy a session ran under. ground records what a session did, but not
// which version of the global CLAUDE.md it was given. Without that, nothing can
// be compared before and after a change."
// "this is something i want"
//
// 「[Opus 5.5] At every SessionStart (startup, resume, clear, compact) each CLAUDE.md」
// 「[Opus 5.5] Claude Code gives the session is hashed. A session gets a row when a」
// 「[Opus 5.5] file's hash is not the one it last had for that file; each text is kept」
// 「[Opus 5.5] once under its hash. Both go to the node as attestations, the way」
// 「[Opus 5.5] session:model does (sessionmodel.d), so k holds every version beside what」
// 「[Opus 5.5] the sessions under it did.」

import db : sqlite3, sqlite3_stmt, sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_bind_int64,
            sqlite3_step, sqlite3_finalize, sqlite3_column_text, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;

// 「[Opus 5.5] The files, as paths: the global one, then a CLAUDE.md in each directory」
// 「[Opus 5.5] from the root down to where the session starts.」
struct PolicyFiles {
    char[8192] buf = 0;
    size_t used;
    size_t[64] at;
    size_t[64] len;
    size_t count;
    const(char)[] opIndex(size_t i) const return { return buf[at[i] .. at[i] + len[i]]; }
    void add(const(char)[] dir, const(char)[] file) {
        if (count >= at.length || used + dir.length + file.length > buf.length) return;
        at[count] = used;
        foreach (c; dir) buf[used++] = c;
        foreach (c; file) buf[used++] = c;
        len[count] = used - at[count];
        count++;
    }
}

PolicyFiles policyFiles(const(char)[] home, const(char)[] cwd) {
    PolicyFiles f;
    if (home.length > 0) f.add(home, "/.claude/CLAUDE.md");
    if (cwd.length == 0 || cwd[0] != '/') return f;
    f.add("", "/CLAUDE.md");
    foreach (i; 1 .. cwd.length + 1) {
        if (i == cwd.length || cwd[i] == '/') f.add(cwd[0 .. i], "/CLAUDE.md");
    }
    return f;
}

// 「[Opus 5.5] Writes down that `session` runs under `text` at `path`, and says whether」
// 「[Opus 5.5] that was new for it.」
bool keepPolicy(sqlite3* db, const(char)[] session, const(char)[] path, const(char)[] text, long now) {
    import sha256 : Sha256;
    Sha256 h;
    h.put(cast(const(ubyte)[]) text);
    char[64] hex;
    h.hexInto(hex);
    const(char)[] hash = hex[];

    sqlite3_stmt* stmt;
    bool bind(const(char)[] sql) {
        if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return false;
        sqlite3_bind_text(stmt, 1, session.ptr, cast(int) session.length, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, path.ptr, cast(int) path.length, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 3, hash.ptr, cast(int) hash.length, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt, 4, now);
        sqlite3_bind_text(stmt, 5, text.ptr, cast(int) text.length, SQLITE_TRANSIENT);
        return true;
    }
    void run(const(char)[] sql) {
        if (!bind(sql)) return;
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }

    // 「[Opus 5.5] The same text the session last had for this file is no change.」
    if (bind("SELECT hash FROM session_policy WHERE session = ?1 AND path = ?2 ORDER BY id DESC LIMIT 1\0")) {
        bool same = false;
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            auto had = cast(const(char)*) sqlite3_column_text(stmt, 0);
            if (had !is null) {
                size_t n = 0;
                while (had[n] != 0) n++;
                same = had[0 .. n] == hash;
            }
        }
        sqlite3_finalize(stmt);
        if (same) return false;
    }

    run("INSERT OR IGNORE INTO policy_text (hash, text, first_at, first_path) "
        ~ "VALUES (?3, ?5, ?4, ?2)\0");
    run("INSERT INTO session_policy (session, path, hash, since) VALUES (?1, ?2, ?3, ?4)\0");
    run("INSERT OR IGNORE INTO attestations "
        ~ "(id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES ("
        ~ "'ground:session-policy:' || ?1 || ':' || ?4 || ':' || ?3, json_array('session:' || ?1), "
        ~ "'[\"session:policy\"]', json_array('session:' || ?1), '[\"ground\"]', "
        ~ "strftime('%Y-%m-%dT%H:%M:%SZ', ?4, 'unixepoch'), 'ground', "
        ~ "json_object('path', ?2, 'hash', ?3, 'since', ?4))\0");
    run("INSERT OR IGNORE INTO attestations "
        ~ "(id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES ("
        ~ "'ground:policy-text:' || ?3, json_array('policy:' || ?3), '[\"policy:text\"]', "
        ~ "json_array('policy:' || ?3), '[\"ground\"]', "
        ~ "strftime('%Y-%m-%dT%H:%M:%SZ', ?4, 'unixepoch'), 'ground', "
        ~ "json_object('hash', ?3, 'path', ?2, 'text', ?5))\0");
    return true;
}

// 「[Opus 5.5] At SessionStart: every file of policyFiles that exists, read whole and」
// 「[Opus 5.5] kept. A file that will not read is passed over; the rest are still kept.」
size_t keepPoliciesAt(sqlite3* db, const(char)[] session, const(char)[] home, const(char)[] cwd, long now) {
    import core.stdc.stdio : fopen, fread, fclose;
    auto files = policyFiles(home, cwd);
    size_t kept = 0;
    __gshared char[262144] text = 0;
    foreach (i; 0 .. files.count) {
        char[4100] z = 0;
        auto p = files[i];
        if (p.length >= z.length) continue;
        z[0 .. p.length] = p[];
        auto f = fopen(z.ptr, "rb");
        if (f is null) continue;
        auto n = fread(text.ptr, 1, text.length, f);
        fclose(f);
        if (keepPolicy(db, session, p, text[0 .. n], now)) kept++;
    }
    return kept;
}
