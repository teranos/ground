module spawn_test;

// A ritual is named from anywhere, so its project path is a locator rather
// than a test against cwd. The declared projects carry the absolute path.

import proto : parsePbt;
import ritual : repoRoot, spawnScript;
import matcher : indexOf;

enum src = `
project {
  path: "/home/u/src/proj"
}
project {
  path: "/home/u/src/other"
}

rites walk {
  START {
    eval: "true"
  }
}

project {
  path: "/src/proj"
  ritual probe {
    walk
  }
}
`;
enum parsed = parsePbt(src);

// The ritual says /src/proj; the declared project says where that is.
enum root = repoRoot(parsed, "/src/proj");
static assert(root == "/home/u/src/proj");

// A suffix that matches nothing declared has no root, and a performance
// cannot be put anywhere. Better than guessing a directory.
static assert(repoRoot(parsed, "/src/nothing") == "");

// A path that is already absolute is its own root.
static assert(repoRoot(parsed, "/home/u/src/other") == "/home/u/src/other");

// The command that starts the agent. -w names the tree, and ground's own
// WorktreeCreate handler places it, so the path is known before it exists.
// What the start prints is handed to `ground bind`, which is how a performance
// learns who carries it. An exported variable reached the agent from the claude
// daemon's environment and not from this script, naming a performance long over.
// 「[Opus 5.5] What it printed, stdout and stderr, and how it exited are handed over whole: a start that failed」
// 「[Opus 5.5] is said by bind to the session that fired the ritual, and the script exits as the start did.」
// 「[Opus 5.5] Bind's own answer does not end the script first: it exits as the start did, and as bind did」
// 「[Opus 5.5] when the start worked and bind could not bind it.」
private enum bound(string perf) = "printf '%s\\n' \"$said\"\n"
    ~ "printf '%s\\n' \"$said\" | ground bind '" ~ perf ~ "' \"$started\" && bound=0 || bound=$?\n"
    ~ "if [ \"$started\" != 0 ]; then exit \"$started\"; fi\n"
    ~ "exit \"$bound\"\n";

enum s = spawnScript("/home/u/src/proj", "probe-17", "probe-17", "Performing ritual probe.");
static assert(s.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\ncd '/home/u/src/proj'\n"
    ~ "said=$(claude -w 'probe-17' --bg --permission-mode dontAsk 'Performing ritual probe.' 2>&1) && started=0 || started=$?\n"
    ~ bound!("probe-17"));

// --bg and not -p. Print mode is one shot and detached, reachable by nothing
// but pkill; a background session is in `claude agents`, where it can be
// peeked at, replied to, attached to, and stopped without a signal.
enum bg = spawnScript("/r", "p-1", "p-1", "go");
static assert(bg.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\ncd '/r'\n"
    ~ "said=$(claude -w 'p-1' --bg --permission-mode dontAsk 'go' 2>&1) && started=0 || started=$?\n"
    ~ bound!("p-1"));

// "define a CLAUDE.md inline in a ritual" — appended, not replacing, because
// a CLAUDE.md adds to what an agent already is.
enum sys = spawnScript("/r", "p-1", "p-1", "go", "You are a Specialist in Targeted Advertisement Campaigns.");
static assert(sys.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\ncd '/r'\n"
    ~ "said=$(claude -w 'p-1' --bg --permission-mode dontAsk "
    ~ "--append-system-prompt 'You are a Specialist in Targeted Advertisement Campaigns.' "
    ~ "'go' 2>&1) && started=0 || started=$?\n"
    ~ bound!("p-1"));

// A ritual that says nothing about it spawns exactly as before.
static assert(spawnScript("/r", "p-1", "p-1", "go", "").text() == bg.text());

// The model already resolved for this performance goes to claude as its flag.
enum model = spawnScript("/r", "p-1", "p-1", "go", "", "sonnet");
static assert(model.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\ncd '/r'\n"
    ~ "said=$(claude -w 'p-1' --bg --permission-mode dontAsk --model 'sonnet' 'go' 2>&1) && started=0 || started=$?\n"
    ~ bound!("p-1"));

// A model and a system prompt together, each its own flag.
enum both = spawnScript("/r", "p-1", "p-1", "go", "Be brief.", "fable");
static assert(both.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\ncd '/r'\n"
    ~ "said=$(claude -w 'p-1' --bg --permission-mode dontAsk --model 'fable' "
    ~ "--append-system-prompt 'Be brief.' 'go' 2>&1) && started=0 || started=$?\n"
    ~ bound!("p-1"));

// "the same rules for ritual agents should apply to subagents, they should cohere"
// No effort is named at the start: how hard the model thinks is its own
// setting, which the usage windows move.
static assert(indexOf(model.text(), "--effort") < 0);

// No model resolved is no flag.
static assert(spawnScript("/r", "p-1", "p-1", "go", "", "").text() == bg.text());

// No tree named, no -w. The flag is the whole of the request, so leaving it off
// is how an agent works in the place the push happened rather than beside it.
enum here = spawnScript("/r", "", "p-2", "go");
static assert(here.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\ncd '/r'\n"
    ~ "said=$(claude --bg --permission-mode dontAsk 'go' 2>&1) && started=0 || started=$?\n"
    ~ bound!("p-2"));

