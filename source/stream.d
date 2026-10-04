module stream;

// "today we send data to our own sqlite that we also run decay on"
// "tomorrow i want to send the exact same data to both our local sqlite and also qntx at the same time"
// "by default i dont want to send the tooloutput, in the ground sqlite keep keep (fuller) data longer"
//
// Every attestation a hook writes goes to the QNTX node as well, by the sky,
// a pass's rows as one list in one POST, each under ground's own id — the
// node is idempotent on it, so a lost answer is safe to send again. The row
// goes as it is, except the attributes of the three payload-carrying events,
// which go as decay leaves them: tool_name, file_path, command, original_size. The tool output stays
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

// The node refuses a request body larger than this: maxAttestationBody in
// QNTX's server/attestation_handlers.go.
enum NODE_BODY_CAP = 10 * 1024 * 1024;

// "4 can wait for longer even, up to 5m, and be gentle with sending at the start until it catches up"
enum STREAM_WAIT_FIRST = 60;
enum STREAM_WAIT_MOST = 300;

// How much a sky sends and how long it waits. A pass takes `take` rows; one
// the node answered doubles it while the pass was full, and one it did not
// answer puts it back to one row and doubles the wait, up to 5m.
struct Pace {
    long take = 1;
    long wait;
    bool toldAtMost;
}

void paceLanded(ref Pace p, bool grow) {
    if (grow) p.take *= 2;
    p.wait = 0;
    p.toldAtMost = false;
}

// True once per outage: when the wait first reaches 5m. Sentry hears then.
// "Does not need to be told this often, deploy's are commonplace, so this is expected to happen a lot."
bool paceFailed(ref Pace p) {
    p.take = 1;
    if (p.wait == 0) p.wait = STREAM_WAIT_FIRST;
    else p.wait = p.wait * 2 > STREAM_WAIT_MOST ? STREAM_WAIT_MOST : p.wait * 2;
    if (p.wait < STREAM_WAIT_MOST || p.toldAtMost) return false;
    p.toldAtMost = true;
    return true;
}

// A 2xx landed and a 4xx is the row's or the token's, and asking again changes
// neither; the 4xx row stays pending with its status, for a person to read.
// No answer, a code below zero and a 5xx are asked again after the backoff,
// and so is a 429: the node saying come back later.
// "it should be retryable"
enum TOO_MANY = 429;

bool retryable(int status) {
    return status < 200 || status >= 500 || status == TOO_MANY;
}

// The rows a 4xx keeps out of the stream, in SQL: every 4xx but a 429.
enum REFUSED_SQL = "(qntx_status >= 400 AND qntx_status < 500 AND qntx_status != 429)";

// The attributes a row is posted with, in the same words decay uses on the
// local copy, so what the node holds and what the store keeps after seven
// days are one shape.
enum SKELETON_SQL = "CASE json_extract(predicates, '$[0]') "
    ~ "WHEN 'PostToolUse' THEN json_object('tool_name', json_extract(attributes, '$.tool_name'), "
    ~   "'file_path', json_extract(attributes, '$.tool_input.file_path'), "
    ~   "'command', json_extract(attributes, '$.tool_input.command'), "
    ~   "'original_size', length(attributes), "
    ~   "'duration_ms', json_extract(attributes, '$.duration_ms')) "
    ~ "WHEN 'PreToolUse' THEN json_object('tool_name', json_extract(attributes, '$.tool_name'), "
    ~   "'file_path', json_extract(attributes, '$.tool_input.file_path'), "
    ~   "'command', json_extract(attributes, '$.tool_input.command'), "
    ~   "'original_size', length(attributes)) "
    ~ "WHEN 'SubagentStop' THEN json_object('session_id', json_extract(attributes, '$.session_id'), "
    ~   "'original_size', length(attributes)) "
    ~ "ELSE attributes END";

