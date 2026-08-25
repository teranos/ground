module spawn_test;

// A ritual is named from anywhere, so its project path is a locator rather
// than a test against cwd. The declared projects carry the absolute path.

import proto : parsePbt;
import ritual : repoRoot, spawnScript;

enum src = `
project { path: "/home/u/src/proj" }
project { path: "/home/u/src/other" }

rites walk { START { eval: "true" } }

project {
  path: "/src/proj"
  ritual probe { walk }
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
// GROUND_PERFORMANCE is what the agent answers with when asked what it carries.
enum s = spawnScript("/home/u/src/proj", "probe-17", "probe-17", "Performing ritual probe.");
static assert(s.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\ncd '/home/u/src/proj'\n"
    ~ "export GROUND_PERFORMANCE='probe-17'\n"
    ~ "claude -w 'probe-17' --bg --permission-mode dontAsk 'Performing ritual probe.'\n");

// --bg and not -p. Print mode is one shot and detached, reachable by nothing
// but pkill; a background session is in `claude agents`, where it can be
// peeked at, replied to, attached to, and stopped without a signal.
enum bg = spawnScript("/r", "p-1", "p-1", "go");
static assert(bg.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\ncd '/r'\n"
    ~ "export GROUND_PERFORMANCE='p-1'\n"
    ~ "claude -w 'p-1' --bg --permission-mode dontAsk 'go'\n");

// "define a CLAUDE.md inline in a ritual" — appended, not replacing, because
// a CLAUDE.md adds to what an agent already is.
enum sys = spawnScript("/r", "p-1", "p-1", "go", "You are a Specialist in Targeted Advertisement Campaigns.");
static assert(sys.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\ncd '/r'\n"
    ~ "export GROUND_PERFORMANCE='p-1'\n"
    ~ "claude -w 'p-1' --bg --permission-mode dontAsk "
    ~ "--append-system-prompt 'You are a Specialist in Targeted Advertisement Campaigns.' "
    ~ "'go'\n");

// A ritual that says nothing about it spawns exactly as before.
static assert(spawnScript("/r", "p-1", "p-1", "go", "").text() == bg.text());

// No tree named, no -w. The flag is the whole of the request, so leaving it off
// is how an agent works in the place the push happened rather than beside it.
enum here = spawnScript("/r", "", "p-2", "go");
static assert(here.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\ncd '/r'\n"
    ~ "export GROUND_PERFORMANCE='p-2'\n"
    ~ "claude --bg --permission-mode dontAsk 'go'\n");

// In place the tree cannot say which performance an agent carries: a session a
// person opened in that same checkout answers to it too. The id can.
static assert(here.text() != spawnScript("/r", "", "p-3", "go").text());

// The prompt is built from a rite's msg and cmd, so it carries whatever those
// carry — including a quote that would end the argument early.
enum q = spawnScript("/r", "p-1", "p-1", "say 'hi' now");
static assert(q.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\ncd '/r'\n"
    ~ "export GROUND_PERFORMANCE='p-1'\n"
    ~ "claude -w 'p-1' --bg --permission-mode dontAsk 'say '\\''hi'\\'' now'\n");

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

// The ending ends the agent — reap_test.d, which selects on the session.

// Ground opens no pull request and writes no commit. "making a PR at the end
// of each DONE was a mistake" — a ritual that wants either says so in a rite,
// where the gh invocation is visible in the pbt rather than built in here.
static assert(!__traits(compiles, { import ritual : prScript; }));
static assert(!__traits(compiles, { import ritual : commitScript; }));
