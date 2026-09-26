module queue_test;

// One queue. A deferred control once wrote a `deferred:` row that the Stop
// hook read back through a second reader, beside the `immediate:` rows sky
// carries. Two readers, two receipts, and a project-scoped path nothing has
// written to since QNTX stopped. A deferred message is an immediate row with
// an `after` gate, and sky hands it in when the gate opens.

enum stop = import("source/stop.d");
enum start = import("source/sessionstart.d");
enum post = import("source/posttooluse.d");
enum display = import("source/messagedisplay.d");

static assert(!contains(stop, "readDeferredMessage"), "Stop reads one queue, and sky carries it");
static assert(!contains(stop, "readProjectDeferredMessage"), "no project-scoped deferred read at Stop");
static assert(!contains(start, "readProjectDeferredMessage"), "no project-scoped deferred read at SessionStart");
static assert(!contains(post, "writeDeferredMessage"), "a deferred control writes an immediate row with a gate");
static assert(!contains(display, "writeDeferredMessage"), "the rewrite notice is an immediate row");

private bool contains(const(char)[] hay, const(char)[] needle) {
    if (needle.length > hay.length) return false;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle) return true;
    return false;
}