// In place the tree cannot say which performance an agent carries: a session a
// person opened in that same checkout answers to it too. The id can.
static assert(here.text() != spawnScript("/r", "", "p-3", "go").text());

// The prompt is built from a rite's msg and cmd, so it carries whatever those
// carry — including a quote that would end the argument early.
enum q = spawnScript("/r", "p-1", "p-1", "say 'hi' now");
static assert(q.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\ncd '/r'\n"
    ~ "said=$(claude -w 'p-1' --bg --permission-mode dontAsk 'say '\\''hi'\\'' now' 2>&1) && started=0 || started=$?\n"
    ~ bound!("p-1"));

// A prompt too big for the buffer used to lose its closing quote, and sh got a
// different command than the one built. Overflow refuses instead — the same
// answer reapScript already gives when it has no id to reap.
private template rep(string s, int n) {
    static if (n <= 0) enum rep = "";
    else enum rep = s ~ rep!(s, n - 1);
}
private enum k100 = rep!("aaaaaaaaaa", 10);
private enum k1000 = rep!(k100, 10);

enum huge = spawnScript("/r", "p-1", "p-1", rep!(k1000, 9));
static assert(huge.text().length == 0);

// The last prompt that fits still fits.
enum snug = spawnScript("/r", "p-1", "p-1", rep!(k1000, 7));
static assert(snug.text().length > 0);

// "you COULD if you wanted to run an agent like that, equiped with ritual"
// "i think a ritual cant run longer than one compaction window"
// "it a high upper bound"
// "WHEN A RITUAL RUNS IT PICKS UP FROM THE PREVIOUS -BG SESSION"
// "ITS THE SAME -BG SESSION THAT IS THE SAME ENTITY"
enum again = spawnScript("/r", "", "p-4", "go", "", "", "2f7c2b1f-0762-47b4-8e87-13b41c67be5e");
static assert(again.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\ncd '/r'\n"
    ~ "said=$(claude --bg --resume '2f7c2b1f-0762-47b4-8e87-13b41c67be5e' --permission-mode dontAsk 'go' 2>&1) && started=0 || started=$?\n"
    ~ bound!("p-4"));

// A ritual that has never run has no session to pick up, and starts one.
static assert(spawnScript("/r", "", "p-2", "go", "", "", "").text() == here.text());

// The session to pick up is the one that carried the ritual's latest
// performance in its project. A performance whose agent was never bound
// carried nobody.
unittest {
    import ritual : lastSessionOf, writePosition, start;
    import db : sqlite3, sqlite3_open, sqlite3_close, applySchema, SQLITE_OK;

    sqlite3* db;
    assert(sqlite3_open(":memory:\0".ptr, &db) == SQLITE_OK);
    assert(applySchema(db));

    void performed(string ritual, string id, string session) {
        auto p = start(ritual, 1);
        p.id = id;
        p.repo = "/src/proj";
        p.rites = "START";
        p.agentSession = session;
        assert(writePosition(db, p));
    }

    assert(lastSessionOf(db, "probe", "/src/proj") is null);
    performed("probe", "probe-1", "aaaa");
    performed("probe", "probe-2", "bbbb");
    performed("probe", "probe-3", "");
    performed("other", "other-1", "cccc");
    assert(lastSessionOf(db, "probe", "/src/proj") == "bbbb");
    assert(lastSessionOf(db, "probe", "/src/else") is null);

    // A dead performance halted after a later one started is not the later one.
    import db : sqlite3_exec;
    assert(sqlite3_exec(db, "UPDATE ritual_position SET updated_at = datetime('now', '+1 hour') WHERE id = 'probe-1'\0".ptr,
                        null, null, null) == SQLITE_OK);
    assert(lastSessionOf(db, "probe", "/src/proj") == "bbbb");
    sqlite3_close(db);
}

// The ending ends the agent — reap_test.d, which selects on the session.

// Ground opens no pull request and writes no commit. "making a PR at the end
// of each DONE was a mistake" — a ritual that wants either says so in a rite,
// where the gh invocation is visible in the pbt rather than built in here.
static assert(!__traits(compiles, { import ritual : prScript; }));
static assert(!__traits(compiles, { import ritual : commitScript; }));

// "An Error is the entity any layer emits when something breaks intention"
// "Only pure distilled signal over anything else"
// 「[Opus 5.5] What bind says of a start, to the session that fired the ritual: nothing of one that named its」
// 「[Opus 5.5] agent, and why of one that exited otherwise or named none.」
unittest {
    import ritual : startSays;
    import code.reply : Reply;
    Reply r;
    scope(exit) r.dispose();
    startSays(r, 0, "ce9c80d5", "backgrounded · ce9c80d5\n");
    assert(r.slice() == "");
    startSays(r, 1, "", "error: daemon not running\n");
    assert(r.slice() == "the start of the performance's agent exited 1: error: daemon not running\n");
    r.dispose();
    startSays(r, 0, "", "something else\n");
    assert(r.slice() == "the start printed no agent id, so this performance has an agent ground cannot stop: something else\n");
    r.dispose();
    // 「[Opus 5.5] What it printed is carried whole: the reason is at the end of a long one.」
    __gshared char[9000] long_ = 'v';
    long_[$ - 6 .. $] = "REASON";
    startSays(r, 3, "", long_[]);
    assert(r.slice()[$ - 6 .. $] == "REASON");
}
