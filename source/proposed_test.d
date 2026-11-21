module proposed_test;

// "we catch what the model wanted to put in there"
// "and place it as a commented block"
// "in my obsidian"
// "so i want everything, (keep the governance) and more (know how it wanted to modify its own governance)"

import proposed : isControl, commentedInto, placeOf, blockInto, rootOf, keepIn, NOTE;
import zbuf : ZBuf;
import matcher : contains;

unittest {
    assert(isControl("/r/controls/stream.pbt"));
    assert(!isControl("/r/controls/README.md"));
    assert(!isControl("/r/a.pbt.md"), "the vault's note of a control is the operator's to write");
}

unittest {
    // Every line commented, so what was proposed is read and never runs.
    __gshared ZBuf b;
    b.reset();
    commentedInto("scope {\n  event: \"Stop\"\n}\n", b);
    assert(b.slice() == "# scope {\n#   event: \"Stop\"\n# }\n");
    b.reset();
    commentedInto("one line, no newline", b);
    assert(b.slice() == "# one line, no newline\n");
}

enum bindings = "syncbvh\tQNTX/Stories\tteranos/QNTX-Web\tmain\tstories\n"
    ~ "syncbvh\tsbvh-nl/l.sbvh.nl\tsbvh-nl/l.sbvh.nl\tmain\t.\n";

unittest {
    // The place the file's repository is bound at in a vault: where the note goes.
    const(char)[] vault;
    __gshared ZBuf place;
    assert(placeOf(bindings, "sbvh-nl/l.sbvh.nl", "controls/stream.pbt", vault, place));
    assert(vault == "syncbvh");
    assert(place.slice() == "sbvh-nl/l.sbvh.nl");
    assert(placeOf(bindings, "teranos/QNTX-Web", "stories/x.pbt", vault, place));
    assert(place.slice() == "QNTX/Stories");
    assert(!placeOf(bindings, "teranos/QNTX-Web", "other/x.pbt", vault, place), "a folder not bound has no place");
    assert(!placeOf(bindings, "teranos/ground", "controls/x.pbt", vault, place));
}

unittest {
    __gshared ZBuf b;
    b.reset();
    blockInto(b, "2026-11-21T13:20:05Z", "sess-1", "sbvh-nl/l.sbvh.nl", "controls/stream.pbt", "scope {\n}\n");
    auto s = b.slice();
    assert(contains(s, "## 2026-11-21T13:20:05Z"));
    assert(contains(s, "controls/stream.pbt"));
    assert(contains(s, "sess-1"));
    assert(contains(s, "# scope {\n# }\n"), "the proposal, commented");
}

unittest {
    assert(rootOf("other\t/a/b\nsyncbvh\t/Users/x/Documents/syncbvh\n", "syncbvh") == "/Users/x/Documents/syncbvh");
    assert(rootOf("other\t/a/b\n", "syncbvh") == "");
}

unittest {
    // The whole of it: a refused control lands in the vault's note, appended.
    import core.stdc.stdio : fopen, fread, fclose, remove, snprintf;
    import core.sys.posix.unistd : getpid, rmdir;
    import db : mkdir;
    char[256] root = 0;
    auto rl = snprintf(root.ptr, root.length, "/tmp/ground-proposed-%d", getpid());
    mkdir(root.ptr, 493);
    char[512] d = 0;
    snprintf(d.ptr, d.length, "%s/sbvh-nl", root.ptr); mkdir(d.ptr, 493);
    snprintf(d.ptr, d.length, "%s/sbvh-nl/l.sbvh.nl", root.ptr); mkdir(d.ptr, 493);

    __gshared ZBuf vaults;
    vaults.reset();
    vaults.put("syncbvh\t");
    vaults.put(root[0 .. rl]);
    vaults.put("\n");

    auto note = keepIn(bindings, vaults.slice(), "sbvh-nl/l.sbvh.nl", "controls/stream.pbt",
                       "scope {\n}\n", "sess-1", "2026-11-21T13:20:05Z");
    assert(note.length > 0, "kept");
    assert(contains(note, NOTE));
    auto again = keepIn(bindings, vaults.slice(), "sbvh-nl/l.sbvh.nl", "controls/other.pbt",
                        "permission {\n}\n", "sess-2", "2026-11-21T13:21:00Z");
    assert(again == note, "one note holds them all");

    char[600] p = 0;
    snprintf(p.ptr, p.length, "%s/sbvh-nl/l.sbvh.nl/%.*s", root.ptr, cast(int) NOTE.length, NOTE.ptr);
    auto f = fopen(p.ptr, "r");
    assert(f !is null);
    __gshared char[8192] got = 0;
    auto n = fread(got.ptr, 1, got.length, f);
    fclose(f);
    assert(contains(got[0 .. n], "# scope {"));
    assert(contains(got[0 .. n], "# permission {"), "the second is appended, the first still there");
    assert(contains(got[0 .. n], "controls/other.pbt"));

    assert(keepIn(bindings, "", "sbvh-nl/l.sbvh.nl", "controls/x.pbt", "x\n", "s", "t").length == 0,
           "a vault ground has not seen on this machine is nowhere to write");

    remove(p.ptr);
    snprintf(d.ptr, d.length, "%s/sbvh-nl/l.sbvh.nl", root.ptr); rmdir(d.ptr);
    snprintf(d.ptr, d.length, "%s/sbvh-nl", root.ptr); rmdir(d.ptr);
    rmdir(root.ptr);
}

// "we should not miss the data"
// The proposal is a row of the store, whole: its lines, quotes and tabs as written.
unittest {
    import proposed : keepInStore, PROPOSED_PREDICATE;
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK, SQLITE_ROW,
        sqlite3_prepare_v2, sqlite3_step, sqlite3_finalize, sqlite3_stmt, sqlite3_column_text;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    enum text = "scope {\n\tevent: \"Stop\"\n  msg: `a \\ b`\n}\n";
    assert(keepInStore(db, "/r/controls/x.pbt", text, "sess-p", "/r"), "said kept only when it is");

    enum q = "SELECT json_extract(attributes, '$.text'), json_extract(attributes, '$.path') FROM attestations "
        ~ "WHERE json_extract(predicates, '$[0]') = 'control:proposed'\0";
    sqlite3_stmt* s;
    assert(sqlite3_prepare_v2(db, q.ptr, -1, &s, null) == SQLITE_OK);
    assert(sqlite3_step(s) == SQLITE_ROW, "the row is there");
    auto t = sqlite3_column_text(s, 0);
    size_t n = 0;
    while (t[n] != 0) n++;
    assert(t[0 .. n] == text, "as it was written");
    sqlite3_finalize(s);
    sqlite3_close(db);
}
