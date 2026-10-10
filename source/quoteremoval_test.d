module quoteremoval_test;

import quoteremoval : removedQuotes, Removals, removalsInto;

// A quoted line in a comment, taken out and put back nowhere.
unittest {
    enum patch = "diff --git a/a.d b/a.d\n"
        ~ "index 1111111..2222222 100644\n"
        ~ "--- a/a.d\n"
        ~ "+++ b/a.d\n"
        ~ "@@ -3 +2,0 @@\n"
        ~ "-// \"the max time on phases is ideally lower than 5s always\"\n";
    auto r = removedQuotes(patch);
    assert(r.count == 1);
    assert(r.files[0] == "a.d");
    assert(r.spans[0] == "the max time on phases is ideally lower than 5s always");
}

// Moved is not removed: the same quote stands in an added line, in this file
// or another.
unittest {
    enum patch = "diff --git a/a.d b/a.d\n"
        ~ "--- a/a.d\n"
        ~ "+++ b/a.d\n"
        ~ "@@ -3 +3 @@\n"
        ~ "-// \"why do i still have 12+ sec outliers\"\n"
        ~ "+    // \"why do i still have 12+ sec outliers\"\n";
    assert(removedQuotes(patch).count == 0);

    enum across = "diff --git a/a.d b/a.d\n"
        ~ "--- a/a.d\n"
        ~ "+++ b/a.d\n"
        ~ "@@ -3 +2,0 @@\n"
        ~ "-// \"why do i still have 12+ sec outliers\"\n"
        ~ "diff --git a/b.md b/b.md\n"
        ~ "--- a/b.md\n"
        ~ "+++ b/b.md\n"
        ~ "@@ -1,0 +2 @@\n"
        ~ "+\"why do i still have 12+ sec outliers\"\n";
    assert(removedQuotes(across).count == 0);
}

// What the claim side does not count, the removal side does not either: a
// string literal is code, and one quoted word is a name.
unittest {
    enum patch = "diff --git a/a.d b/a.d\n"
        ~ "--- a/a.d\n"
        ~ "+++ b/a.d\n"
        ~ "@@ -3,2 +2,0 @@\n"
        ~ "-enum x = \"a string literal of code\";\n"
        ~ "-// the \"name\" alone\n";
    assert(removedQuotes(patch).count == 0);
}

// Every line of a document is prose, and a deleted file is read by the name it
// had, since the new side is /dev/null.
unittest {
    enum patch = "diff --git a/NOTES.md b/NOTES.md\n"
        ~ "deleted file mode 100644\n"
        ~ "--- a/NOTES.md\n"
        ~ "+++ /dev/null\n"
        ~ "@@ -1,2 +0,0 @@\n"
        ~ "-# heading\n"
        ~ "-\"human user quotes should never count towards the consecutive comment run control\"\n";
    auto r = removedQuotes(patch);
    assert(r.count == 1);
    assert(r.files[0] == "NOTES.md");
    assert(r.spans[0] == "human user quotes should never count towards the consecutive comment run control");
}

// The file headers are not removed lines, even when a path carries a quote.
unittest {
    enum patch = "diff --git a/x.md b/x.md\n"
        ~ "--- a/x.md\n"
        ~ "+++ b/x.md\n"
        ~ "@@ -1 +1 @@\n"
        ~ "-plain\n"
        ~ "+plainer\n";
    assert(removedQuotes(patch).count == 0);
}

// What the node is sent: the commit, and the files and spans side by side.
unittest {
    import zbuf : ZBuf;
    enum patch = "diff --git a/a.d b/a.d\n"
        ~ "--- a/a.d\n"
        ~ "+++ b/a.d\n"
        ~ "@@ -3 +2,0 @@\n"
        ~ "-// \"a path\\with a backslash in it\"\n";
    auto r = removedQuotes(patch);
    __gshared ZBuf o;
    o.reset();
    removalsInto(o, "abc1234", r);
    assert(o.slice() == `{"commit":"abc1234","files":["a.d"],"spans":["a path\\with a backslash in it"]}`, o.slice());
}

// The patch a real commit makes, read through libgit2.
unittest {
    import libgit2 : Repo;
    import libgit2_test : sh, scratch, gitOut;
    auto root = scratch("quoteremoval");
    auto r = root.text();
    sh("git init -q -b main '", r, "'");
    sh("git -C '", r, "' config user.name ground");
    sh("git -C '", r, "' config user.email ground@example.invalid");
    sh("printf 'int x;\\n// \"you replace something i said with soething elsem\"\\n' > '", r, "/a.c'");
    sh("git -C '", r, "' add a.c");
    sh("git -C '", r, "' commit -q -m one");
    sh("printf 'int x;\\n// my own words instead\\n' > '", r, "/a.c'");
    sh("git -C '", r, "' commit -q -a -m two");
    auto sha = gitOut(r, "rev-parse HEAD");
    __gshared Repo g;
    assert(g.open(r), g.why);
    __gshared char[65536] patch = 0;
    auto shown = g.show(sha.text(), patch[]);
    g.close();
    assert(shown !is null);
    auto got = removedQuotes(shown);
    assert(got.count == 1, shown);
    assert(got.files[0] == "a.c");
    assert(got.spans[0] == "you replace something i said with soething elsem");

    // Attested once for the node, though PostToolUse can be heard twice.
    import quoteremoval : attestRemovals;
    import db : openDb, sqlite3_close, sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize,
                sqlite3_column_text, sqlite3_column_int64, sqlite3_stmt, SQLITE_OK, SQLITE_ROW;
    attestRemovals(sha.text(), r, "sess-removal");
    attestRemovals(sha.text(), r, "sess-removal");
    auto db = openDb();
    assert(db !is null);
    scope (exit) sqlite3_close(db);
    enum sql = "SELECT count(*), max(attributes) FROM attestations "
        ~ "WHERE predicates = '[\"quote:removed\"]' AND contexts LIKE '%sess-removal%'\0";
    sqlite3_stmt* stmt;
    assert(sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) == SQLITE_OK);
    scope (exit) sqlite3_finalize(stmt);
    assert(sqlite3_step(stmt) == SQLITE_ROW);
    assert(sqlite3_column_int64(stmt, 0) == 1);
    auto attrs = sqlite3_column_text(stmt, 1);
    size_t n;
    while (attrs[n] != 0) n++;
    static bool contains(const(char)[] s, const(char)[] what) {
        if (what.length > s.length) return false;
        foreach (i; 0 .. s.length - what.length + 1)
            if (s[i .. i + what.length] == what) return true;
        return false;
    }
    assert(contains(attrs[0 .. n], `"spans":["you replace something i said with soething elsem"]`), attrs[0 .. n]);
    assert(contains(attrs[0 .. n], `"files":["a.c"]`), attrs[0 .. n]);
}
