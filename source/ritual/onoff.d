module ritual.onoff;

// "rituals off should mean totally off"
// A project's rituals are off until a session standing in it says rituals on.

enum Said { Nothing, On, Off }

private bool blank(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

// The whole prompt is the phrase, or it is not the phrase.
Said saidOf(const(char)[] prompt) {
    size_t a = 0, b = prompt.length;
    while (a < b && blank(prompt[a])) a++;
    while (b > a && blank(prompt[b - 1])) b--;
    auto s = prompt[a .. b];
    if (s == "rituals on") return Said.On;
    if (s == "rituals off") return Said.Off;
    return Said.Nothing;
}

// The project a place stands in, by the path its rituals are keyed on. A repo
// a project names outranks every path; otherwise the deepest path wins.
const(char)[] projectAt(PR)(auto ref const PR r, const(char)[] cwd,
                            const(char)[] root, const(char)[] origin) {
    import hooks : pathMatch;

    // Only a path some ritual is keyed on has anything to switch. Wind writes
    // a deeper project block with files and no ritual, and it won here.
    bool keysRitual(const(char)[] p) {
        foreach (i; 0 .. r.ritualCount) if (r.rituals[i].projectPath == p) return true;
        return false;
    }
    if (origin.length > 0)
        foreach (i; 0 .. r.projectCount)
            if (r.projects[i].origin == origin && keysRitual(r.projects[i].path))
                return r.projects[i].path;

    const(char)[] best = "";
    foreach (i; 0 .. r.ritualCount) {
        auto p = r.rituals[i].projectPath;
        if (p.length <= best.length) continue;
        if (pathMatch(cwd, p) || (root.length > 0 && pathMatch(root, p))) best = p;
    }
    return best;
}

// A project with no row was never switched on, and is off.
bool ritualsOn(DB)(DB db, const(char)[] project) {
    import db : sqlite3_stmt, sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_step,
                sqlite3_column_int64, sqlite3_finalize, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    import exec : emitError;
    if (project.length == 0) return false;
    if (db is null) {
        emitError("ritual.switch.read", "the store would not open, so whether rituals are on is unknown and they are off",
                  0, 1, "", cast(string) project, "", "", "");
        return false;
    }

    enum sql = "SELECT enabled FROM ritual_switch WHERE project = ?1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) {
        emitError("ritual.switch.read", "the store would not say whether rituals are on, so they are off",
                  0, 1, "", cast(string) project, "", "", "");
        return false;
    }
    sqlite3_bind_text(stmt, 1, project.ptr, cast(int) project.length, SQLITE_TRANSIENT);
    bool on = sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int64(stmt, 0) != 0;
    sqlite3_finalize(stmt);
    return on;
}

bool setRituals(DB)(DB db, const(char)[] project, bool on, const(char)[] sessionId, long now) {
    import db : sqlite3_stmt, sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_bind_int64,
                sqlite3_step, sqlite3_finalize, SQLITE_OK, SQLITE_DONE, SQLITE_TRANSIENT;
    if (db is null || project.length == 0) return false;

    enum sql = "INSERT OR REPLACE INTO ritual_switch (project, enabled, said_by, said_at) "
        ~ "VALUES (?1, ?2, ?3, ?4)\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return false;
    sqlite3_bind_text(stmt, 1, project.ptr, cast(int) project.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 2, on ? 1 : 0);
    sqlite3_bind_text(stmt, 3, sessionId.ptr, cast(int) sessionId.length, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 4, now);
    bool done = sqlite3_step(stmt) == SQLITE_DONE;
    sqlite3_finalize(stmt);
    return done;
}

private struct Line {
    char[512] buf = 0;
    size_t len;
    void put(const(char)[] s) { foreach (c; s) if (len < buf.length) buf[len++] = c; }
    const(char)[] text() return { return buf[0 .. len]; }
}

// Why a performance of this project does not start, or null when it may.
const(char)[] offBecause(DB)(DB db, const(char)[] project) {
    if (ritualsOn(db, project)) return null;
    __gshared Line why;
    why.len = 0;
    why.put("rituals are off for ");
    why.put(project);
    why.put("; a session there says rituals on to let them fire");
    return why.text();
}

// The same question asked by the ritual's name, as a control names it. A name
// that resolves to nothing is performFromControl's to report.
const(char)[] ritualOff(DB, PR)(DB db, auto ref const PR r, const(char)[] ritualName) {
    import ritual.resolve : chooseRitual;
    auto chosen = chooseRitual(r, ritualName, "");
    if (!chosen.ok) return null;
    return offBecause(db, r.rituals[chosen.ritualIdx].projectPath);
}

// The phrase, acted on, and what it did in one sentence.
size_t switched(DB, PR)(DB db, auto ref const PR r, Said said, const(char)[] cwd,
                        const(char)[] root, const(char)[] origin,
                        const(char)[] sessionId, long now, char[] dest) {
    if (said == Said.Nothing) return 0;
    size_t o = 0;
    void put(const(char)[] s) { foreach (c; s) if (o < dest.length) dest[o++] = c; }
    auto word = said == Said.On ? "rituals on" : "rituals off";

    auto project = projectAt(r, cwd, root, origin);
    if (project.length == 0) {
        put(word);
        put(": no project { } block stands at ");
        put(cwd);
        put(", so nothing was switched");
        return o;
    }
    if (!setRituals(db, project, said == Said.On, sessionId, now)) {
        import exec : emitError;
        emitError("ritual.switch.write", "the store would not take the switch, so nothing was switched",
                  0, 1, cast(string) sessionId, cast(string) project, "", "", "");
        put(word);
        put(" for ");
        put(project);
        put(": the store would not take it, so nothing was switched");
        return o;
    }
    put(word);
    put(" for ");
    put(project);
    if (said == Said.On)
        put(": its rituals fire, for every session there, until one says rituals off");
    else
        put(": no new performance of its rituals starts, for every session there, until one says rituals on; one already running carries on");
    return o;
}
