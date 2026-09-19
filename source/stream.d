module stream;

// "today we send data to our own sqlite that we also run decay on"
// "tomorrow i want to send the exact same data to both our local sqlite and also qntx at the same time"
// "by default i dont want to send the tooloutput, in the ground sqlite keep keep (fuller) data longer"
//
// Every attestation a hook writes goes to the QNTX node as well, by the sky,
// one POST per row, under ground's own id — the node is idempotent on it, so
// a lost answer is safe to send again. The row goes as it is, except the
// attributes of the three payload-carrying events, which go as decay leaves
// them: tool_name, file_path, command, original_size. The tool output stays
// in the local store for its decay period and never leaves the machine.
//
// A row's place in the stream is qntx_at, the way an outbox item's is
// shipped_at: 0 pending, -pid claimed by that sky, a unix time when the node
// had it. BEFORE_STREAM marks the rows that were there when the stream began;
// they are never claimed. qntx_status is the last answer: the HTTP status, or
// -code for a transfer libcurl could not make.

import db : sqlite3, sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_bind_int64,
            sqlite3_bind_text, sqlite3_column_text, sqlite3_column_int64, sqlite3_changes,
            sqlite3_stmt, SQLITE_OK, SQLITE_ROW, SQLITE_TRANSIENT, ZBuf;

// "today will be the day of recording to parquet, so its a clean slate in that regard"
// A unix second no post ever lands at, so a reader of "landed" (> BEFORE_STREAM)
// and of "claimed" (< 0) is never fooled by it.
enum BEFORE_STREAM = 1;

// How many rows one pass takes. A pass is one sky's turn between deliveries,
// and each row is a round trip to the node.
enum TAKE = 10;

// A 2xx landed and a 4xx is the row's or the token's, and asking again changes
// neither; the 4xx row stays pending with its status, for a person to read.
// No answer, a code below zero and a 5xx are asked again after the backoff.
bool retryable(int status) {
    return status < 200 || status >= 500;
}

// The attributes a row is posted with, in the same words decay uses on the
// local copy, so what the node holds and what the store keeps after seven
// days are one shape.
enum SKELETON_SQL = "CASE json_extract(predicates, '$[0]') "
    ~ "WHEN 'PostToolUse' THEN json_object('tool_name', json_extract(attributes, '$.tool_name'), "
    ~   "'file_path', json_extract(attributes, '$.tool_input.file_path'), "
    ~   "'command', json_extract(attributes, '$.tool_input.command'), "
    ~   "'original_size', length(attributes)) "
    ~ "WHEN 'PreToolUse' THEN json_object('tool_name', json_extract(attributes, '$.tool_name'), "
    ~   "'file_path', json_extract(attributes, '$.tool_input.file_path'), "
    ~   "'command', json_extract(attributes, '$.tool_input.command'), "
    ~   "'original_size', length(attributes)) "
    ~ "WHEN 'SubagentStop' THEN json_object('session_id', json_extract(attributes, '$.session_id'), "
    ~   "'original_size', length(attributes)) "
    ~ "ELSE attributes END";

// Claim up to TAKE pending rows for this sky. Any sky takes any row: the
// UPDATE is the race, and sqlite runs one at a time.
long claimStream(sqlite3* db, long pid) {
    enum sql = "UPDATE attestations SET qntx_at = -?1 WHERE rowid IN (SELECT rowid FROM attestations "
        ~ "WHERE qntx_at = 0 AND NOT (qntx_status >= 400 AND qntx_status < 500) ORDER BY rowid LIMIT ?2)\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return 0;
    sqlite3_bind_int64(stmt, 1, pid);
    sqlite3_bind_int64(stmt, 2, TAKE);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return sqlite3_changes(db);
}

// One claimed row as the node takes it: the body to POST, and the row it is.
struct Claimed {
    long rowid;
    ZBuf body_;
}

