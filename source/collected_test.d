module collected_test;

// "for knowing what is incoming"
// "and also what is outbound,"

version (Posix):

import collected;
import zbuf : ZBuf;

enum ME = "did:key:z6MkMe";
enum OTHER = "did:key:z6MkOther";

// What mycelia kept: the moment it asked, then the node's answer.
enum KEPT = "1000\n" ~ `{"collected":[`
    ~ `{"to":"Mycelia","did":"` ~ ME ~ `","due":"2026-11-14T04:00:00Z","waiting":[`
    ~ `{"from":"Shiitake","says":"the build on k is red","at":"2026-11-13T22:00:00Z","from_did":"` ~ OTHER ~ `"}]},`
    ~ `{"to":"Shiitake","did":"` ~ OTHER ~ `","due":"2026-11-14T04:01:37Z","waiting":[`
    ~ `{"from":"Mycelia","says":"Mycelia here","at":"2026-11-13T22:01:37Z","from_did":"` ~ ME ~ `"}]}]}`;

// "18:37 <-- Shiitake: \"the things Shiitake said to us\""
// "we dont need three lines for 1 message"
// One line a message: when it is due on this clock, which way it goes, who
// said it or is to hear it, and what it says.
unittest {
    ZBuf said;
    assert(collectedFor(KEPT, ME, 1010, 3600, said) == 0, said.slice());
    assert(said.slice() ==
        "05:00 <-- Shiitake: \"the build on k is red\"\n"
        ~ "05:01 --> Shiitake: \"Mycelia here\"\n", said.slice());
}

// The other side of the same list.
unittest {
    ZBuf said;
    assert(collectedFor(KEPT, OTHER, 1010, 3600, said) == 0, said.slice());
    assert(said.slice() ==
        "05:01 <-- Mycelia: \"Mycelia here\"\n"
        ~ "05:00 --> Mycelia: \"the build on k is red\"\n", said.slice());
}

// "why is absence made into presence of nothing ?"
// A side with nothing waiting is not said; with neither, nothing is.
unittest {
    ZBuf said;
    assert(collectedFor("1000\n{\"collected\":[]}", ME, 1010, 3600, said) == 0);
    assert(said.slice().length == 0, said.slice());
}

// What mycelia could not ask is kept in the answer's place, and said as that.
unittest {
    ZBuf said;
    assert(collectedFor("1000\nQNTX 502", ME, 1010, 3600, said) == 1);
    assert(said.slice() == "mycelia could not ask the node: QNTX 502\n", said.slice());
}

// An answer older than mycelia's passes is not drawn as current.
unittest {
    ZBuf said;
    assert(collectedFor(KEPT, ME, 1000 + 61, 3600, said) == 1);
    assert(said.slice() == "mycelia last asked the node 61s ago: what it kept is not current\n", said.slice());
}

// Nothing kept is a mycelia that never asked.
unittest {
    ZBuf said;
    assert(collectedFor("", ME, 1010, 3600, said) == 1);
    assert(said.slice() == "mycelia has kept nothing: it has not asked the node\n", said.slice());
}

// Times are drawn on the clock of the machine: an RFC3339 instant, as the
// node writes it, at an offset from UTC, as hours and minutes.
unittest {
    assert(clockOf("2026-11-14T04:01:37Z", 3600) == "05:01");
    assert(clockOf("2026-11-13T23:30:00Z", 3600) == "00:30", "past midnight on the clock");
    assert(clockOf("2026-11-14T00:10:00Z", -3600) == "23:10", "before midnight on the clock");
    assert(clockOf("not a time", 3600) == "");
}

// What ag draws, as data: what comes in and what goes out, each item with
// what the node names it by.
unittest {
    ZBuf said;
    assert(collectedJson(KEPT, ME, 1010, 3600, said) == 0, said.slice());
    assert(said.slice() ==
        `{"incoming":[{"to":"Mycelia","did":"` ~ ME ~ `","due":"05:00","items":[`
        ~ `{"id":"","from":"Shiitake","says":"the build on k is red","at":"23:00"}]}],`
        ~ `"outbound":[{"to":"Shiitake","did":"` ~ OTHER ~ `","due":"05:01","id":"","says":"Mycelia here","at":"23:01"}]}`,
        said.slice());
}

// What kept mycelia from an answer is the error ag draws.
unittest {
    ZBuf said;
    assert(collectedJson("1000\nQNTX 502", ME, 1010, 3600, said) == 1);
    assert(said.slice() == `{"error":"mycelia could not ask the node: QNTX 502"}`, said.slice());
}

// Nothing waiting either way is two empty lists, which ag draws as nothing.
unittest {
    ZBuf said;
    assert(collectedJson("1000\n{\"collected\":[]}", ME, 1010, 3600, said) == 0);
    assert(said.slice() == `{"incoming":[],"outbound":[]}`, said.slice());
}

// A time on the clock to hold until is the next such moment, as the node
// takes it: RFC3339, in UTC.
unittest {
    // 2026-11-14T08:23:00Z is 09:23 on a clock an hour ahead.
    enum now = 1794644580;
    ZBuf until;
    assert(untilOf("10:00", now, 3600, until));
    assert(until.slice() == "2026-11-14T09:00:00Z", until.slice());
    assert(untilOf("09:00", now, 3600, until), "a time already past today is tomorrow's");
    assert(until.slice() == "2026-11-15T08:00:00Z", until.slice());
    assert(!untilOf("25:00", now, 3600, until));
    assert(!untilOf("9", now, 3600, until));
}

// What a button asks the node: the sigil's parameters as a JSON object.
unittest {
    ZBuf body;
    // A static array: -betterC has no GC to build a literal on.
    const(char)[][4] pairs = ["to", "did:key:z6MkMe", "says", "a \"quoted\" line\nand another"];
    bodyOf(pairs[], body);
    assert(body.slice() == `{"to":"did:key:z6MkMe","says":"a \"quoted\" line\nand another"}`, body.slice());
}

// "kept. kept bro, i want to put my finger on, and then not have to thing about it anymore"
// A press is mycelia's to make in the person's session: asked of it as the path on one
// line and the body after, and answered as the node's status on one line and
// its body after.
unittest {
    ZBuf asked;
    pressFor("/api/collected/cancel", `{"to":"a","id":"b"}`, asked);
    assert(asked.slice() == "/api/collected/cancel\n{\"to\":\"a\",\"id\":\"b\"}", asked.slice());

    auto ok = answerOf("200\n{\"collected\":[]}");
    assert(ok.status == 200 && ok.body_ == `{"collected":[]}`);
    auto refused = answerOf("403\n{\"error\":\"no\"}");
    assert(refused.status == 403 && refused.body_ == `{"error":"no"}`);
    auto unasked = answerOf("0\nthe person's session was not taken out of the Keychain: OSStatus -128 User canceled");
    assert(unasked.status == 0 && unasked.body_ == "the person's session was not taken out of the Keychain: OSStatus -128 User canceled");
    assert(answerOf("").status == 0 && answerOf("").body_.length == 0, "no answer is no status");
}
