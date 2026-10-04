module error_result_test;

// An error's message was dropped whenever it carried an exit code or an errno:
// ritual.drive.tree reached the parent as its exit code and nothing else.

import errors : GroundError, formatResult;

unittest {
    GroundError err;
    err.origin = "ritual.drive.tree";
    err.message = "no tree came in ten minutes";
    err.exitCode = 1;
    assert(formatResult(err) == "exit 1: no tree came in ten minutes", formatResult(err));
}

unittest {
    GroundError err;
    err.origin = "exec.mkstemp";
    err.message = "the wrapper script could not be made";
    err.exitCode = -1;
    err.errnoVal = 28;
    assert(formatResult(err) == "start-failed exec.mkstemp errno 28: the wrapper script could not be made",
           formatResult(err));
}

// ground drive on an id with no row ended in signal 11, the store held open:
// an error owed to no session was posted detached, the fork refused, and the
// refusal was such an error too, round again until the stack ran out.
unittest {
    import exec : emitError;
    import db : openDb, sqlite3_close;
    auto held = openDb();
    assert(held !is null);
    emitError("ritual.drive.row", "the driver was started for a performance with no row, so it walked nothing",
              0, 1, "", "", "", "no-such-performance", "");
    sqlite3_close(held);
}

// With no message, an error says only its code.
unittest {
    GroundError err;
    err.origin = "hook.timing";
    err.exitCode = 2;
    assert(formatResult(err) == "exit 2", formatResult(err));
}
