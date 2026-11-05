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
