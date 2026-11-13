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

// What waits for this session's DID, and what it said that waits for another.
unittest {
    ZBuf said;
    assert(collectedFor(KEPT, ME, 1010, said) == 0, said.slice());
    assert(said.slice() ==
        "Waiting for you, due 2026-11-14T04:00:00Z:\n"
        ~ "  Shiitake, 2026-11-13T22:00:00Z: the build on k is red\n"
        ~ "You said, waiting:\n"
        ~ "  to Shiitake, due 2026-11-14T04:01:37Z: Mycelia here\n", said.slice());
}

// The other side of the same list.
unittest {
    ZBuf said;
    assert(collectedFor(KEPT, OTHER, 1010, said) == 0, said.slice());
    assert(said.slice() ==
        "Waiting for you, due 2026-11-14T04:01:37Z:\n"
        ~ "  Mycelia, 2026-11-13T22:01:37Z: Mycelia here\n"
        ~ "You said, waiting:\n"
        ~ "  to Mycelia, due 2026-11-14T04:00:00Z: the build on k is red\n", said.slice());
}

// Nothing either way is said, not left blank.
unittest {
    ZBuf said;
    assert(collectedFor("1000\n{\"collected\":[]}", ME, 1010, said) == 0);
    assert(said.slice() == "Nothing waits for you, and nothing you said waits.\n", said.slice());
}

// What mycelia could not ask is kept in the answer's place, and said as that.
unittest {
    ZBuf said;
    assert(collectedFor("1000\nQNTX 502", ME, 1010, said) == 1);
    assert(said.slice() == "mycelia could not ask the node: QNTX 502\n", said.slice());
}

// An answer older than mycelia's passes is not drawn as current.
unittest {
    ZBuf said;
    assert(collectedFor(KEPT, ME, 1000 + 61, said) == 1);
    assert(said.slice() == "mycelia last asked the node 61s ago: what it kept is not current\n", said.slice());
}

// Nothing kept is a mycelia that never asked.
unittest {
    ZBuf said;
    assert(collectedFor("", ME, 1010, said) == 1);
    assert(said.slice() == "mycelia has kept nothing: it has not asked the node\n", said.slice());
}
