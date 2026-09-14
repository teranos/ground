module shovel;

import db : openDb, sqlite3, sqlite3_close, sqlite3_prepare_v2, sqlite3_step,
                sqlite3_bind_text, sqlite3_finalize, sqlite3_stmt, sqlite3_column_text,
                sqlite3_column_int64, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT, ZBuf;
import core.stdc.stdio : stdout, stderr, fputs, fwrite, fprintf;

// Event type → attribute field mapping
const(char)[] fieldForEvent(const(char)[] event) {
    if (eq(event, "Stop"))              return "$.last_assistant_message";
    if (eq(event, "UserPromptSubmit"))   return "$.prompt";
    if (eq(event, "PreToolUse"))         return "$.tool_input.command";
    if (eq(event, "PostToolUse"))        return "$.tool_input.command";
    if (eq(event, "PermissionRequest"))  return "$.tool_input.command";
    return null;
}

// Convert wildcard pattern (a*b*c) to SQL LIKE (%a%b%c%)
void patternToLike(ref ZBuf buf, const(char)[] pattern) {
    buf.put("%");
    foreach (c; pattern) {
        if (c == '*') buf.put("%");
        else buf.putChar(c);
    }
    buf.put("%");
}

bool eq(const(char)[] a, const(char)[] b) {
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length)
        if (a[i] != b[i]) return false;
    return true;
}

// Truncate text to maxLen, adding "..." if truncated
void putTruncated(ref ZBuf buf, const(char)[] text, size_t maxLen) {
    if (text.length <= maxLen) {
        buf.put(text);
        return;
    }
    buf.put(text[0 .. maxLen]);
    buf.put("...");
}

void putInt(ref ZBuf buf, long v) {
    char[20] digits = 0;
    int dLen = 0;
    if (v == 0) { digits[0] = '0'; dLen = 1; }
    else { while (v > 0) { digits[dLen++] = cast(char)('0' + v % 10); v /= 10; } }
    foreach (i; 0 .. dLen) buf.putChar(digits[dLen - 1 - i]);
}

// Read session transcript from ~/.claude/projects/*/session_id.jsonl
int handleSessionDump(const(char)[] sessionId) {
    import core.stdc.stdio : fread, fclose, FILE;
    import db : getenv, popen, pclose;

    // Use find to locate the transcript file
    __gshared ZBuf cmd;
    cmd.reset();
    auto home = getenv("HOME\0".ptr);
    if (home is null) { fputs("Cannot determine HOME\n", stderr); return 1; }
    size_t homeLen = 0;
    while (home[homeLen] != 0) homeLen++;

    cmd.put("find ");
    cmd.put(home[0 .. homeLen]);
    cmd.put("/.claude/projects -name '");
    cmd.put(sessionId);
    cmd.put("*.jsonl' -print -quit 2>/dev/null");
    cmd.putChar('\0');

    auto pipe = popen(cmd.ptr(), "r\0".ptr);
    if (pipe is null) { fputs("Cannot search for transcript\n", stderr); return 1; }

    __gshared char[4096] pathBuf = 0;
    size_t pathLen = 0;
    while (pathLen < pathBuf.length - 1) {
        auto n = fread(&pathBuf[pathLen], 1, 1, pipe);
        if (n == 0) break;
        if (pathBuf[pathLen] == '\n') break;
        pathLen++;
    }
    pclose(pipe);

    if (pathLen == 0) {
        fputs("No transcript found for session ", stderr);
        fwrite(sessionId.ptr, 1, sessionId.length, stderr);
        fputs("\n", stderr);
        return 1;
    }

    // Cat the file to stdout
    __gshared ZBuf catCmd;
    catCmd.reset();
    catCmd.put("cat '");
    catCmd.put(pathBuf[0 .. pathLen]);
    catCmd.put("'");
    catCmd.putChar('\0');

    auto catPipe = popen(catCmd.ptr(), "r\0".ptr);
    if (catPipe is null) return 1;

    __gshared char[8192] readBuf = 0;
    while (true) {
        auto n = fread(&readBuf[0], 1, readBuf.length, catPipe);
        if (n == 0) break;
        fwrite(&readBuf[0], 1, n, stdout);
    }
    pclose(catPipe);
    return 0;
}

