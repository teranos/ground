module roots_test;

// A file read or written through the client is the session's own when it stands in the session's
// cwd or one of its additionalDirectories. Plan mode ran every read, and Accept edits every write,
// wherever the model's path pointed: ~/.ssh read without asking, ~/.bashrc written without asking.

import code.acp : withinRoots, modeVerdict, Verdict;
import sessionmode : SessionMode;

// In the cwd, at any depth, or in an additional root.
static assert(withinRoots("/w/repo", `["/w/other"]`, "/w/repo/src/a.d"));
static assert(withinRoots("/w/repo", `["/w/other"]`, "/w/repo"));
static assert(withinRoots("/w/repo", `["/w/other"]`, "/w/other/x"));
static assert(withinRoots("/w/repo/", "", "/w/repo/a"));

// Beside it, above it, under a name that only starts the same, or climbing out of it, is not.
static assert(!withinRoots("/w/repo", `["/w/other"]`, "/w/repository/a"));
static assert(!withinRoots("/w/repo", `["/w/other"]`, "/home/u/.ssh/id_rsa"));
static assert(!withinRoots("/w/repo", `["/w/other"]`, "/w/repo/../../home/u/.bashrc"));
static assert(!withinRoots("/w/repo", `["/w/other"]`, "/w/repo/./../x"));
static assert(!withinRoots("/w/repo", "", "relative/a"));
static assert(!withinRoots("", "", "/w/repo/a"));

// Plan runs what reads, in the session's roots; a read outside them is asked.
static assert(modeVerdict(SessionMode.plan, false, false, true, false, false) == Verdict.run);
static assert(modeVerdict(SessionMode.plan, false, false, true, false, true) == Verdict.ask);
static assert(modeVerdict(SessionMode.plan, false, false, false, false, false) == Verdict.refuse);

// Accept edits runs an edit in the session's roots; one outside them is asked.
static assert(modeVerdict(SessionMode.acceptEdits, false, false, false, true, false) == Verdict.run);
static assert(modeVerdict(SessionMode.acceptEdits, false, false, false, true, true) == Verdict.ask);

// What the user said to always allow or reject, and the modes that ask nothing, are as they were.
static assert(modeVerdict(SessionMode.acceptEdits, true, false, false, true, true) == Verdict.run);
static assert(modeVerdict(SessionMode.manual, false, true, false, true, false) == Verdict.refuse);
static assert(modeVerdict(SessionMode.bypassPermissions, false, false, false, true, true) == Verdict.run);
static assert(modeVerdict(SessionMode.dontAsk, false, false, true, false, false) == Verdict.refuse);
static assert(modeVerdict(SessionMode.manual, false, false, true, false, false) == Verdict.ask);

// A request's own params, not the first text that reads "params": one in _meta, or quoted in a
// string, came first and was taken for the request's.
import code.acp : objectValue, memberValue, sameId;
static assert(objectValue(`{"id":1,"_meta":{"params":{"x":1}},"params":{"y":2}}`, `"params"`) == `{"y":2}`);
static assert(objectValue(`{"note":"\"params\":{\"z\":1}","params":{"y":2}}`, `"params"`) == `{"y":2}`);
static assert(objectValue(`{"params":[1]}`, `"params"`) is null);
static assert(objectValue(`{"id":1}`, `"params"`) is null);
static assert(memberValue(`{"params":[1],"id":2}`, `"params"`) == `[1]`);
static assert(memberValue(`{ "params" : "s" }`, `"params"`) == `"s"`);

// A cancel names a request by its id, however the client spelled it.
static assert(sameId(`"a"`, `"a"`));
static assert(sameId(`"a"`, `"a"`));
static assert(sameId(`"a\/b"`, `"a/b"`));
static assert(sameId(`7`, `7`));
static assert(!sameId(`"b"`, `"a"`));
static assert(!sameId(`7`, `"7"`));

// As the disk resolves them: a link in the roots to a file outside them is outside, and a path
// that resolves to nothing, nor its directory, is not known to be in them.
unittest {
    import code.acp : withinRootsOnDisk;
    import core.sys.posix.stdlib : mkdtemp;
    import core.sys.posix.unistd : symlink, unlink, rmdir;
    import core.stdc.stdio : fopen, fclose, snprintf;
    import errors : mkdir;
    char[64] base = "/tmp/ground-roots-XXXXXX\0";
    assert(mkdtemp(base.ptr) !is null);
    size_t n = 0;
    while (base[n] != 0) n++;
    char[256] repo = 0, outside = 0, link = 0, inside = 0, linkdir = 0, fresh = 0;
    snprintf(repo.ptr, repo.length, "%s/repo", base.ptr);
    snprintf(outside.ptr, outside.length, "%s/secret", base.ptr);
    snprintf(link.ptr, link.length, "%s/repo/link", base.ptr);
    snprintf(inside.ptr, inside.length, "%s/repo/a", base.ptr);
    snprintf(linkdir.ptr, linkdir.length, "%s/repo/out", base.ptr);
    snprintf(fresh.ptr, fresh.length, "%s/repo/out/new", base.ptr);
    assert(mkdir(repo.ptr, 493) == 0);
    auto f = fopen(outside.ptr, "w"); fclose(f);
    f = fopen(inside.ptr, "w"); fclose(f);
    assert(symlink(outside.ptr, link.ptr) == 0);
    assert(symlink(base.ptr, linkdir.ptr) == 0);
    scope(exit) { unlink(link.ptr); unlink(linkdir.ptr); unlink(inside.ptr); unlink(outside.ptr); rmdir(repo.ptr); rmdir(base.ptr); }
    size_t len(const(char)[] b) { size_t k = 0; while (b[k] != 0) k++; return k; }
    auto r = repo[0 .. len(repo)];

    assert(withinRootsOnDisk(r, "", inside[0 .. len(inside)]));
    // A file not there yet stands where its directory does.
    char[256] made = 0;
    snprintf(made.ptr, made.length, "%s/repo/b", base.ptr);
    assert(withinRootsOnDisk(r, "", made[0 .. len(made)]));
    assert(!withinRootsOnDisk(r, "", link[0 .. len(link)]), "a link to a file outside is outside");
    assert(!withinRootsOnDisk(r, "", fresh[0 .. len(fresh)]), "a new file under a linked directory outside is outside");
    char[256] nowhere = 0;
    snprintf(nowhere.ptr, nowhere.length, "%s/repo/no/such/file", base.ptr);
    assert(!withinRootsOnDisk(r, "", nowhere[0 .. len(nowhere)]), "what resolves to nothing is not known to be in");
}
