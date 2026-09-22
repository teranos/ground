module hook_socket_test;

// "A hook opens no socket; this is the one process of a session that does."
//   — sky.d, of itself
//
// A hook runs inside a tool call and every millisecond it spends is the
// session's. A socket it opens is a socket that stalls a turn on the network.
// The percentiles of a branch's CI runs were once asked for from inside
// PostToolUse; the node that waits on the run asks for them now, and nothing
// in either hook names a way to reach out.

enum pre  = import("source/pretooluse.d");
enum post = import("source/posttooluse.d");

static assert(!contains(post, "getCIPercentiles"), "PostToolUse asks github for nothing");
static assert(!contains(post, "popen("), "PostToolUse opens no pipe to a network command");
static assert(!contains(post, "httpPost"), "PostToolUse posts nothing");
static assert(!contains(pre, "popen("), "PreToolUse opens no pipe to a network command");
static assert(!contains(pre, "httpPost"), "PreToolUse posts nothing");

// Sky carries what it is handed and forms no view about any of it. The wait
// on a CI run — and the asking after it — is the node's, on arrival.
enum sky = import("source/sky.d");
static assert(!contains(sky, "adaptive"), "sky picks no interval from a run's history");
static assert(!contains(sky, "checkCIStatus"), "sky asks github nothing about a push");
static assert(!contains(sky, "p50") && !contains(sky, "p90"), "sky knows no percentiles");

private bool contains(const(char)[] hay, const(char)[] needle) {
    if (needle.length > hay.length) return false;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle) return true;
    return false;
}