// BOOK_COMMAND **ground shovel**: Searches past hook events by wildcard pattern, or dumps a session's transcript.
int handleShovel(int argc, const(char)** argv) {
    // ground shovel <event> <pattern>
    // ground shovel session <id>
    if (argc < 4) {
        fputs("Usage: ground shovel <event> <pattern>\n", stderr);
        fputs("       ground shovel session <session_id>\n", stderr);
        fputs("\nEvents: Stop, UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest\n", stderr);
        fputs("Pattern: wildcards with * (e.g. \"curl*http\", \"create*control\")\n", stderr);
        return 1;
    }

    // Extract args as slices
    const(char)[] arg2 = sliceArg(argv[2]);
    const(char)[] arg3 = sliceArg(argv[3]);

    // Session mode
    if (eq(arg2, "session"))
        return handleSessionDump(arg3);

    // Pattern search mode
    auto event = arg2;
    auto pattern = arg3;

    auto field = fieldForEvent(event);
    if (field is null) {
        fputs("Unknown event type: ", stderr);
        fwrite(event.ptr, 1, event.length, stderr);
        fputs("\nSupported: Stop, UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest\n", stderr);
        return 1;
    }

    auto db = openDb();
    if (db is null) { fputs("Cannot open ground db\n", stderr); return 1; }

    // Build LIKE pattern
    __gshared ZBuf likePat;
    likePat.reset();
    patternToLike(likePat, pattern);

    // Query: count + matches grouped by session
    // First: get total count
    __gshared ZBuf countSql;
    countSql.reset();
    countSql.put("SELECT COUNT(*) FROM attestations WHERE predicates = '[\"");
    countSql.put(event);
    countSql.put("\"]' AND json_extract(attributes, '");
    countSql.put(field);
    countSql.put("') LIKE ?1");
    countSql.putChar('\0');

    sqlite3_stmt* countStmt;
    long total = 0;
    if (sqlite3_prepare_v2(db, countSql.ptr(), -1, &countStmt, null) == SQLITE_OK) {
        sqlite3_bind_text(countStmt, 1, likePat.ptr(), cast(int) likePat.len, SQLITE_TRANSIENT);
        if (sqlite3_step(countStmt) == SQLITE_ROW)
            total = sqlite3_column_int64(countStmt, 0);
        sqlite3_finalize(countStmt);
    }

    // Count distinct sessions
    __gshared ZBuf sessionCountSql;
    sessionCountSql.reset();
    sessionCountSql.put("SELECT COUNT(DISTINCT json_extract(attributes, '$.session_id')) FROM attestations WHERE predicates = '[\"");
    sessionCountSql.put(event);
    sessionCountSql.put("\"]' AND json_extract(attributes, '");
    sessionCountSql.put(field);
    sessionCountSql.put("') LIKE ?1");
    sessionCountSql.putChar('\0');

    sqlite3_stmt* sessCountStmt;
    long sessionCount = 0;
    if (sqlite3_prepare_v2(db, sessionCountSql.ptr(), -1, &sessCountStmt, null) == SQLITE_OK) {
        sqlite3_bind_text(sessCountStmt, 1, likePat.ptr(), cast(int) likePat.len, SQLITE_TRANSIENT);
        if (sqlite3_step(sessCountStmt) == SQLITE_ROW)
            sessionCount = sqlite3_column_int64(sessCountStmt, 0);
        sqlite3_finalize(sessCountStmt);
    }

    // Print header
    __gshared ZBuf out_;
    out_.reset();
    putInt(out_, total);
    out_.put(" matches across ");
    putInt(out_, sessionCount);
    out_.put(" sessions\n\n");
    fwrite(out_.ptr(), 1, out_.len, stdout);

    if (total == 0) {
        sqlite3_close(db);
        return 0;
    }

    // Fetch matches grouped by session, ordered by session then rowid
    __gshared ZBuf fetchSql;
    fetchSql.reset();
    fetchSql.put("SELECT json_extract(attributes, '$.session_id'), ");
    fetchSql.put("substr(json_extract(attributes, '");
    fetchSql.put(field);
    fetchSql.put("'), 1, 200), ");
    fetchSql.put("substr(timestamp, 1, 10) ");
    fetchSql.put("FROM attestations WHERE predicates = '[\"");
    fetchSql.put(event);
    fetchSql.put("\"]' AND json_extract(attributes, '");
    fetchSql.put(field);
    fetchSql.put("') LIKE ?1 ");
    fetchSql.put("ORDER BY json_extract(attributes, '$.session_id'), rowid ASC");
    fetchSql.putChar('\0');

    sqlite3_stmt* fetchStmt;
    if (sqlite3_prepare_v2(db, fetchSql.ptr(), -1, &fetchStmt, null) != SQLITE_OK) {
        sqlite3_close(db);
        return 1;
    }
    sqlite3_bind_text(fetchStmt, 1, likePat.ptr(), cast(int) likePat.len, SQLITE_TRANSIENT);

    const(char)[] prevSession = null;
    __gshared char[64] prevSessionBuf = 0;
    size_t prevSessionLen = 0;

    while (sqlite3_step(fetchStmt) == SQLITE_ROW) {
        auto sessionPtr = sqlite3_column_text(fetchStmt, 0);
        auto textPtr = sqlite3_column_text(fetchStmt, 1);
        auto datePtr = sqlite3_column_text(fetchStmt, 2);
        if (textPtr is null) continue;

        auto session = cstr(sessionPtr);
        auto text = cstr(textPtr);
        auto date = cstr(datePtr);

        // New session group?
        auto shortSession = session.length >= 8 ? session[0 .. 8] : session;
        auto prevShort = prevSessionBuf[0 .. prevSessionLen];
        if (!eq(shortSession, prevShort)) {
            // Print session header
            __gshared ZBuf hdr;
            hdr.reset();
            if (prevSessionLen > 0) hdr.put("\n");
            hdr.put("[");
            hdr.put(shortSession);
            if (date.length > 0) {
                hdr.put(" — ");
                hdr.put(date);
            }
            hdr.put("]\n");
            fwrite(hdr.ptr(), 1, hdr.len, stdout);

            // Update prev session
            foreach (i; 0 .. shortSession.length)
                prevSessionBuf[i] = shortSession[i];
            prevSessionLen = shortSession.length;
        }

        // Print match line — collapse newlines to spaces
        __gshared ZBuf line;
        line.reset();
        line.put("- ");
        size_t charCount = 0;
        foreach (c; text) {
            if (charCount >= 180) { line.put("..."); break; }
            if (c == '\n' || c == '\r') { line.putChar(' '); charCount++; }
            else { line.putChar(c); charCount++; }
        }
        line.put("\n");
        fwrite(line.ptr(), 1, line.len, stdout);
    }

    sqlite3_finalize(fetchStmt);
    sqlite3_close(db);
    return 0;
}

const(char)[] sliceArg(const(char)* ptr) {
    if (ptr is null) return null;
    size_t len = 0;
    while (ptr[len] != 0) len++;
    return ptr[0 .. len];
}

const(char)[] cstr(const(char)* ptr) {
    if (ptr is null) return null;
    size_t len = 0;
    while (ptr[len] != 0) len++;
    return ptr[0 .. len];
}

// --- Tests ---

unittest {
    // patternToLike: simple word
    ZBuf buf;
    patternToLike(buf, "curl");
    assert(buf.slice() == "%curl%");
}

unittest {
    // patternToLike: wildcard pattern
    ZBuf buf;
    patternToLike(buf, "test*curl*http");
    assert(buf.slice() == "%test%curl%http%");
}

unittest {
    // fieldForEvent: known events
    assert(fieldForEvent("Stop") == "$.last_assistant_message");
    assert(fieldForEvent("UserPromptSubmit") == "$.prompt");
    assert(fieldForEvent("PreToolUse") == "$.tool_input.command");
    assert(fieldForEvent("Unknown") is null);
}
