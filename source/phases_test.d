module phases_test;

// "perhaps its better to focus on improving the instrument?"

import phases : outerPhases, phaseChain, parsePhases, PhaseEntry, PhaseMeans, regressionLine;

struct Sink {
    char[1024] data = 0;
    size_t len;
    void put(const(char)[] s) { foreach (c; s) if (len < data.length) data[len++] = c; }
    void putChar(char c) { put((&c)[0 .. 1]); }
    const(char)[] slice() const return { return data[0 .. len]; }
}

// The row says where the whole process went, not only the handler: stdin,
// the event attestation, and the handler, then whatever the handler measured.
static assert(() {
    Sink s;
    outerPhases(s, 1200, 30000, 4000, "parse=10us total=12us exit=none");
    return s.slice() == "stdin=1200us attest=30000us handler=4000us parse=10us total=12us exit=none";
}());

// A handler that measured nothing still leaves the outer three.
static assert(() {
    Sink s;
    outerPhases(s, 1200, 30000, 4000, "");
    return s.slice() == "stdin=1200us attest=30000us handler=4000us";
}());

// The whole row parses back, total and exit set aside as before.
static assert(() {
    Sink s;
    outerPhases(s, 1200, 30000, 4000, "parse=10us total=12us exit=none");
    PhaseEntry[32] e;
    auto n = parsePhases(s.slice(), e);
    return n == 4 && e[0].key == "stdin" && e[0].val == 1200
        && e[2].key == "handler" && e[2].val == 4000 && e[3].key == "parse";
}());

// One emit for every exit. A stamp never taken is a phase never entered, and
// the chain skips it rather than printing a delta from zero.
static assert(() {
    Sink s;
    static immutable string[5] keys = ["parse", "binary", "match", "db", "perm"];
    long[5] stamps = [10, 0, 0, 0, 0];
    phaseChain(s, 0, keys[], stamps[], 15, "none");
    return s.slice() == "parse=10us total=15us exit=none";
}());

static assert(() {
    Sink s;
    static immutable string[5] keys = ["parse", "binary", "match", "db", "perm"];
    long[5] stamps = [10, 20, 25, 0, 30];
    phaseChain(s, 0, keys[], stamps[], 32, "perm-allow");
    return s.slice() == "parse=10us binary=10us match=5us perm=5us total=32us exit=perm-allow";
}());

// The regression message averages the rows it averaged, key by key. A key
// missing from a row is not a zero in that row.
static assert(() {
    PhaseMeans m;
    m.add("stdin=100us attest=300us total=400us exit=none");
    m.add("stdin=300us attest=500us handler=10us");
    Sink s;
    m.render(s);
    return m.rows == 2 && s.slice() == "stdin=0.2ms attest=0.4ms handler=0.0ms";
}());

// The line names the event's own phases and none of Stop's.
static assert(() {
    PhaseMeans m;
    m.add("stdin=1000us attest=30000us handler=4000us parse=2000us total=6000us exit=none");
    Sink s;
    regressionLine(s, "PreToolUse", 158, 50, "v0.19.1-277\n", m);
    import matcher : contains;
    return contains(s.slice(), "PreToolUse averages 158ms (budget 50ms, ground v0.19.1-277)")
        && contains(s.slice(), "over 1 runs: stdin=1.0ms attest=30.0ms handler=4.0ms parse=2.0ms")
        && !contains(s.slice(), "sessQ") && !contains(s.slice(), "\n");
}());
