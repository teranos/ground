module skylife;

// What a sky says about itself to Sentry, as one attestation as well, so the
// node can count the skies and see what each left pending and refused. QNTX
// #1068, Phase 3, asks for it, and for one more when a sky starts.

import db : ZBuf;

enum PREDICATE = "sky:lifecycle";

struct Life {
    const(char)[] how;
    const(char)[] level;
    const(char)[] tree;
    long pid, delivered, polls, seconds, streamed, pending, refused;
}

void lifeInto(ref ZBuf o, const ref Life l) {
    import immediate : putJsonString;
    void str(const(char)[] key, const(char)[] v, bool first = false) {
        o.put(first ? `{"` : `,"`);
        o.put(key);
        o.put(`":"`);
        putJsonString(o, v);
        o.put(`"`);
    }
    void num(const(char)[] key, long v) {
        o.put(`,"`);
        o.put(key);
        o.put(`":`);
        if (v < 0) { o.put("-"); v = -v; }
        o.putUint(cast(ulong) v);
    }
    str("how", l.how, true);
    str("level", l.level);
    str("tree", l.tree);
    num("pid", l.pid);
    num("delivered", l.delivered);
    num("polls", l.polls);
    num("seconds", l.seconds);
    num("streamed", l.streamed);
    num("stream_pending", l.pending);
    num("stream_refused", l.refused);
    o.put("}");
}

// The attestation itself, in the session's context, with the cwd its branch
// and subject are read from.
void attestLife(DB)(DB db, const(char)[] cwd, const(char)[] sessionId, const ref Life l) {
    import db : attestEvent;
    __gshared ZBuf body_;
    __gshared ZBuf tag;
    body_.reset();
    lifeInto(body_, l);
    tag.reset();
    tag.putUint(cast(ulong) l.pid);
    tag.put(":");
    tag.put(l.how.length > 24 ? l.how[0 .. 24] : l.how);
    attestEvent(db, PREDICATE, cwd, sessionId, body_.slice(), tag.slice());
}

unittest {
    __gshared ZBuf o;
    Life l;
    l.how = `delivered and exited 2`;
    l.level = "info";
    l.tree = "ground";
    l.pid = 4242; l.delivered = 3; l.polls = 12; l.seconds = 60;
    l.streamed = 40; l.pending = 5; l.refused = 20;
    o.reset();
    lifeInto(o, l);
    assert(o.slice() == `{"how":"delivered and exited 2","level":"info","tree":"ground","pid":4242,`
        ~ `"delivered":3,"polls":12,"seconds":60,"streamed":40,"stream_pending":5,"stream_refused":20}`, o.slice());

    // What a sky says about itself can carry a quote, and stays one JSON string.
    l.how = `refused: "x"`;
    o.reset();
    lifeInto(o, l);
    enum quoted = `{"how":"refused: \"x\"",`;
    assert(o.slice()[0 .. quoted.length] == quoted, o.slice());
}