// Claim up to `take` pending rows for this sky. Any sky takes any row: the
// UPDATE is the race, and sqlite runs one at a time.
//
// The read inside runs under the write lock, so it has to go by the index.
// idx_attestations_stream is partial, qntx_at <= 0, and a WHERE that says
// only qntx_at = 0 does not prove that to the planner: it walked every row
// of the table, 480 thousand of them, from each sky every two seconds, and
// every hook waited its busy timeout behind it. Sentry showed the day it
// began, 2026-09-21, the day the stream landed.
// "PreToolUse really used to run under 50ms"
enum CLAIM_SQL = "UPDATE attestations SET qntx_at = -?1 WHERE rowid IN (SELECT rowid FROM attestations "
    ~ "WHERE qntx_at <= 0 AND qntx_at = 0 AND NOT " ~ REFUSED_SQL ~ " ORDER BY rowid LIMIT ?2)";

unittest {
    import db : sqlite3_open, sqlite3_close, applySchema, sqlite3_column_text;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    enum plan = "EXPLAIN QUERY PLAN " ~ CLAIM_SQL ~ "\0";
    sqlite3_stmt* stmt;
    assert(sqlite3_prepare_v2(db, plan.ptr, -1, &stmt, null) == SQLITE_OK);
    sqlite3_bind_int64(stmt, 1, 1);
    sqlite3_bind_int64(stmt, 2, 10);
    bool byIndex = false;
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        auto text = sqlite3_column_text(stmt, 3);
        size_t n = 0;
        while (text[n] != 0) n++;
        auto detail = (cast(const(char)*) text)[0 .. n];
        assert(!contains(detail, "SCAN attestations"), "the claim walked the whole table under the write lock");
        if (contains(detail, "idx_attestations_stream")) byIndex = true;
    }
    sqlite3_finalize(stmt);
    assert(byIndex, "the claim reads by idx_attestations_stream");
    sqlite3_close(db);
}

long claimStream(sqlite3* db, long pid, long take) {
    enum sql = CLAIM_SQL ~ "\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return 0;
    sqlite3_bind_int64(stmt, 1, pid);
    sqlite3_bind_int64(stmt, 2, take);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return sqlite3_changes(db);
}

// A row's body, whole. A hook's payload is at most readStdin's 256KB, and the
// envelope around it is small, so a row always fits; `over` says when one did
// not, and such a row is not posted cut. The body went through a 4096-byte
// buffer for a week: 89 rows reached the node cut mid-JSON and were refused.
enum STREAM_BODY_CAP = 262_144 + 16_384;

struct Body {
    char[STREAM_BODY_CAP] data = 0;
    size_t len;
    bool over;
    void reset() { len = 0; over = false; }
    void put(const(char)[] s) {
        foreach (c; s) { if (len < data.length) data[len++] = c; else over = true; }
    }
    const(char)[] slice() const return { return data[0 .. len]; }
}

// One claimed row as the node takes it: the body to POST, and the row it is.
struct Claimed {
    long rowid;
    Body body_;
}

// The next claimed row of this sky into `c`, false when there are none left.
// The body is built by sqlite: the id, the four slots, the timestamp as unix
// seconds, the source, and the attributes as SKELETON_SQL leaves them.
enum NEXT_CLAIMED_SQL = "SELECT rowid, json_object('id', id, 'subjects', json(subjects), 'predicates', json(predicates), "
    ~ "'contexts', json(contexts), 'actors', json(actors), "
    ~ "'timestamp', CAST(strftime('%s', timestamp) AS INTEGER), 'source', source, "
    ~ "'attributes', json(" ~ SKELETON_SQL ~ ")) "
    ~ "FROM attestations WHERE qntx_at <= 0 AND qntx_at = -?1 AND rowid > ?2 ORDER BY rowid LIMIT 1\0";

