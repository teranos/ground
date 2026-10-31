module store_aside_test;

// A hook whose timing row the store refused used to be delivered into the
// session as an exec-result: every busy minute of the store, a line of chat.

// "its kind of wastefull to spam the session chats like this, we have sentry for that kind of observability. and ramen should show me visually"

import errors : breadcrumbDirInto, deliverAside, GroundError;
import core.stdc.stdio : fclose, fopen, fread;
import core.stdc.string : strstr;

// Said aside, the error lands in the session's breadcrumb, with the phases
// that say how long the store held the hook, and nowhere a session reads.
unittest {
    GroundError err;
    err.origin      = "hook.timing";
    err.message     = "the store refused this hook's timing row: sqlite code 005";
    err.exitCode    = 5;
    err.sessionId   = "aside-test-session";
    err.controlName = "hook.timing";
    err.timestamp   = 1_793_372_283;
    err.stdout      = "stdin=35us open=1096us write=5036943us lock=5000532us close=94us";
    assert(deliverAside(err) == "breadcrumb", "it lands in the breadcrumb, not the store");

    char[512] dir = 0;
    auto p = breadcrumbDirInto(dir);
    assert(p > 0);
    char[768] path = 0;
    size_t q;
    foreach (i; 0 .. p) path[q++] = dir[i];
    foreach (c; "/aside-test-session.log") path[q++] = c;
    auto f = fopen(&path[0], "r");
    assert(f !is null, "the session's breadcrumb file is there");
    static char[4096] text = 0;
    auto n = fread(&text[0], 1, text.length - 1, f);
    fclose(f);
    text[n] = 0;
    assert(strstr(&text[0], "hook.timing\thook.timing\texit=5\terrno=0\tthe store refused this hook's timing row: sqlite code 005") !is null,
           "the line says which store, which code");
    assert(strstr(&text[0], "lock=5000532us") !is null, "and how long the hook was held");
}
