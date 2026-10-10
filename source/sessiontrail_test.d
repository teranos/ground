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

// "3. sure"
// What `git add` and `git commit -a` in the same command will stage, read off
// the command as the shell runs it: each add from where it stands.
unittest {
    import sessiontrail : addsBefore;
    auto a = addsBefore(`cd /r && git add a.d sub/b.d && git commit -m x`, "/cwd");
    assert(a.count == 1 && a.adds[0].dir == "/r" && a.adds[0].specs.length == 2);
    assert(a.adds[0].specs[0] == "a.d" && a.adds[0].specs[1] == "sub/b.d");
    assert(!a.all);

    auto u = addsBefore(`git -C /r add -u && git -C /r commit -m x`, "/cwd");
    assert(u.count == 1 && u.adds[0].update && u.adds[0].dir == "/r" && u.adds[0].specs.length == 0);

    auto am = addsBefore(`git commit -am "x"`, "/cwd");
    assert(am.count == 0 && am.all, "-a, combined with -m, stages every tracked change");
    assert(addsBefore(`git commit --all -m x`, "/cwd").all);

    // A dry run stages nothing, and an add after the commit is not in it.
    assert(addsBefore(`git add -n a.d && git commit -m x`, "/cwd").count == 0);
    assert(addsBefore(`git commit -m x && git add a.d`, "/cwd").count == 0);

    // A relative cd is taken from where the shell stands.
    auto rel = addsBefore(`cd sub && git add . && git commit -m x`, "/r");
    assert(rel.adds[0].dir == "/r/sub" && rel.adds[0].specs[0] == ".");
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

// Every path in one asking still reads the edit-path index, path by path.
unittest {
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, sqlite3_prepare_v2, sqlite3_step,
                sqlite3_finalize, sqlite3_column_text, sqlite3_stmt, SQLITE_OK, SQLITE_ROW;
    import sessiontrail : editorsAllSql;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    scope (exit) sqlite3_close(db);

    __gshared char[4096] sql = 0;
    __gshared char[4200] plan = 0;
    enum lead = "EXPLAIN QUERY PLAN ";
    foreach (i, c; lead) plan[i] = c;
    auto body_ = editorsAllSql(3, sql[]);
    foreach (i, c; body_) plan[lead.length + i] = c;
    plan[lead.length + body_.length] = 0;

    sqlite3_stmt* stmt;
    assert(sqlite3_prepare_v2(db, &plan[0], -1, &stmt, null) == SQLITE_OK);
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
    assert(byIndex, "the edits of every path are found by the path's index");
}

// "i will be able to trace back to the exact conversation, even years back"
// The sessions on a commit are the ones the git program and a query per file
// named: the same sessions, in the same order, with the same last edit.
unittest {
    import libgit2_test : fixture, gitOut, Buf, sh;
    import sessiontrail : sessionsForCommit, collectEditors, describe, Editors;
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, attestEventAt, SQLITE_OK;

    auto fx = fixture();
    auto root = gitOut(fx.text(), "rev-parse --show-toplevel");
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    scope (exit) sqlite3_close(db);

    void edit(const(char)[] session, const(char)[] tool, const(char)[] name, const(char)[] when) {
        Buf a;
        a.put(`{"tool_name":"`);
        a.put(tool);
        a.put(`","tool_input":{"file_path":"`);
        a.put(root.text());
        a.put("/");
        a.put(name);
        a.put(`"}}`);
        attestEventAt(db, "PostToolUse", "/tmp", session, a.text(), when, 1);
    }
    edit("early", "Edit", "a.d", "2026-01-01T00:00:01Z");
    edit("late", "Edit", "a.d", "2026-02-01T00:00:00Z");
    edit("fresh", "Write", "new.d", "2026-03-01T00:00:00Z");
    edit("mover", "Edit", "sub/moved.d", "2026-02-02T00:00:00Z");
    edit("late", "Edit", "plain.d", "2026-04-01T00:00:00Z");
    edit("aside", "Edit", "side.d", "2026-05-01T00:00:00Z");
    edit("remover", "Edit", "evil.d", "2026-01-01T00:00:06Z");

    // The answer as it was asked before: the git program, file by file.
    Editors expected;
    auto names = gitOut(fx.text(), "diff --cached --name-only");
    size_t start;
    foreach (i; 0 .. names.n + 1) {
        if (i < names.n && names.b[i] != '\n') continue;
        auto name = names.b[start .. i];
        start = i + 1;
        if (name.length == 0) continue;
        auto ct = gitOut(root.text(), "log -1 --format=%ct -- '", name, "'");
        long since;
        foreach (c; ct.text()) { if (c < '0' || c > '9') break; since = since * 10 + (c - '0'); }
        Buf path;
        path.put(root.text());
        path.put("/");
        path.put(name);
        collectEditors(db, path.text(), since, expected);
    }
    describe(db, expected);

    Buf cmd;
    cmd.put("git -C '");
    cmd.put(fx.text());
    cmd.put("' commit -m x");
    auto found = sessionsForCommit(db, cmd.text(), "/cwd");
    assert(!found.over);
    assert(found.count == expected.count);
    foreach (i; 0 .. found.count) {
        assert(found.at(i) == expected.at(i), found.at(i));
        assert(found.lastAt[i] == expected.lastAt[i], found.at(i));
    }

    // fe71e8a's shape: the add in the same command as the commit. The file is
    // not staged yet when the hook reads the tree, and its editor is named.
    {
        sh("printf 'five\\n' >> '", root.text(), "/side.d'");
        edit("sider", "Edit", "side.d", "2026-06-01T00:00:00Z");
        Buf same;
        same.put("cd '");
        same.put(fx.text());
        same.put("' && git add side.d && git commit -m x");
        auto withAdd = sessionsForCommit(db, same.text(), "/cwd");
        assert(withAdd.has("sider"), "an add in the same command is staged by the time the commit runs");
        assert(gitOut(fx.text(), "diff --cached --name-only -- side.d").n == 0, "and the hook staged nothing itself");
    }

    // Read off the fixture, so the comparison is known to cover each case.
    assert(found.count == 4);
    assert(found.has("late") && found.has("fresh") && found.has("mover") && found.has("remover"));
    assert(!found.has("early"), "edited before the file was last committed");
    assert(!found.has("aside"), "edited a file that is not staged");
}