bool nextClaimed(sqlite3* db, long pid, long after, ref Claimed c) {
    enum sql = NEXT_CLAIMED_SQL;
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

// How much of the node's reason is kept on the row.
enum REASON_CAP = 300;

// What the node answered for one row. Landed: the time. Not landed: the row
// is pending again, carrying the status and the node's words for it; a 4xx
// keeps it out of the next claim.
void rowResolved(sqlite3* db, long rowid, int status, bool landed, long now,
                 const(char)[] reason = "") {
    enum sql = "UPDATE attestations SET qntx_at = ?1, qntx_status = ?2, qntx_reason = ?4 WHERE rowid = ?3\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return;
    if (reason.length > REASON_CAP) reason = reason[0 .. REASON_CAP];
    sqlite3_bind_int64(stmt, 1, landed ? now : 0);
    sqlite3_bind_int64(stmt, 2, status);
    sqlite3_bind_int64(stmt, 3, rowid);
    sqlite3_bind_text(stmt, 4, reason.ptr, cast(int) reason.length, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

// The node's reason on a row, as rowResolved left it; empty when none.
const(char)[] reasonOf(sqlite3* db, long rowid) {
    __gshared char[REASON_CAP] buf = 0;
    size_t n;
    enum sql = "SELECT qntx_reason FROM attestations WHERE rowid = ?1\0";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return "";
    sqlite3_bind_int64(stmt, 1, rowid);
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        auto text = sqlite3_column_text(stmt, 0);
        if (text !is null)
            while (text[n] != 0 && n < buf.length) { buf[n] = text[n]; n++; }
    }
    sqlite3_finalize(stmt);
    return buf[0 .. n];
}

// Rows still claimed by this sky when its pass ends are handed back.
enum RELEASE_SQL = "UPDATE attestations SET qntx_at = 0 WHERE qntx_at <= 0 AND qntx_at = -?1\0";

void claimReleased(sqlite3* db, long pid) {
    enum sql = RELEASE_SQL;
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return;
    sqlite3_bind_int64(stmt, 1, pid);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

// Does the planner reach this statement through the named index? The partial
// index on qntx_at covers rows at or below zero, and a bound parameter does
// not tell the planner it is negative: without the index term, every claim
// release scanned 490k rows under the write lock. 3.2s on 2026-09-26.
bool planUsesIndex(sqlite3* db, const(char)* sql, const(char)[] index) {
    import db : sqlite3_column_text;
    import matcher : contains;
    __gshared char[8192] explain = 0;
    size_t n = 0;
    void put(const(char)[] s) { foreach (ch; s) if (n < explain.length - 1) explain[n++] = ch; }
    put("EXPLAIN QUERY PLAN ");
    size_t len = 0;
    while (sql[len] != 0) len++;
    put(sql[0 .. len]);
    explain[n] = 0;
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, explain.ptr, -1, &stmt, null) != SQLITE_OK) return false;
    bool used = false;
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        auto text = sqlite3_column_text(stmt, 3);
        if (text is null) continue;
        size_t tl = 0;
        while (text[tl] != 0) tl++;
        if (contains(text[0 .. tl], index)) used = true;
    }
    sqlite3_finalize(stmt);
    return used;
}

unittest {
    import db : sqlite3_open, sqlite3_close, applySchema;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    assert(planUsesIndex(db, RELEASE_SQL.ptr, "idx_attestations_stream"),
           "releasing a claim must not scan the table");
    assert(planUsesIndex(db, NEXT_CLAIMED_SQL.ptr, "idx_attestations_stream"),
           "the next claimed row must not scan the table");
    import outbox : HOLDERS_SQL;
    assert(planUsesIndex(db, HOLDERS_SQL!("attestations", "qntx_at").ptr, "idx_attestations_stream"),
           "listing claim holders must not scan the table");
    sqlite3_close(db);
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
    enum sql = "SELECT SUM(qntx_at = 0 AND NOT " ~ REFUSED_SQL ~ "), "
        ~ "SUM(qntx_at = 0 AND " ~ REFUSED_SQL ~ ") "
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

// The claimed rows as one list, in rowid order, as far as `into` holds them.
// A row that would take the list past `into` stops it there: it and the rows
// after it stay claimed until the pass releases them, and go in a later pass.
struct Built {
    size_t len;
    long rows;
    bool byteFull;
}

Built buildBatch(sqlite3* db, long pid, long now, char[] into) {
    Built b;
    if (into.length < 2) return b;
    into[b.len++] = '[';
    long after = 0;
    __gshared Claimed c;
    while (nextClaimed(db, pid, after, c)) {
        after = c.rowid;
        // A row that did not fit is not sent cut. It stays pending with the
        // reason on it, for a person to read; nothing here can make it fit.
        if (c.body_.over) {
            rowResolved(db, c.rowid, 0, false, now, "the row did not fit ground's stream buffer and was not sent");
            continue;
        }
        auto row = c.body_.slice();
        auto need = (b.rows > 0 ? 1 : 0) + row.length + 1;
        if (b.len + need > into.length) {
            b.byteFull = true;
            break;
        }
        if (b.rows > 0) into[b.len++] = ',';
        foreach (ch; row) into[b.len++] = ch;
        b.rows++;
    }
    into[b.len++] = ']';
    return b;
}

// The next row this sky holds after `after`, by rowid alone.
enum NEXT_ROWID_SQL = "SELECT rowid FROM attestations WHERE qntx_at <= 0 AND qntx_at = -?1 AND rowid > ?2 "
    ~ "ORDER BY rowid LIMIT 1\0";

private long nextClaimedRowid(sqlite3* db, long pid, long after) {
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(db, NEXT_ROWID_SQL.ptr, -1, &stmt, null) != SQLITE_OK) return 0;
    sqlite3_bind_int64(stmt, 1, pid);
    sqlite3_bind_int64(stmt, 2, after);
    long rowid = 0;
    if (sqlite3_step(stmt) == SQLITE_ROW) rowid = sqlite3_column_int64(stmt, 0);
    sqlite3_finalize(stmt);
    return rowid;
}

