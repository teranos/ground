module touch_test;

// teranos/ground#275
// "AND BASH AS WELL WHEN IT TOUCHES A FILE"

version (Posix):

import touch;
import zbuf : ZBuf;
import matcher : indexOf;

// This file, and the top of the tree it is in.
private enum HERE = __FILE_FULL_PATH__;
private enum TOP = HERE[0 .. $ - "/source/touch_test.d".length];

// A tool's event for one file, as Claude Code sends it.
private void toolEvent(ref ZBuf payload, string event, string tool, string key, const(char)[] value) {
    payload.reset();
    payload.put(`{"hook_event_name":"` ~ event ~ `","tool_name":"` ~ tool ~ `","tool_input":{"` ~ key ~ `":"`);
    payload.put(value);
    payload.put(`"}}`);
}

// A file is its repository's: the origin's owner and repo, the commit the
// working tree is at, and the path inside it.
unittest {
    Touched t;
    assert(touched(HERE, t), "this file is in a repository with an origin");
    assert(t.repo() == "teranos/ground", t.repo());
    assert(t.path() == "source/touch_test.d", t.path());
    assert(t.commit().length == 40, t.commit());
    foreach (c; t.commit()) assert((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'), t.commit());
}

// A file in no repository carries none of the three.
unittest {
    Touched t;
    assert(!touched("/etc/hosts", t));
    assert(t.repo().length == 0 && t.commit().length == 0 && t.path().length == 0);
    assert(!touched("relative/path.d", t), "a path that is not whole is in no repository");
}

// A Read names its file on the row, as git writes a path at a commit.
unittest {
    ZBuf contexts, payload;
    contexts.put(`["session:s`);
    toolEvent(payload, "PreToolUse", "Read", "file_path", HERE);
    putTouched(contexts, "PreToolUse", TOP, payload.slice());
    auto said = contexts.slice();
    assert(indexOf(said, `","file:teranos/ground@`) >= 0, said);
    assert(indexOf(said, `:source/touch_test.d`) >= 0, said);
}

// A command names the files its words are, read from where it runs and from
// where a cd in it moved to, once each; a word that is no file is none.
unittest {
    ZBuf files;
    auto n = namedFiles("cat source/touch_test.d | head -3 && cd source && wc -l 'touch.d' touch_test.d nothere.d > /dev/null", TOP, files);
    assert(n == 2, "two files are named, one of them twice");
    auto all = files.slice();
    assert(indexOf(all, TOP ~ "/source/touch_test.d\0") == 0, all);
    assert(indexOf(all, TOP ~ "/source/touch.d\0") > 0, all);

    ZBuf contexts, payload;
    contexts.put(`["session:s`);
    toolEvent(payload, "PostToolUse", "Bash", "command", "grep -n module source/touch.d /etc/hosts");
    putTouched(contexts, "PostToolUse", TOP, payload.slice());
    auto said = contexts.slice();
    assert(indexOf(said, `:source/touch.d`) >= 0, said);
    assert(indexOf(said, `hosts`) < 0, "a file in no repository was named on the row");
}

// A row that is no tool's, or a tool that touches no file, is as it was.
unittest {
    ZBuf contexts, payload;
    contexts.put(`["session:s`);
    putTouched(contexts, "Stop", TOP, `{"hook_event_name":"Stop"}`);
    toolEvent(payload, "PreToolUse", "WebSearch", "query", "x");
    putTouched(contexts, "PreToolUse", TOP, payload.slice());
    assert(contexts.slice() == `["session:s`, contexts.slice());
}
