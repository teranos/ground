module sessiontrail_test;

// "when that get's comitted, that in the commit itself is inserted the session id"
// "i will be able to trace back to the exact conversation, even years back"

import sessiontrail : withTrailers, treeOf, editorsSince, isCommit;

// The sessions go in as trailers on the commit itself, after `commit`, so
// whatever the message says and however it is given, they ride with it.
unittest {
    const(char)[][2] two = ["aaaa", "bbbb"];
    assert(withTrailers("git -C '/r' commit -q -F /tmp/m", two[]) ==
        "git -C '/r' commit --trailer 'session: aaaa' --trailer 'session: bbbb' -q -F /tmp/m");
    assert(withTrailers("git commit -m 'x'", two[0 .. 1]) ==
        "git commit --trailer 'session: aaaa' -m 'x'");
    // No session edited what is staged: the commit is left as it was typed.
    assert(withTrailers("git commit -m 'x'", two[0 .. 0]) == "git commit -m 'x'");
}

// Where the commit happens: the tree `git -C` names, or where the call stands.
unittest {
    assert(isCommit("git -C '/r' commit -q"));
    assert(isCommit("git commit -m x"));
    assert(!isCommit("git log --grep=commit"));
    assert(!isCommit("git commit-tree abc"));
    assert(treeOf("git -C '/r/x y' commit -q", "/cwd") == "/r/x y");
    assert(treeOf("git -C /r commit", "/cwd") == "/r");
    assert(treeOf("git commit -m x", "/cwd") == "/cwd");

    // A commit after `cd` and an `&&` was no commit at all: on 2026-10-02 at
    // 15:59:14Z one carried no trailer and its prose was never scored.
    enum chained = `cd /r && git add a.d && git commit -m "probe live"`;
    assert(isCommit(chained));
    assert(withTrailers(chained, two()[0 .. 1]) ==
        `cd /r && git add a.d && git commit --trailer 'session: aaaa' -m "probe live"`);
    assert(isCommit("git status; git commit -q"));
    assert(!isCommit("cd /r && git log --grep=commit"));
    assert(treeOf("cd /x && git -C /r commit", "/cwd") == "/r");
}

private const(char)[][2] two() {
    const(char)[][2] t = ["aaaa", "bbbb"];
    return t;
}

// Every session that edited the file since it was last committed, read by the
// file's path: the session's own subject names where it was started, which is
// not where the file is.
unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, attestEventAt, SQLITE_OK;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    attestEventAt(db, "PostToolUse", "/tmp", "before",
        `{"tool_name":"Edit","tool_input":{"file_path":"/r/a.d"}}`, "2026-09-01T10:00:00Z", 1);
    attestEventAt(db, "PostToolUse", "/tmp", "editor",
        `{"tool_name":"Edit","tool_input":{"file_path":"/r/a.d"}}`, "2026-09-02T10:00:00Z", 2);
    attestEventAt(db, "PostToolUse", "/tmp", "writer",
        `{"tool_name":"Write","tool_input":{"file_path":"/r/a.d"}}`, "2026-09-02T11:00:00Z", 3);
    attestEventAt(db, "PostToolUse", "/tmp", "reader",
        `{"tool_name":"Read","tool_input":{"file_path":"/r/a.d"}}`, "2026-09-02T12:00:00Z", 4);
    attestEventAt(db, "PostToolUse", "/tmp", "elsewhere",
        `{"tool_name":"Edit","tool_input":{"file_path":"/r/b.d"}}`, "2026-09-02T12:00:00Z", 5);
    // Decay keeps the path at the top of the attributes; the session stays in contexts.
    attestEventAt(db, "PostToolUse", "/tmp", "decayed",
        `{"tool_name":"Edit","file_path":"/r/a.d","decayed":1}`, "2026-09-02T13:00:00Z", 6);

    // Read by the index on the path, not by a walk of every row.
    {
        import db : sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_column_text,
                    sqlite3_stmt, SQLITE_ROW;
        import sessiontrail : EDIT_PATH;
        enum plan = "EXPLAIN QUERY PLAN SELECT 1 FROM attestations WHERE json_extract(predicates, '$[0]') = 'PostToolUse' AND "
            ~ EDIT_PATH ~ " = '/r/a.d'\0";
        sqlite3_stmt* stmt;
        assert(sqlite3_prepare_v2(db, plan.ptr, -1, &stmt, null) == SQLITE_OK);
        bool byIndex;
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            auto t = sqlite3_column_text(stmt, 3);
            size_t n;
            while (t[n] != 0) n++;
            auto detail = (cast(const(char)*) t)[0 .. n];
            foreach (i; 0 .. detail.length)
                if (i + 26 <= detail.length && detail[i .. i + 26] == "idx_attestations_edit_path") byIndex = true;
        }
        sqlite3_finalize(stmt);
        assert(byIndex, "the edits of a file are found by the path's index");
    }

    // 2026-09-01T12:00:00Z, after "before" and ahead of the rest.
    auto found = editorsSince(db, "/r/a.d", 1788264000);
    assert(found.count == 3);
    assert(found.has("editor") && found.has("writer") && found.has("decayed"));
    assert(!found.has("before") && !found.has("reader") && !found.has("elsewhere"));

    // "yes, add the model and also the effort that was used"
    // The model and effort in force at the session's last edit of the file,
    // not the ones it switched to after.
    import db : sqlite3_exec;
    import sessiontrail : describe;
    enum models = "INSERT INTO session_model (session, model, effort, since) VALUES "
        ~ "('editor', 'claude-opus-5-5', 'high', 1788200000), "
        ~ "('editor', 'claude-sonnet-5', 'low', 1788400000)\0";
    assert(sqlite3_exec(db, models.ptr, null, null, null) == SQLITE_OK);
    describe(db, found);
    assert(found.labelOf("editor") == "editor (claude-opus-5-5, high)", found.labelOf("editor"));

    // A session ground never recorded a model for is named by its id alone.
    assert(found.labelOf("writer") == "writer");
    sqlite3_close(db);
}