// One answer of the node's batch reply: {"results":[{"status":N,"answer":{..}},..]}.
// `at` is 0 before the first, and is moved past each answer read.
struct Answer {
    int status;
    const(char)[] text;
}

bool nextAnswer(const(char)[] reply, ref size_t at, ref Answer a) {
    import matcher : indexOf;
    if (at == 0) {
        enum open = `"results":[`;
        auto found = indexOf(reply, open);
        if (found < 0) return false;
        at = cast(size_t) found + open.length;
    }
    while (at < reply.length && (reply[at] == ' ' || reply[at] == ',' || reply[at] == '\n')) at++;
    if (at >= reply.length || reply[at] != '{') return false;

    // The answer object, brace-matched outside strings.
    size_t end = at;
    int depth = 0;
    bool inString = false;
    for (; end < reply.length; end++) {
        auto c = reply[end];
        if (inString) {
            if (c == '\\') { end++; continue; }
            if (c == '"') inString = false;
            continue;
        }
        if (c == '"') inString = true;
        else if (c == '{') depth++;
        else if (c == '}' && --depth == 0) break;
    }
    if (end >= reply.length) return false;
    auto obj = reply[at .. end];
    at = end + 1;

    enum statusKey = `"status":`;
    auto s = indexOf(obj, statusKey);
    if (s < 0) return false;
    a.status = 0;
    foreach (c; obj[cast(size_t) s + statusKey.length .. $]) {
        if (c < '0' || c > '9') break;
        a.status = a.status * 10 + (c - '0');
    }
    enum answerKey = `"answer":`;
    auto t = indexOf(obj, answerKey);
    a.text = t < 0 ? "" : obj[cast(size_t) t + answerKey.length .. $];
    return true;
}

// The rows a batch carried, each resolved by its own answer, in the order
// sent. `short_` is a reply that ran out of answers before the rows did; the
// rows past it stay claimed, for the pass to release.
struct Resolved {
    long landed;
    bool retry;
    bool short_;
    int lastStatus;
}

Resolved resolveBatch(sqlite3* db, long pid, long rows, const(char)[] reply, long now) {
    Resolved r;
    size_t at = 0;
    long after = 0;
    foreach (i; 0 .. rows) {
        auto rowid = nextClaimedRowid(db, pid, after);
        if (rowid == 0) break;
        after = rowid;
        Answer a;
        if (!nextAnswer(reply, at, a)) {
            r.short_ = true;
            break;
        }
        auto landed = a.status >= 200 && a.status < 300;
        rowResolved(db, rowid, a.status, landed, now, landed ? "" : a.text);
        r.lastStatus = a.status;
        if (landed) r.landed++;
        else if (retryable(a.status)) r.retry = true;
    }
    return r;
}

