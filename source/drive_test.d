module drive_test;

// What the driver does about a tree that is not there.
// A rite run before the tree exists records "hold, code 1" with the output
// "cd: …: No such file or directory" — a verdict about a question never asked.

import ritual.drive : TreeVerdict, treeVerdict;

// The tree is there. Nothing to decide.
static assert(treeVerdict(true, false) == TreeVerdict.Run);
static assert(treeVerdict(true, true) == TreeVerdict.Run);

// Not there and never seen: the agent has not made it yet. `ground ritual`
// dispatches the driver and the agent together, and the tree only exists once
// `claude -w` fires WorktreeCreate — so the driver always starts ahead of it.
static assert(treeVerdict(false, false) == TreeVerdict.Wait);

// Not there and seen before: it was removed, and the performance is over.
static assert(treeVerdict(false, true) == TreeVerdict.Gone);
