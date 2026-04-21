module decay;

import db : sqlite3, sqlite3_exec, sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize,
            sqlite3_bind_text, sqlite3_column_text, sqlite3_column_int64, sqlite3_changes,
            sqlite3_stmt, sqlite3_close, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT, ZBuf;
import core.stdc.stdio : stderr, fputs, fprintf, fwrite;

int decayDb(sqlite3* db) {
    // Get before stats
    long beforeToolUse = countRows(db, "PostToolUse");
    long beforePreToolUse = countRows(db, "PreToolUse");
    long beforeSubagent = countRows(db, "SubagentStop");
    long beforeSize = dbPageSize(db);

    // 1. Strip PostToolUse/PreToolUse attributes > 7 days
    enum stripToolUse = "UPDATE attestations SET attributes = json_object("
        ~ "'tool_name', json_extract(attributes, '$.tool_name'), "
        ~ "'file_path', json_extract(attributes, '$.tool_input.file_path'), "
        ~ "'command', json_extract(attributes, '$.tool_input.command'), "
        ~ "'original_size', length(attributes), "
        ~ "'decayed', 1"
        ~ ") WHERE json_extract(predicates, '$[0]') IN ('PostToolUse', 'PreToolUse') "
        ~ "AND created_at < datetime('now', '-7 days') "
        ~ "AND json_extract(attributes, '$.decayed') IS NULL\0";

    sqlite3_exec(db, stripToolUse.ptr, null, null, null);
    auto toolUseDecayed = sqlite3_changes(db);

    // 2. Strip SubagentStop attributes > 7 days
    enum stripSubagent = "UPDATE attestations SET attributes = json_object("
        ~ "'session_id', json_extract(attributes, '$.session_id'), "
        ~ "'original_size', length(attributes), "
        ~ "'decayed', 1"
        ~ ") WHERE json_extract(predicates, '$[0]') = 'SubagentStop' "
        ~ "AND created_at < datetime('now', '-7 days') "
        ~ "AND json_extract(attributes, '$.decayed') IS NULL\0";

    sqlite3_exec(db, stripSubagent.ptr, null, null, null);
    auto subagentDecayed = sqlite3_changes(db);

    // 3. Delete timing rows > 30 days
    enum deleteTiming = "DELETE FROM timing WHERE created_at < datetime('now', '-30 days')\0";
    sqlite3_exec(db, deleteTiming.ptr, null, null, null);
    auto timingDeleted = sqlite3_changes(db);

    // VACUUM to reclaim space
    sqlite3_exec(db, "VACUUM\0".ptr, null, null, null);

    long afterSize = dbPageSize(db);

    // Stats
    fprintf(stderr, "ground decay: %d PostToolUse/PreToolUse stripped, %d SubagentStop stripped, %d timing deleted\n".ptr,
        toolUseDecayed, subagentDecayed, timingDeleted);
    fprintf(stderr, "ground decay: db %ldKB -> %ldKB\n".ptr, beforeSize / 1024, afterSize / 1024);

    return 0;
}

long countRows(sqlite3* db, const(char)[] predicate) {
    enum sql = "SELECT count(*) FROM attestations WHERE json_extract(predicates, '$[0]') = ?1 AND json_extract(attributes, '$.decayed') IS NULL\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return 0;
    sqlite3_bind_text(stmt, 1, predicate.ptr, cast(int) predicate.length, SQLITE_TRANSIENT);
    long count = 0;
    if (sqlite3_step(stmt) == SQLITE_ROW)
        count = sqlite3_column_int64(stmt, 0);
    sqlite3_finalize(stmt);
    return count;
}

long dbPageSize(sqlite3* db) {
    // page_count * page_size = total bytes
    enum sql = "SELECT page_count * page_size FROM pragma_page_count, pragma_page_size\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return 0;
    long size = 0;
    if (sqlite3_step(stmt) == SQLITE_ROW)
        size = sqlite3_column_int64(stmt, 0);
    sqlite3_finalize(stmt);
    return size;
}