// What one pass came to. `odd` is a reply that is not an outage: a 4xx for
// the whole list, an answer too large to read, or fewer answers than rows.
struct Pass {
    bool sent;
    bool ok;
    bool grow;
    bool odd;
    int status;
    char[300] whyBuf = 0;
    size_t whyLen;
    const(char)[] why() const return { return whyBuf[0 .. whyLen]; }
    void say(const(char)[] s) { foreach (c; s) if (whyLen < whyBuf.length) whyBuf[whyLen++] = c; }
}

// One pass: claim at the pace, post the list, resolve each row by its answer.
// Rows a pass did not resolve go back. Not ok is what the caller waits on.
Pass streamPass(sqlite3* db, const(char)[] url, const(char)[] token, long pid, long now,
                long take, ref long posted) {
    import http : httpPostInto;
    Pass p;
    p.ok = true;

    auto claimed = claimStream(db, pid, take);
    if (claimed == 0) return p;

    __gshared char[NODE_BODY_CAP] batch = 0;
    auto built = buildBatch(db, pid, now, batch[]);
    if (built.rows == 0) {
        claimReleased(db, pid);
        return p;
    }
    p.sent = true;

    __gshared ZBuf endpoint;
    endpoint.reset();
    endpoint.put(url);
    endpoint.put("/api/attestations");

    // Each answer is a few words about one row, so the reply is smaller than
    // the list; a reply that is not is said, not read cut.
    __gshared char[NODE_BODY_CAP] reply = 0;
    auto r = httpPostInto(endpoint.slice(), batch[0 .. built.len], token, reply[], 10);
    p.status = r.status > 0 ? r.status : -r.code;

    if (r.overran) {
        p.ok = false;
        p.odd = true;
        p.say("the node's answer to the list was larger than ground reads");
    } else if (r.status == 200) {
        auto res = resolveBatch(db, pid, built.rows, reply[0 .. r.len], now);
        posted += res.landed;
        p.ok = !res.retry && !res.short_;
        if (res.retry) p.status = res.lastStatus;
        if (res.short_) {
            p.odd = true;
            p.say("the node answered fewer results than the rows it was sent: ");
            p.say(reply[0 .. r.len]);
        }
        p.grow = p.ok && claimed == take && !built.byteFull;
    } else {
        // No answer, a 5xx or a 429 is an outage and the rows wait it out.
        // Any other 4xx for the whole list is the token or the request, and
        // is said.
        p.ok = false;
        if (!retryable(r.status)) {
            p.odd = true;
            p.say(reply[0 .. r.len]);
        } else if (r.status == 0) {
            p.say(r.why());
        } else {
            p.say(reply[0 .. r.len]);
        }
    }
    claimReleased(db, pid);
    return p;
}

