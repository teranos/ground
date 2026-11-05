module breadcrumb_test;

// A breadcrumb lands in the directory its path names, or nowhere: a home longer than the path
// holds was cut, and the breadcrumb was written into the directory the cut named, which is not
// the one anyone reads.
import errors : errorsDirIn, crumbPathIn;

unittest {
    char[512] dir = 0;
    auto n = errorsDirIn("/h", dir);
    assert(dir[0 .. n] == "/h/.local/share/ground/errors");
    assert(dir[n] == 0);

    char[600] longHome = 'a';
    longHome[0] = '/';
    assert(errorsDirIn(longHome[], dir) == 0, "what does not fit is no directory");

    char[768] path = 0;
    auto m = crumbPathIn(dir[0 .. n], "sess-1", path);
    assert(path[0 .. m] == "/h/.local/share/ground/errors/sess-1.log");
    char[800] longSession = 's';
    assert(crumbPathIn(dir[0 .. n], longSession[], path) == 0, "what does not fit is no path");
}

// An error is carried whole however long it is: the breadcrumb's line was 2048 bytes and the
// exec-result row's attributes 4096, and a message past either was cut, or the row not written.
unittest {
    import errors : GroundError, crumbLine;
    import code.reply : Reply;
    import matcher : indexOf;
    __gshared char[6000] long_ = 'x';
    long_[$ - 4 .. $] = "TAIL";
    GroundError err;
    err.origin = "sandload";
    err.exitCode = -1;
    err.message = cast(string) long_[];
    err.stderr = "the end of stderr";
    Reply line;
    scope(exit) line.dispose();
    crumbLine(line, err);
    assert(!line.full);
    assert(indexOf(line.slice(), "xTAIL\n") >= 0);
    assert(indexOf(line.slice(), "    the end of stderr\n") >= 0);
}

unittest {
    import immediate : writeExecResult;
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK, sqlite3_prepare_v2,
        sqlite3_step, sqlite3_finalize, sqlite3_stmt, sqlite3_column_text, SQLITE_ROW;
    import matcher : indexOf;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    scope(exit) sqlite3_close(db);
    __gshared char[6000] long_ = 'y';
    long_[$ - 4 .. $] = "TAIL";
    assert(writeExecResult(db, "sess-long", "sandload", long_[], "", ""), "a long result is written");
    sqlite3_stmt* st;
    assert(sqlite3_prepare_v2(db, "SELECT attributes FROM attestations WHERE predicates = '[\"immediate:exec-result\"]'\0".ptr, -1, &st, null) == SQLITE_OK);
    assert(sqlite3_step(st) == SQLITE_ROW);
    auto p = sqlite3_column_text(st, 0);
    size_t n = 0;
    while (p[n] != 0) n++;
    auto attrs = (cast(const(char)*) p)[0 .. n];
    assert(indexOf(attrs, `yTAIL","after":0}`) >= 0, attrs[n > 80 ? n - 80 : 0 .. n]);
    sqlite3_finalize(st);
}

// What deliverError hands the store is whole: formatResult held 4095 bytes, so a longer message
// reached the growing writer already cut.
unittest {
    import errors : GroundError, formatResult;
    __gshared char[6000] long_ = 'z';
    long_[$ - 4 .. $] = "TAIL";
    GroundError err;
    err.origin = "sandload";
    err.exitCode = 1;
    err.message = cast(string) long_[];
    auto r = formatResult(err);
    assert(r.length == "exit 1: ".length + long_.length);
    assert(r[$ - 4 .. $] == "TAIL");
}

// stderr, the last channel, carries what the breadcrumb would have: the message and both streams.
unittest {
    import errors : GroundError, stderrRecord;
    import code.reply : Reply;
    import matcher : indexOf;
    GroundError err;
    err.origin = "exec.script";
    err.exitCode = 2;
    err.message = "grandchild exited";
    err.stdout = "what it printed";
    err.stderr = "why it failed";
    Reply rec;
    scope(exit) rec.dispose();
    stderrRecord(rec, err);
    assert(indexOf(rec.slice(), "ground error: exec.script: grandchild exited\n") == 0, rec.slice());
    assert(indexOf(rec.slice(), "  stdout:\n    what it printed\n") >= 0, rec.slice());
    assert(indexOf(rec.slice(), "  stderr:\n    why it failed\n") >= 0, rec.slice());
}

// A detail longer than a delivery carries is said to be, with the row that holds all of it: cut
// silently, the watcher receipted the prefix, and the tail, where the reason is, never came.
unittest {
    import immediate : writeExecResult, readImmediateMessage, MESSAGE_CAP;
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;
    import matcher : indexOf;
    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));
    scope(exit) sqlite3_close(db);
    __gshared char[MESSAGE_CAP + 4000] long_ = 'w';
    assert(writeExecResult(db, "sess-cut", "ritual", long_[], "", ""));
    auto got = readImmediateMessage(db, "/tmp", "sess-cut");
    assert(got.message !is null);
    assert(got.message.length <= MESSAGE_CAP);
    assert(indexOf(got.message, "[ground cut this message at ") >= 0, got.message[$ - 200 .. $]);
    assert(indexOf(got.message, got.msgId) >= 0, "the cut names the row that holds all of it");
}
