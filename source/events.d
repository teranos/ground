module events;

import hooks : HookEvent;
import core.stdc.stdio : stdout, fwrite;

// The recognized event set, straight from the enum — nothing hand-copied.
immutable string[] eventNames = [__traits(allMembers, HookEvent)];

enum BOOK_COMMAND = q"EOS
# every hook event ground answers to:
ground events
EOS";

int handleEvents() {
    foreach (name; eventNames) {
        fwrite(name.ptr, 1, name.length, stdout);
        fwrite("\n".ptr, 1, 1, stdout);
    }
    return 0;
}

unittest {
    enum members = [__traits(allMembers, HookEvent)];
    assert(eventNames.length == members.length);
    foreach (i, m; members)
        assert(eventNames[i] == m);
}
