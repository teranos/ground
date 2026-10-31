module handler_names;

// The handlers a control may name, by kind. The engine holds their code
// (handlers.d); the sand needs only to know a name is one of them.

static immutable string[] checkNames = [
    "binaryShadowed", "commitNotRequested", "mergeNotRequested", "killNotRequested",
    "branchNotRequested", "prNotRequested", "quoteProvenance", "quoteStandsAlone",
    "quoteChronology", "strikethrough", "unanalyzableBash", "deepAndChain",
    "stagedNamesPerson", "pushNamesPerson",
];

// No delay handler is named by any control today.
static immutable string[] delayNames = [];

static immutable string[] deliverNames = ["upstreamBriefingDeliver"];

bool named(const string[] names, const(char)[] name) {
    foreach (n; names) if (n == name) return true;
    return false;
}
