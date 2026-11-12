module touch_test;

// teranos/ground#275
// "AND BASH AS WELL WHEN IT TOUCHES A FILE"
// "WE SHOULD CONSIDER A OBSIDIAN VAULT ITS OWN THING"
// "ON THE SAME ABSTRACTION LEVEL AS REPO, AND/OR KNOW ABOUT BINDINGS"

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
    payload.put(`{"hook_event_name":"`);
    payload.put(event);
    payload.put(`","tool_name":"`);
    payload.put(tool);
    payload.put(`","tool_input":{"`);
    payload.put(key);
    payload.put(`":"`);
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

// A note is its vault's: the directory that holds .obsidian, by its name,
// and the note's path inside it. A vault that is no repository is still one.
unittest {
    import core.stdc.stdio : snprintf, fopen, fputs, fclose;
    import core.sys.posix.stdlib : setenv;
    import core.sys.posix.unistd : getpid;
    import db : mkdir;
    char[256] top = 0, dot = 0, sub = 0, note = 0;
    auto tn = snprintf(top.ptr, top.length, "/tmp/ground-vault-%d", getpid());
    mkdir(top.ptr, 448);
    snprintf(dot.ptr, dot.length, "/tmp/ground-vault-%d/garden", getpid());
    mkdir(dot.ptr, 448);
    snprintf(dot.ptr, dot.length, "/tmp/ground-vault-%d/garden/.obsidian", getpid());
    mkdir(dot.ptr, 448);
    snprintf(sub.ptr, sub.length, "/tmp/ground-vault-%d/garden/Beds", getpid());
    mkdir(sub.ptr, 448);
    auto nn = snprintf(note.ptr, note.length, "/tmp/ground-vault-%d/garden/Beds/Pond notes.md", getpid());
    auto f = fopen(note.ptr, "w");
    assert(f !is null);
    fputs("the pond", f);
    fclose(f);

    const(char)[] vault, inVault;
    assert(vaultOf(note[0 .. nn], vault, inVault), "a note under .obsidian's directory is in no vault");
    assert(vault == "garden", vault);
    assert(inVault == "Beds/Pond notes.md", inVault);
    assert(!vaultOf(HERE, vault, inVault), "a source file was taken for a note");

    ZBuf contexts, payload;
    contexts.put(`["session:s`);
    toolEvent(payload, "PreToolUse", "Read", "file_path", note[0 .. nn]);
    putTouched(contexts, "PreToolUse", top[0 .. tn], payload.slice());
    assert(contexts.slice() == `["session:s","vault:garden:Beds/Pond notes.md`, contexts.slice());

    // Bound at the node, the note is the repository's file as well.
    setenv("HOME", top.ptr, 1);
    char[256] share = 0;
    snprintf(share.ptr, share.length, "/tmp/ground-vault-%d/.local", getpid());
    mkdir(share.ptr, 448);
    snprintf(share.ptr, share.length, "/tmp/ground-vault-%d/.local/share", getpid());
    mkdir(share.ptr, 448);
    snprintf(share.ptr, share.length, "/tmp/ground-vault-%d/.local/share/ground", getpid());
    mkdir(share.ptr, 448);
    auto kept = fopen(bindingsFile(), "w");
    assert(kept !is null);
    fputs("garden\tBeds\tacme/garden-docs\tmain\tdocs/beds\n", kept);
    fclose(kept);
    contexts.reset();
    contexts.put(`["session:s`);
    putTouched(contexts, "PreToolUse", top[0 .. tn], payload.slice());
    assert(contexts.slice() == `["session:s","vault:garden:Beds/Pond notes.md","file:acme/garden-docs@main:docs/beds/Pond notes.md`, contexts.slice());
}

// What a node says is bound, as the lines ground keeps; and a note's place
// among them: the note's own binding, the nearest folder above it, the top of
// a repository, or none.
unittest {
    enum answer = `{"vaults":[{"name":"syncbvh","path":"/var/lib/obsidian/syncbvh","folders":["github.com/teranos/QNTX@main:docs/adr=QNTX/ADR","github.com/teranos/QNTX@main:AGENTS.md=QNTX/AgentInstructions/QNTX/AGENTS.md","github.com/teranos/ground@main:.=teranos/ground","github.com/sbvh-nl/ramen@master:SPEC.md=ramen/SPEC.md"],"disabled":[]}]}`;
    ZBuf lines;
    assert(bindingsFrom(answer, lines) == 4, lines.slice());
    assert(indexOf(lines.slice(), "syncbvh\tQNTX/ADR\tteranos/QNTX\tmain\tdocs/adr\n") == 0, lines.slice());

    const(char)[] repo, branch;
    ZBuf path;
    assert(boundTo(lines.slice(), "syncbvh", "QNTX/ADR/ADR-059-Harness-is-a-Plugin.md", repo, branch, path));
    assert(repo == "teranos/QNTX" && branch == "main" && path.slice() == "docs/adr/ADR-059-Harness-is-a-Plugin.md", path.slice());
    assert(boundTo(lines.slice(), "syncbvh", "QNTX/AgentInstructions/QNTX/AGENTS.md", repo, branch, path));
    assert(repo == "teranos/QNTX" && path.slice() == "AGENTS.md", path.slice());
    assert(boundTo(lines.slice(), "syncbvh", "teranos/ground/doc/book/attestation.md", repo, branch, path));
    assert(repo == "teranos/ground" && path.slice() == "doc/book/attestation.md", path.slice());
    assert(boundTo(lines.slice(), "syncbvh", "ramen/SPEC.md", repo, branch, path));
    assert(repo == "sbvh-nl/ramen" && branch == "master" && path.slice() == "SPEC.md", path.slice());
    assert(!boundTo(lines.slice(), "syncbvh", "QNTX/2026-11-12.md", repo, branch, path), "a note in no bound place was given a repository");
    assert(!boundTo(lines.slice(), "another", "QNTX/ADR/x.md", repo, branch, path), "another vault's note was given this one's binding");
    assert(!boundTo(lines.slice(), "syncbvh", "QNTX/ADRs/x.md", repo, branch, path), "a folder whose name only begins alike was taken for the bound one");
}
