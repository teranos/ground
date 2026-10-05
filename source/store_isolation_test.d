module store_isolation_test;

// Every test that ended in an error wrote it into the real store: advance_test's
// WEIRD halt left 586 immediate:exec-result rows under session:sess by
// 2026-10-04, one run at a time. A test process opens a store of its own.

import db : storePath;
import core.stdc.string : strstr;

unittest {
    auto p = storePath();
    assert(p !is null);
    assert(strstr(p, ".local/share/ground") is null, "a test never opens the real store");
    assert(strstr(p, "ground-unittest-") !is null, "it opens one of its own, named for the test run");
}

// An error a test raised and no store took was appended to the real
// errors/.log: ritual.drive.row at every test run on 2026-10-04.
unittest {
    import errors : breadcrumbDirInto;
    char[512] buf = 0;
    assert(breadcrumbDirInto(buf) > 0);
    assert(strstr(&buf[0], ".local/share/ground") is null, "a test never leaves a breadcrumb beside the real store");
    assert(strstr(&buf[0], "ground-unittest-") !is null, "it leaves it beside its own");
}

// The files kept beside the store go where the store went. On a fresh CI
// runner ~/.local/share/ground was only ever made by the store's open, and
// with the store moved, writeIntent had no directory to write into.
unittest {
    import sky : buildGroundPath;
    __gshared char[512] buf = 0;
    assert(buildGroundPath(buf, "ritual-intent-", "x", ".id") > 0);
    assert(strstr(&buf[0], ".local/share/ground") is null, "a test never writes beside the real store");
    assert(strstr(&buf[0], "ground-unittest-") !is null, "it writes beside its own");
}
