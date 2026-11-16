module gates;

// "so there is no discussion"
// "i need to be able to say gates off"
// "and just have a model cruise"
// A person who says `gates off` in a session lifts every control's gate there:
// no PreToolUse control denies or asks, and no Stop control holds the turn.
// `gates on` puts them back. The latest one said decides, and gates are on
// until one is. Read from the prompts only: an assistant cannot put a row
// where this looks.

private const(char)[] trimmed(const(char)[] s) {
    while (s.length > 0 && (s[0] == ' ' || s[0] == '\n' || s[0] == '\r' || s[0] == '\t')) s = s[1 .. $];
    while (s.length > 0 && (s[$ - 1] == ' ' || s[$ - 1] == '\n' || s[$ - 1] == '\r' || s[$ - 1] == '\t')) s = s[0 .. $ - 1];
    return s;
}

private bool sameFolded(const(char)[] a, const(char)[] b) {
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length) {
        char x = a[i], y = b[i];
        if (x >= 'A' && x <= 'Z') x = cast(char)(x + 32);
        if (y >= 'A' && y <= 'Z') y = cast(char)(y + 32);
        if (x != y) return false;
    }
    return true;
}

bool isGatesOff(const(char)[] prompt) { return sameFolded(trimmed(prompt), "gates off"); }
bool isGatesOn(const(char)[] prompt) { return sameFolded(trimmed(prompt), "gates on"); }

// Prompts newest first: the first `gates off` or `gates on` met decides.
bool gatesOffIn(const(char[])[] prompts) {
    foreach (p; prompts) {
        if (isGatesOff(p)) return true;
        if (isGatesOn(p)) return false;
    }
    return false;
}

// Whether the person said `gates off` last in this session.
bool gatesOff(const(char)[] sessionId) {
    import db : openDb, sqlite3_prepare_v2, sqlite3_bind_text, sqlite3_step, sqlite3_column_text,
                sqlite3_finalize, sqlite3_close, sqlite3_stmt, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT;
    import zbuf : ZBuf;

    if (sessionId.length == 0) return false;
    auto db = openDb();
    if (db is null) return false;

    __gshared ZBuf ctx;
    ctx.reset();
    ctx.put("session:");
    ctx.put(sessionId);

    // Only prompts that are the words alone can decide, so only those are read.
    enum sql = "SELECT json_extract(attributes, '$.prompt') FROM attestations "
        ~ "WHERE json_extract(predicates, '$[0]') IN ('UserPromptSubmit','QueuedPromptSubmit') "
        ~ "AND json_extract(contexts, '$[0]') = ?1 "
        ~ "AND lower(trim(json_extract(attributes, '$.prompt'), ' ' || char(10) || char(13) || char(9))) IN ('gates off','gates on') "
        ~ "ORDER BY rowid DESC LIMIT 1\0";

    bool off = false;
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, ctx.ptr(), cast(int) ctx.len, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            auto text = sqlite3_column_text(stmt, 0);
            if (text !is null) {
                size_t n = 0;
                while (text[n] != 0) n++;
                off = isGatesOff((cast(const(char)*) text)[0 .. n]);
            }
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
    return off;
}