unittest {
    import db : sqlite3_open, sqlite3_close, sqlite3_exec, applySchema, attestEventAt;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    assert(claimStream(db, 111, 10) == 0, "nothing written is nothing pending");

    // A PostToolUse row with its output whole, and a Stop row.
    attestEventAt(db, "PostToolUse", "/tmp", "sess-s",
        `{"session_id":"sess-s","tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_response":{"stdout":"a very long listing"},"duration_ms":1711}`,
        "2026-09-19T09:03:25Z", 34348);
    attestEventAt(db, "Stop", "/tmp", "sess-s", `{"session_id":"sess-s","stop_hook_active":false}`,
        "2026-09-19T09:03:26Z", 34349);

    assert(claimStream(db, 111, 10) == 2);
    assert(claimStream(db, 222, 10) == 0, "a second sky finds nothing left to claim");

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
    // QNTX #1068, Phase 3: a tool's own cost goes with it.
    assert(contains(body_, `"duration_ms":1711`), "what the tool took is sent");
    assert(!contains(body_, "a very long listing"), "the output stays home");
    assert(!contains(body_, "tool_response"));

    Claimed d;
    assert(nextClaimed(db, 111, c.rowid, d));
    assert(contains(d.body_.slice(), `"stop_hook_active":false`), "everything else goes whole");
    Claimed e;
    assert(!nextClaimed(db, 111, d.rowid, e));

    // A row goes whole or not at all. The body went through a 4096-byte
    // buffer for a week and 89 rows reached the node cut mid-JSON: every
    // pasted prompt over 4KB, every rite row, refused 400 and never retried.
    // A hook's payload is at most readStdin's 256KB, so a row always fits.
    {
        enum head = `{"session_id":"sess-s","prompt":"`;
        enum tail = `TAILMARK"}`;
        __gshared char[200_000 + head.length + tail.length] payload = 'x';
        payload[0 .. head.length] = head;
        payload[$ - tail.length .. $] = tail;
        attestEventAt(db, "UserPromptSubmit", "/tmp", "sess-s", payload[], "2026-09-19T09:03:27Z", 34350);
        assert(claimStream(db, 555, 10) == 1);
        Claimed w;
        assert(nextClaimed(db, 555, 0, w));
        assert(!w.body_.over, "a 200KB row fits");
        assert(contains(w.body_.slice(), "TAILMARK"), "and goes whole");
        rowResolved(db, w.rowid, 201, true, 5000);
        claimReleased(db, 555);
    }

    // Landed is the time; refused by the node is pending with its status and
    // out of the next claim; unreachable is pending and claimed again.
    rowResolved(db, c.rowid, 201, true, 5000);
    rowResolved(db, d.rowid, 403, false, 5000);
    // The node's reason stays on the row. A status alone told nobody why 89
    // rows were refused; the reason was in the reply and thrown away.
    rowResolved(db, d.rowid, 400, false, 5000, "Invalid request body: unexpected EOF");
    assert(reasonOf(db, d.rowid) == "Invalid request body: unexpected EOF");
    rowResolved(db, d.rowid, 403, false, 5000);
    assert(claimStream(db, 111, 10) == 0, "a 4xx is not asked again");
    rowResolved(db, d.rowid, 503, false, 5000);
    assert(claimStream(db, 111, 10) == 1, "a 5xx is");
    claimReleased(db, 111);
    rowResolved(db, d.rowid, 429, false, 5000);
    assert(claimStream(db, 111, 10) == 1, "and a 429 is");
    claimReleased(db, 111);
    assert(standing(db).pending == 1 && standing(db).refused == 0, "a 429 is pending, not refused");

    auto s = standing(db);
    assert(s.pending == 1 && s.refused == 0);
    rowResolved(db, d.rowid, 400, false, 5000);
    s = standing(db);
    assert(s.pending == 0 && s.refused == 1);

    // A claim by a sky that died is freed; a landed row and a BEFORE_STREAM
    // row are not claims and are not touched.
    rowResolved(db, d.rowid, 0, false, 0);
    assert(claimStream(db, 333, 10) == 1);
    static bool nobody(long) { return false; }
    assert(releaseDeadClaims(db, &nobody) == 1);
    assert(claimStream(db, 444, 10) == 1, "claimable again");
    sqlite3_close(db);
}

unittest {
    assert(retryable(0), "no answer");
    assert(retryable(-7), "libcurl could not connect");
    assert(retryable(500));
    assert(retryable(503));
    assert(!retryable(400));
    assert(!retryable(403));
    // "it should be retryable"
    assert(retryable(429), "the node is slow and this token sends the most; come back after Retry-After");
    assert(!retryable(201), "landed is not retried either; it is done");
}

unittest {
    // "be gentle with sending at the start until it catches up"
    Pace p;
    assert(p.take == 1, "a sky starts with one row");
    paceLanded(p, true);
    assert(p.take == 2);
    paceLanded(p, true);
    assert(p.take == 4);
    paceLanded(p, false);
    assert(p.take == 4, "caught up, so the next pass is no larger");

    // "4 can wait for longer even, up to 5m"
    assert(!paceFailed(p));
    assert(p.take == 1, "a failed post is gentle again");
    assert(p.wait == 60);
    assert(!paceFailed(p));
    assert(p.wait == 120);
    assert(!paceFailed(p));
    assert(p.wait == 240);
    // "Does not need to be told this often, deploy's are commonplace"
    assert(paceFailed(p), "sentry hears once, when the wait reaches 5m");
    assert(p.wait == 300);
    assert(!paceFailed(p), "and not again while it stays there");
    assert(p.wait == 300);

    paceLanded(p, true);
    assert(p.wait == 0 && p.take == 2, "a post that lands ends the waiting");
    assert(!paceFailed(p));
    assert(p.wait == 60, "and the next outage starts from the first wait");
}

