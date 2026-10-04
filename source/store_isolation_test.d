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
