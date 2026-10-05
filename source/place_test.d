module place_test;

// QNTX #1068, Phase 3: a row ground streams names no project and no origin,
// so the node cannot group sessions by where they ran.

import proto : parsePbt;
import place : placeOf;

enum blocks = `
project {
  path: "/teranos/QNTX"
}

project {
  path: "/teranos/QNTX/web"
}

project {
  origin: "teranos/ground"
  path: "/somewhere/else"
}
`;

static immutable parsed = parsePbt(blocks);

// The deepest project block whose path holds the place.
static assert(placeOf(parsed, "/Users/x/teranos/QNTX/server", "", "") == "/teranos/QNTX");
static assert(placeOf(parsed, "/Users/x/teranos/QNTX/web/src", "", "") == "/teranos/QNTX/web");

// A project that names the repo's origin is that repo's, wherever the checkout is.
static assert(placeOf(parsed, "/tmp/a-worktree", "", "teranos/ground") == "/somewhere/else");

// The repo's root counts as the place, so a worktree cut elsewhere is its project's.
static assert(placeOf(parsed, "/tmp/qntx-deploy-1", "/Users/x/teranos/QNTX", "") == "/teranos/QNTX");

// Nowhere any block stands is no project, said as nothing.
static assert(placeOf(parsed, "/Users/x/elsewhere", "", "") == "");

// Every event a session writes carries where it ran, after the session itself,
// which stays first: queries read contexts[0] as the session.
import db : sqlite3, sqlite3_open, sqlite3_close, sqlite3_exec, applySchema, attestEventAt,
            sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_column_text,
            sqlite3_stmt, SQLITE_OK, SQLITE_ROW;

private const(char)[] contextsOf(sqlite3* db, string id) {
    __gshared char[256] buf = 0;
    enum sql = "SELECT contexts FROM attestations WHERE id LIKE ?1\0";
    sqlite3_stmt* s;
    assert(sqlite3_prepare_v2(db, sql.ptr, -1, &s, null) == SQLITE_OK);
    import db : sqlite3_bind_text, SQLITE_TRANSIENT;
    sqlite3_bind_text(s, 1, id.ptr, cast(int) id.length, SQLITE_TRANSIENT);
    size_t n;
    if (sqlite3_step(s) == SQLITE_ROW) {
        auto t = sqlite3_column_text(s, 0);
        while (t[n] != 0 && n < buf.length) { buf[n] = t[n]; n++; }
    }
    sqlite3_finalize(s);
    return buf[0 .. n];
}

unittest {
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    assert(sqlite3_exec(db, ("INSERT INTO session_project (session_id, project, origin, place) "
        ~ "VALUES ('s-p', 'teranos/QNTX', 'teranos/QNTX', '/teranos/QNTX')\0").ptr, null, null, null) == SQLITE_OK);
    attestEventAt(db, "PreToolUse", "/tmp", "s-p", `{"x":1}`, "2026-10-04T13:00:00Z", 77);
    assert(contextsOf(db, "%PreToolUse:2026-10-04T13:00:00Z:77") ==
           `["session:s-p","origin:teranos/QNTX","project:/teranos/QNTX"]`);

    // A session that has no place on record says only who it is.
    attestEventAt(db, "PreToolUse", "/tmp", "s-q", `{"x":1}`, "2026-10-04T13:00:01Z", 78);
    assert(contextsOf(db, "%PreToolUse:2026-10-04T13:00:01Z:78") == `["session:s-q"]`);
    sqlite3_close(db);
}