unittest {
    import db : sqlite3_open, sqlite3_close, applySchema, attestEventAt;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    attestEventAt(db, "Stop", "/tmp", "sess-b", `{"session_id":"sess-b","n":1}`, "2026-10-02T09:00:01Z", 1);
    attestEventAt(db, "Stop", "/tmp", "sess-b", `{"session_id":"sess-b","n":2}`, "2026-10-02T09:00:02Z", 2);
    attestEventAt(db, "Stop", "/tmp", "sess-b", `{"session_id":"sess-b","n":3}`, "2026-10-02T09:00:03Z", 3);

    assert(claimStream(db, 7, 2) == 2, "a pass claims as many as its pace");
    __gshared char[100_000] into = 0;
    auto b = buildBatch(db, 7, 5000, into[]);
    assert(b.rows == 2 && !b.byteFull);
    auto sent = into[0 .. b.len];
    // "the 2s can move to 5s and just collect everything in that 5s and send it always, like it still does but batch them"
    assert(sent[0] == '[' && sent[$ - 1] == ']', "one list");
    assert(contains(sent, `"n":1`) && contains(sent, `"n":2`));
    assert(contains(sent, "},{"), "the rows as the node takes each one, side by side");
    claimReleased(db, 7);

    // The node's limit: a row that would take the list past it waits for
    // the next pass, still pending.
    assert(claimStream(db, 7, 3) == 3);
    Claimed first;
    assert(nextClaimed(db, 7, 0, first));
    auto one = buildBatch(db, 7, 5000, into[0 .. first.body_.len + 2]);
    assert(one.rows == 1 && one.byteFull);
    assert(one.len == first.body_.len + 2);
    assert(into[0] == '[' && into[one.len - 1] == ']');
    assert(into[1 .. one.len - 1] == first.body_.slice(), "the first row whole, alone");
    claimReleased(db, 7);
    assert(claimStream(db, 7, 10) == 3, "nothing was lost to the limit");

    // Each row by its own answer, in the order sent.
    auto all = buildBatch(db, 7, 5000, into[]);
    assert(all.rows == 3);
    Claimed second;
    assert(nextClaimed(db, 7, first.rowid, second));
    enum reply = `{"results":[{"status":201,"answer":{"id":"a","status":"created"}},`
        ~ `{"status":400,"answer":{"error":"subjects must not be empty"}},`
        ~ `{"status":503,"answer":{"error":"busy"}}]}` ~ "\n";
    auto r = resolveBatch(db, 7, all.rows, reply, 6000);
    assert(r.landed == 1);
    assert(r.retry, "a 5xx is asked again");
    assert(!r.short_);
    assert(reasonOf(db, second.rowid) == `{"error":"subjects must not be empty"}`, "the node's words on the row");
    claimReleased(db, 7);
    assert(claimStream(db, 8, 10) == 1, "landed and refused are out of the next claim; the 5xx is in it");

    // Fewer answers than rows: the rows without one stay pending.
    auto again = buildBatch(db, 8, 6000, into[]);
    assert(again.rows == 1);
    auto none = resolveBatch(db, 8, again.rows, `{"results":[]}`, 7000);
    assert(none.short_ && none.landed == 0);
    claimReleased(db, 8);
    assert(claimStream(db, 9, 10) == 1);
    sqlite3_close(db);
}

unittest {
    import db : sqlite3_open, sqlite3_close, applySchema;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    assert(planUsesIndex(db, NEXT_ROWID_SQL.ptr, "idx_attestations_stream"),
           "walking the claimed rows to resolve them must not scan the table");
    sqlite3_close(db);
}

version (unittest)
private bool contains(const(char)[] hay, const(char)[] needle) {
    if (needle.length > hay.length) return false;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle) return true;
    return false;
}