// The next claimed row of this sky into `c`, false when there are none left.
// The body is built by sqlite: the id, the four slots, the timestamp as unix
// seconds, the source, and the attributes as SKELETON_SQL leaves them.
bool nextClaimed(sqlite3* db, long pid, long after, ref Claimed c) {
    enum sql = "SELECT rowid, json_object('id', id, 'subjects', json(subjects), 'predicates', json(predicates), "
        ~ "'contexts', json(contexts), 'actors', json(actors), "
        ~ "'timestamp', CAST(strftime('%s', timestamp) AS INTEGER), 'source', source, "
        ~ "'attributes', json(" ~ SKELETON_SQL ~ ")) "
        ~ "FROM attestations WHERE qntx_at = -?1 AND rowid > ?2 ORDER BY rowid LIMIT 1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return false;
    sqlite3_bind_int64(stmt, 1, pid);
    sqlite3_bind_int64(stmt, 2, after);
    bool found = false;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        c.rowid = sqlite3_column_int64(stmt, 0);
        c.body_.reset();
        auto text = sqlite3_column_text(stmt, 1);
        if (text !is null) {
            size_t n = 0;
            while (text[n] != 0) n++;
            c.body_.put((cast(const(char)*) text)[0 .. n]);
            found = true;
        }
    }
    sqlite3_finalize(stmt);
    return found;
}

