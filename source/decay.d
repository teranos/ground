module decay;

import db : sqlite3, sqlite3_exec, sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize,
            sqlite3_bind_text, sqlite3_column_text, sqlite3_column_int64, sqlite3_changes,
            sqlite3_stmt, sqlite3_close, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT, ZBuf;
import core.stdc.stdio : stderr, fputs, fprintf, fwrite;

enum BOOK_COMMAND = q"EOS
# strip the bulk out of the db (make install does):
ground decay
EOS";

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

    // 3. Delete timing rows > 30 days, once sentry has them. Unshipped rows
    // are the record still, and the watcher ships them in its own time.
    enum deleteTiming = "DELETE FROM timing WHERE created_at < datetime('now', '-30 days') AND shipped_at > 0\0";
    sqlite3_exec(db, deleteTiming.ptr, null, null, null);
    auto timingDeleted = sqlite3_changes(db);

    // 4. Immediate rows nobody claimed in seven days, and their receipts. A
    // row is pending until a session marks it delivered, and a session that
    // ended marks nothing — so every row ever written to a session that is
    // gone stayed pending and was walked again by every sky every two seconds.
    // 11,297 of them on 2026-09-22, 695ms a pass, with each PreToolUse queued
    // behind it. The receipts go first: they name the row, and a receipt for a
    // row that is gone is a row nobody can read either.
    enum deleteReceipts = "DELETE FROM attestations WHERE json_extract(predicates, '$[0]') LIKE 'delivered:%' "
        ~ "AND substr(json_extract(predicates, '$[0]'), 11) IN ("
        ~ "SELECT id FROM attestations WHERE json_extract(predicates, '$[0]') >= 'immediate:' "
        ~ "AND json_extract(predicates, '$[0]') < 'immediate;' AND created_at < datetime('now', '-7 days'))\0";
    sqlite3_exec(db, deleteReceipts.ptr, null, null, null);
    auto receiptsDeleted = sqlite3_changes(db);
    enum deleteImmediate = "DELETE FROM attestations WHERE json_extract(predicates, '$[0]') >= 'immediate:' "
        ~ "AND json_extract(predicates, '$[0]') < 'immediate;' AND created_at < datetime('now', '-7 days')\0";
    sqlite3_exec(db, deleteImmediate.ptr, null, null, null);
    auto immediateDeleted = sqlite3_changes(db);

    // VACUUM to reclaim space
    sqlite3_exec(db, "VACUUM\0".ptr, null, null, null);

    long afterSize = dbPageSize(db);

    // Stats
    fprintf(stderr, "ground decay: %d PostToolUse/PreToolUse stripped, %d SubagentStop stripped, %d timing deleted, %d immediate deleted with %d receipts\n".ptr,
        toolUseDecayed, subagentDecayed, timingDeleted, immediateDeleted, receiptsDeleted);
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

    // The product schema, not a copy of it: a copy drifts.
    {
        import db : applySchema;
        assert(applySchema(db));
    }

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

    // Insert old timing (40 days ago), shipped, and one as old that never was
    enum oldTiming = "INSERT INTO timing (duration_us, hook_event, created_at, shipped_at) "
        ~ "VALUES (1000, 'PostToolUse', datetime('now', '-40 days'), 1)\0";
    sqlite3_exec(db, oldTiming.ptr, null, null, null);
    enum oldUnshipped = "INSERT INTO timing (duration_us, hook_event, created_at) "
        ~ "VALUES (1500, 'PostToolUse', datetime('now', '-40 days'))\0";
    sqlite3_exec(db, oldUnshipped.ptr, null, null, null);

    // Insert recent timing (5 days ago)
    enum recentTiming = "INSERT INTO timing (duration_us, hook_event, created_at) "
        ~ "VALUES (2000, 'PostToolUse', datetime('now', '-5 days'))\0";
    sqlite3_exec(db, recentTiming.ptr, null, null, null);

    // An immediate row nobody claimed in ten days, its receipt, and one from
    // an hour ago. A pending row is proven pending by the absence of a receipt
    // in every session, so a session that ended leaves its rows pending for
    // ever, and every sky reads them again every two seconds.
    enum oldImmediate = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes, created_at) "
        ~ "VALUES ('imm-old', '[\"x\"]', '[\"immediate:note\"]', '[\"session:gone\"]', '[\"ground\"]', "
        ~ "'2025-01-01T00:00:00Z', 'ground', '{\"detail\":\"old\",\"after\":0}', datetime('now', '-10 days'))\0";
    sqlite3_exec(db, oldImmediate.ptr, null, null, null);
    enum oldReceipt = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes, created_at) "
        ~ "VALUES ('delivered:imm-old:other', '[\"x\"]', '[\"delivered:imm-old\"]', '[\"session:other\"]', '[\"ground\"]', "
        ~ "'2025-01-01T00:00:00Z', 'ground', '{}', datetime('now', '-10 days'))\0";
    sqlite3_exec(db, oldReceipt.ptr, null, null, null);
    enum newImmediate = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes, created_at) "
        ~ "VALUES ('imm-new', '[\"x\"]', '[\"immediate:note\"]', '[\"session:here\"]', '[\"ground\"]', "
        ~ "'2025-01-01T00:00:00Z', 'ground', '{\"detail\":\"new\",\"after\":0}', datetime('now', '-1 hour'))\0";
    sqlite3_exec(db, newImmediate.ptr, null, null, null);

    // Run decay
    decayDb(db);

    // Verify: the old immediate row and its receipt are gone, the new one stays
    {
        enum sql = "SELECT count(*) FROM attestations WHERE id IN ('imm-old', 'delivered:imm-old:other')\0";
        sqlite3_stmt* stmt;
        assert(sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK);
        assert(sqlite3_step(stmt) == SQLITE_ROW);
        assert(sqlite3_column_int64(stmt, 0) == 0, "an immediate row nobody claimed in a week is history, not mail");
        sqlite3_finalize(stmt);
    }
    {
        enum sql = "SELECT count(*) FROM attestations WHERE id = 'imm-new'\0";
        sqlite3_stmt* stmt;
        assert(sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK);
        assert(sqlite3_step(stmt) == SQLITE_ROW);
        assert(sqlite3_column_int64(stmt, 0) == 1, "a recent immediate row is still pending");
        sqlite3_finalize(stmt);
    }

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

    // Verify: old shipped timing deleted; the recent one and the old one
    // sentry never got are kept
    {
        enum sql = "SELECT count(*) FROM timing\0";
        sqlite3_stmt* stmt;
        assert(sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK);
        assert(sqlite3_step(stmt) == SQLITE_ROW);
        assert(sqlite3_column_int64(stmt, 0) == 2, "unshipped is not thrown away");
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
