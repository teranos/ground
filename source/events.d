module events;

import hooks : HookEvent;
import core.stdc.stdio : stdout, fwrite;

// The recognized event set, straight from the enum — nothing hand-copied.
immutable string[] eventNames = [__traits(allMembers, HookEvent)];

// BOOK_COMMAND **ground events**: Prints every hook event ground recognises, straight from the enum.
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
