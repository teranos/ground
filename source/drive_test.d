module drive_test;

// What the driver does about a tree that is not there.
// A rite run before the tree exists records "hold, code 1" with the output
// "cd: …: No such file or directory" — a verdict about a question never asked.

import ritual.drive : TreeVerdict, treeVerdict, TREE_WAIT_SEC;

// The tree is there. Nothing to decide.
static assert(treeVerdict(true, false, true, 0) == TreeVerdict.Run);
static assert(treeVerdict(true, true, true, 0) == TreeVerdict.Run);

// Not there and never seen: the agent has not made it yet. `ground ritual`
// dispatches the driver and the agent together, and the tree only exists once
// `claude -w` fires WorktreeCreate — so the driver always starts ahead of it.
static assert(treeVerdict(false, false, true, 0) == TreeVerdict.Wait);

// Not there and seen before: it was removed, and the performance is over.
static assert(treeVerdict(false, true, true, 0) == TreeVerdict.Gone);

// The regoto test's agent could not start, so no tree came, and its driver
// waited on W1 with nobody told; an abort could not reach it, because the
// wait never read the row. Ended before a tree is ended: the wait is over.
static assert(treeVerdict(false, false, false, 0) == TreeVerdict.Ended);

// And a tree that does not come in time is not coming.
static assert(treeVerdict(false, false, true, TREE_WAIT_SEC - 1) == TreeVerdict.Wait);
static assert(treeVerdict(false, false, true, TREE_WAIT_SEC) == TreeVerdict.NeverMade);

import ritual.drive : mayRemoveTree;
import ritual.position : RitualState;

// A tree ground cut is ground's to remove once the commits are pushed.
static assert(mayRemoveTree(RitualState.Done, "checkout"));
static assert(mayRemoveTree(RitualState.Done, "empty"));

// A ritual that named no tree performed in a place that was already there.
// Removing it deleted a checkout a person was working in.
static assert(!mayRemoveTree(RitualState.Done, ""));

// A halt keeps its tree either way — what the rite left is what you look at.
static assert(!mayRemoveTree(RitualState.Halted, "checkout"));
static assert(!mayRemoveTree(RitualState.Aborted, "checkout"));
static assert(!mayRemoveTree(RitualState.Live, "checkout"));

import ritual.drive : endingWord;

// What sentry is told an ending was. Live is not an ending, so it has no word
// and nothing is reported under one.
static assert(endingWord(RitualState.Done) == "done");
static assert(endingWord(RitualState.Halted) == "halted");
static assert(endingWord(RitualState.Aborted) == "aborted");
static assert(endingWord(RitualState.Live) == "");

// The detail of one note, by its id, or null when there is none.
private const(char)[] noteOf(DB)(DB db, const(char)[] id) {
    import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_stmt, sqlite3_column_text,
                sqlite3_bind_text, SQLITE_TRANSIENT, SQLITE_ROW, SQLITE_OK;
    __gshared char[512] buf = 0;
    sqlite3_stmt* s;
    enum q = "SELECT json_extract(attributes,'$.detail') FROM attestations WHERE id = ?1\0";
    assert(sqlite3_prepare_v2(db, q.ptr, -1, &s, null) == SQLITE_OK);
    sqlite3_bind_text(s, 1, id.ptr, cast(int) id.length, SQLITE_TRANSIENT);
    const(char)[] got = null;
    if (sqlite3_step(s) == SQLITE_ROW) {
        auto t = sqlite3_column_text(s, 0);
        size_t n;
        while (t[n] != 0 && n < buf.length) { buf[n] = t[n]; n++; }
        got = buf[0 .. n];
    }
    sqlite3_finalize(s);
    return got;
}

// "failure needs to prop to parent immediately when i happens"
// "if FLIP1 ci is red, parent should know about it on T15 and the FLIP2 ci red would surface on T2 + T15"
// A run the node found failed is told to the parent the moment the driver finds it, whatever the
// rite's to: says, and not when the walk reaches the rite that waits on the run. A run that went
// well is the block's to close, and tells nobody.
unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, sqlite3_exec, applySchema, SQLITE_OK;
    import immediate : writeDispatchStatus;
    import ritual.drive : resolveOwed;
    import ritual.position : start;

    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    auto p = start("coinflip", 3);
    p.id = "coinflip-1";
    p.parent = "sess-parent";
    p.agentSession = "sess-agent";

    assert(writeDispatchStatus(db, "sess-parent", "sbvh-nl/grove", "coinflip-1:FLIP1", 0));
    assert(writeDispatchStatus(db, "sess-parent", "sbvh-nl/grove", "coinflip-1:FLIP2", 0));
    // What ug writes down when the node leaves a run's conclusion: `run: <conclusion> <token> <url>`.
    enum news = "INSERT INTO attestations (id, subjects, predicates, contexts, actors, timestamp, source, attributes) VALUES "
        ~ "('immediate:news:immediate:dispatch:sess-parent:coinflip-1:FLIP1', '[\"news\"]', '[\"immediate:news\"]', "
        ~ "'[\"session:sess-parent\"]', '[\"ug\"]', '2026-11-05T10:00:00Z', 'ug', "
        ~ "'{\"detail\":\"run: failure coinflip-1:FLIP1 https://github.com/sbvh-nl/grove/actions/runs/1\",\"after\":0}'), "
        ~ "('immediate:news:immediate:dispatch:sess-parent:coinflip-1:FLIP2', '[\"news\"]', '[\"immediate:news\"]', "
        ~ "'[\"session:sess-parent\"]', '[\"ug\"]', '2026-11-05T10:00:00Z', 'ug', "
        ~ "'{\"detail\":\"run: success coinflip-1:FLIP2 https://github.com/sbvh-nl/grove/actions/runs/2\",\"after\":0}')\0";
    assert(sqlite3_exec(db, news.ptr, null, null, null) == SQLITE_OK);

    assert(resolveOwed(db, p, 2_000_000_000) == 2, "both runs are answered");

    assert(noteOf(db, "immediate:note:sess-parent:run-failed:coinflip-1:FLIP1")
        == "coinflip FLIP1 failed: run: failure coinflip-1:FLIP1 https://github.com/sbvh-nl/grove/actions/runs/1",
        "the parent hears the failed run at once");
    assert(noteOf(db, "immediate:note:sess-agent:run-failed:coinflip-1:FLIP1") !is null, "the agent caused it, and hears it too");
    assert(noteOf(db, "immediate:note:sess-parent:run-failed:coinflip-1:FLIP2") is null, "a run that went well tells nobody");
    sqlite3_close(db);
}

// A run went well only when the node's news opens on success.
import ritual.drive : runWent;
static assert(runWent("run: success coinflip-1:FLIP1 https://x/1"));
static assert(!runWent("run: failure coinflip-1:FLIP1 https://x/1"));
static assert(!runWent("run: cancelled coinflip-1:FLIP1 https://x/1"));
static assert(!runWent("run: no run carries the name ground gave it: coinflip-1:FLIP1"));
static assert(!runWent("no outcome came back from the node for this run"));
