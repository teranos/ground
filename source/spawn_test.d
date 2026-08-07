module spawn_test;

// A ritual is named from anywhere, so its project path is a locator rather
// than a test against cwd. The declared projects carry the absolute path.

import proto : parsePbt;
import ritual : repoRoot, spawnScript;

enum src = `
project { path: "/home/u/src/proj" }
project { path: "/home/u/src/other" }

rites walk { START { cmd: "true" } }

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
enum s = spawnScript("/home/u/src/proj", "probe-17", "Performing ritual probe.");
static assert(s.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\ncd '/home/u/src/proj'\n"
    ~ "claude -w 'probe-17' -p 'Performing ritual probe.'\n");

// The prompt is built from a rite's msg and cmd, so it carries whatever those
// carry — including a quote that would end the argument early.
enum q = spawnScript("/r", "p-1", "say 'hi' now");
static assert(q.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\ncd '/r'\n"
    ~ "claude -w 'p-1' -p 'say '\\''hi'\\'' now'\n");

// --- The commit ---
// Ground commits, not the agent. The branch history is the record of the
// walk, and a record the agent writes is a record the agent can skip.

import ritual : commitScript;

enum c = commitScript("/home/u/src/proj-p1", "tree", "APPLE");
static assert(c.text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\ncd '/home/u/src/proj-p1'\n"
    ~ "git add -A\n"
    ~ "git diff --cached --quiet && exit 0\n"
    ~ "git commit -q -m 'tree: APPLE'\n");

// A rite that changed nothing leaves no commit, so eight rites passing against
// an unchanged tree do not become eight empty ones. That is the --quiet line.
static assert(commitScript("/r", "t", "X").text() ==
    "#!/usr/bin/env bash\nset -euo pipefail\ncd '/r'\n"
    ~ "git add -A\n"
    ~ "git diff --cached --quiet && exit 0\n"
    ~ "git commit -q -m 't: X'\n");