// --- Tests ---

unittest {
    import db : sqlite3_open;

    // In-memory db for testing
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);

    // Create schema
    enum schema = "CREATE TABLE attestations ("
        ~ "id TEXT PRIMARY KEY, subjects JSON, predicates JSON, "
        ~ "contexts JSON, actors JSON, timestamp DATETIME, "
        ~ "source TEXT, attributes JSON, "
        ~ "created_at DATETIME DEFAULT CURRENT_TIMESTAMP)\0";
    sqlite3_exec(db, schema.ptr, null, null, null);

    enum timingSchema = "CREATE TABLE timing ("
        ~ "id INTEGER PRIMARY KEY, duration_us INTEGER, hook_event TEXT, "
        ~ "created_at DATETIME DEFAULT CURRENT_TIMESTAMP)\0";
    sqlite3_exec(db, timingSchema.ptr, null, null, null);

    // Insert old PostToolUse (10 days ago)
    enum oldPostToolUse = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes, created_at) "
        ~ "VALUES ('old-ptu', '[\"test\"]', '[\"PostToolUse\"]', '[\"session:1\"]', '[\"ground\"]', "
        ~ "'2025-01-01T00:00:00Z', 'ground', "
        ~ "'{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"},\"tool_result\":\"big output here\"}', "
        ~ "datetime('now', '-10 days'))\0";
    sqlite3_exec(db, oldPostToolUse.ptr, null, null, null);

    // Insert recent PostToolUse (1 day ago)
    enum recentPostToolUse = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes, created_at) "
        ~ "VALUES ('recent-ptu', '[\"test\"]', '[\"PostToolUse\"]', '[\"session:1\"]', '[\"ground\"]', "
        ~ "'2025-01-01T00:00:00Z', 'ground', "
        ~ "'{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/tmp/f\"},\"tool_result\":\"contents\"}', "
        ~ "datetime('now', '-1 day'))\0";
    sqlite3_exec(db, recentPostToolUse.ptr, null, null, null);

    // Insert old GroundedPostToolUse (10 days ago) — should NOT be touched
    enum oldGrounded = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes, created_at) "
        ~ "VALUES ('old-grounded', '[\"test\"]', '[\"GroundedPostToolUse\"]', '[\"session:1\"]', '[\"ground\"]', "
        ~ "'2025-01-01T00:00:00Z', 'ground', "
        ~ "'{\"control\":\"file-read\"}', "
        ~ "datetime('now', '-10 days'))\0";
    sqlite3_exec(db, oldGrounded.ptr, null, null, null);

    // Insert old SubagentStop (10 days ago)
    enum oldSubagent = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes, created_at) "
        ~ "VALUES ('old-sub', '[\"test\"]', '[\"SubagentStop\"]', '[\"session:1\"]', '[\"ground\"]', "
        ~ "'2025-01-01T00:00:00Z', 'ground', "
        ~ "'{\"session_id\":\"abc\",\"large_payload\":\"tons of data\"}', "
        ~ "datetime('now', '-10 days'))\0";
    sqlite3_exec(db, oldSubagent.ptr, null, null, null);

    // Insert old timing (40 days ago)
    enum oldTiming = "INSERT INTO timing (duration_us, hook_event, created_at) "
        ~ "VALUES (1000, 'PostToolUse', datetime('now', '-40 days'))\0";
    sqlite3_exec(db, oldTiming.ptr, null, null, null);

    // Insert recent timing (5 days ago)
    enum recentTiming = "INSERT INTO timing (duration_us, hook_event, created_at) "
        ~ "VALUES (2000, 'PostToolUse', datetime('now', '-5 days'))\0";
    sqlite3_exec(db, recentTiming.ptr, null, null, null);

    // Run decay
    decayDb(db);

    // Verify: old PostToolUse was decayed
    {
        enum sql = "SELECT json_extract(attributes, '$.decayed') FROM attestations WHERE id = 'old-ptu'\0";
        sqlite3_stmt* stmt;
        assert(sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK);
        assert(sqlite3_step(stmt) == SQLITE_ROW);
        assert(sqlite3_column_int64(stmt, 0) == 1);
        sqlite3_finalize(stmt);
    }

    // Verify: old PostToolUse kept tool_name
    {
        enum sql = "SELECT json_extract(attributes, '$.tool_name') FROM attestations WHERE id = 'old-ptu'\0";
        sqlite3_stmt* stmt;
        assert(sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK);
        assert(sqlite3_step(stmt) == SQLITE_ROW);
        auto text = sqlite3_column_text(stmt, 0);
        assert(text !is null);
        size_t tLen = 0;
        while (text[tLen] != 0) tLen++;
        assert((cast(const(char)*) text)[0 .. tLen] == "Bash");
        sqlite3_finalize(stmt);
    }

    // Verify: old PostToolUse lost tool_result
    {
        enum sql = "SELECT json_extract(attributes, '$.tool_result') FROM attestations WHERE id = 'old-ptu'\0";
        sqlite3_stmt* stmt;
        assert(sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK);
        assert(sqlite3_step(stmt) == SQLITE_ROW);
        // tool_result should be null (stripped)
        assert(sqlite3_column_text(stmt, 0) is null);
        sqlite3_finalize(stmt);
    }

    // Verify: recent PostToolUse NOT decayed
    {
        enum sql = "SELECT json_extract(attributes, '$.decayed') FROM attestations WHERE id = 'recent-ptu'\0";
        sqlite3_stmt* stmt;
        assert(sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK);
        assert(sqlite3_step(stmt) == SQLITE_ROW);
        // decayed should be null (not set)
        assert(sqlite3_column_text(stmt, 0) is null);
        sqlite3_finalize(stmt);
    }

    // Verify: GroundedPostToolUse NOT decayed
    {
        enum sql = "SELECT json_extract(attributes, '$.control') FROM attestations WHERE id = 'old-grounded'\0";
        sqlite3_stmt* stmt;
        assert(sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK);
        assert(sqlite3_step(stmt) == SQLITE_ROW);
        auto text = sqlite3_column_text(stmt, 0);
        assert(text !is null); // control field still present
        sqlite3_finalize(stmt);
    }

    // Verify: old SubagentStop was decayed, kept session_id
    {
        enum sql = "SELECT json_extract(attributes, '$.decayed'), json_extract(attributes, '$.session_id') FROM attestations WHERE id = 'old-sub'\0";
        sqlite3_stmt* stmt;
        assert(sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK);
        assert(sqlite3_step(stmt) == SQLITE_ROW);
        assert(sqlite3_column_int64(stmt, 0) == 1);
        auto sid = sqlite3_column_text(stmt, 1);
        assert(sid !is null);
        sqlite3_finalize(stmt);
    }

    // Verify: old timing deleted, recent kept
    {
        enum sql = "SELECT count(*) FROM timing\0";
        sqlite3_stmt* stmt;
        assert(sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK);
        assert(sqlite3_step(stmt) == SQLITE_ROW);
        assert(sqlite3_column_int64(stmt, 0) == 1); // only the recent one
        sqlite3_finalize(stmt);
    }

    // Verify: idempotent — run again, no more changes
    decayDb(db);
    {
        enum sql = "SELECT json_extract(attributes, '$.original_size') FROM attestations WHERE id = 'old-ptu'\0";
        sqlite3_stmt* stmt;
        assert(sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK);
        assert(sqlite3_step(stmt) == SQLITE_ROW);
        // original_size should still be from first decay, not re-decayed
        auto origSize = sqlite3_column_int64(stmt, 0);
        assert(origSize > 0);
        sqlite3_finalize(stmt);
    }

    sqlite3_close(db);
}