// What the node answered for one row. Landed: the time. Not landed: the row
// is pending again, carrying the status; a 4xx keeps it out of the next claim.
void rowResolved(sqlite3* db, long rowid, int status, bool landed, long now) {
    enum sql = "UPDATE attestations SET qntx_at = ?1, qntx_status = ?2 WHERE rowid = ?3\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return;
    sqlite3_bind_int64(stmt, 1, landed ? now : 0);
    sqlite3_bind_int64(stmt, 2, status);
    sqlite3_bind_int64(stmt, 3, rowid);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

// Rows still claimed by this sky when its pass ends are handed back.
void claimReleased(sqlite3* db, long pid) {
    enum sql = "UPDATE attestations SET qntx_at = 0 WHERE qntx_at = -?1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return;
    sqlite3_bind_int64(stmt, 1, pid);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

// A claim held by a sky that is gone is nobody's; BEFORE_STREAM is positive
// and never a claim.
long releaseDeadClaims(sqlite3* db, bool function(long) alive) {
    import outbox : releaseDead;
    return releaseDead!("attestations", "qntx_at")(db, alive);
}

// How many rows wait, and how many carry a 4xx nobody will retry.
struct Standing {
    long pending;
    long refused;
}

Standing standing(sqlite3* db) {
    Standing s;
    enum sql = "SELECT SUM(qntx_at = 0 AND NOT (qntx_status >= 400 AND qntx_status < 500)), "
        ~ "SUM(qntx_at = 0 AND qntx_status >= 400 AND qntx_status < 500) "
        ~ "FROM attestations WHERE qntx_at <= 0\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return s;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        s.pending = sqlite3_column_int64(stmt, 0);
        s.refused = sqlite3_column_int64(stmt, 1);
    }
    sqlite3_finalize(stmt);
    return s;
}

// One pass: claim, post each, resolve each. Rows a pass could not post go
// back. Returns false when the node did not take a row for a reason that
// asking again may change, which is what the caller backs off on.
bool streamPass(sqlite3* db, const(char)[] url, const(char)[] token, long pid, long now,
                ref int lastStatus, ref long posted) {
    import http : httpPost;
    import db : sqlite3_exec;

    if (claimStream(db, pid) == 0) return true;

    __gshared ZBuf endpoint;
    endpoint.reset();
    endpoint.put(url);
    endpoint.put("/api/attestations");

    bool ok = true;
    long after = 0;
    __gshared Claimed c;
    while (nextClaimed(db, pid, after, c)) {
        after = c.rowid;
        auto r = httpPost(endpoint.slice(), c.body_.slice(), token, 10);
        auto status = r.status > 0 ? r.status : -r.code;
        auto landed = r.status >= 200 && r.status < 300;
        rowResolved(db, c.rowid, status, landed, now);
        lastStatus = status;
        if (landed) { posted++; continue; }
        if (retryable(r.status)) { ok = false; break; }
    }
    claimReleased(db, pid);
    return ok;
}

unittest {
    import db : sqlite3_open, sqlite3_close, sqlite3_exec, applySchema, attestEventAt;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    assert(claimStream(db, 111) == 0, "nothing written is nothing pending");

    // A PostToolUse row with its output whole, and a Stop row.
    attestEventAt(db, "PostToolUse", "/tmp", "sess-s",
        `{"session_id":"sess-s","tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_response":{"stdout":"a very long listing"}}`,
        "2026-09-19T09:03:25Z", 34348);
    attestEventAt(db, "Stop", "/tmp", "sess-s", `{"session_id":"sess-s","stop_hook_active":false}`,
        "2026-09-19T09:03:26Z", 34349);

    assert(claimStream(db, 111) == 2);
    assert(claimStream(db, 222) == 0, "a second sky finds nothing left to claim");

    // The body is ground's row as the node takes it.
    Claimed c;
    assert(nextClaimed(db, 111, 0, c));
    auto body_ = c.body_.slice();
    assert(contains(body_, `"id":"ground:payload:PostToolUse:2026-09-19T09:03:25Z:34348"`));
    assert(contains(body_, `"predicates":["PostToolUse"]`));
    assert(contains(body_, `"contexts":["session:sess-s"]`));
    assert(contains(body_, `"actors":["ground"]`));
    assert(contains(body_, `"timestamp":1789808605`), "the second as a number, as the node reads it");
    // "by default i dont want to send the tooloutput"
    assert(contains(body_, `"tool_name":"Bash"`));
    assert(contains(body_, `"command":"ls -la"`));
    assert(contains(body_, `"original_size":`));
    assert(!contains(body_, "a very long listing"), "the output stays home");
    assert(!contains(body_, "tool_response"));

    Claimed d;
    assert(nextClaimed(db, 111, c.rowid, d));
    assert(contains(d.body_.slice(), `"stop_hook_active":false`), "everything else goes whole");
    Claimed e;
    assert(!nextClaimed(db, 111, d.rowid, e));

    // Landed is the time; refused by the node is pending with its status and
    // out of the next claim; unreachable is pending and claimed again.
    rowResolved(db, c.rowid, 201, true, 5000);
    rowResolved(db, d.rowid, 403, false, 5000);
    assert(claimStream(db, 111) == 0, "a 4xx is not asked again");
    rowResolved(db, d.rowid, 503, false, 5000);
    assert(claimStream(db, 111) == 1, "a 5xx is");
    claimReleased(db, 111);

    auto s = standing(db);
    assert(s.pending == 1 && s.refused == 0);
    rowResolved(db, d.rowid, 400, false, 5000);
    s = standing(db);
    assert(s.pending == 0 && s.refused == 1);

    // A claim by a sky that died is freed; a landed row and a BEFORE_STREAM
    // row are not claims and are not touched.
    rowResolved(db, d.rowid, 0, false, 0);
    assert(claimStream(db, 333) == 1);
    static bool nobody(long) { return false; }
    assert(releaseDeadClaims(db, &nobody) == 1);
    assert(claimStream(db, 444) == 1, "claimable again");
    sqlite3_close(db);
}

unittest {
    assert(retryable(0), "no answer");
    assert(retryable(-7), "libcurl could not connect");
    assert(retryable(500));
    assert(retryable(503));
    assert(!retryable(400));
    assert(!retryable(403));
    assert(!retryable(201), "landed is not retried either; it is done");
}

version (unittest)
private bool contains(const(char)[] hay, const(char)[] needle) {
    if (needle.length > hay.length) return false;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle) return true;
    return false;
}
