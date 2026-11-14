module lineage_test;

// "maybe i want that session to inherit the name and not you"
// A fork's transcript is the parent's messages copied, uuid for uuid. The one
// holding the parent's last message goes on as the parent; the one that stops
// before it branched.

version (Posix):

import lineage;

enum PARENT = `{"type":"user","uuid":"aaaaaaaa-0000-0000-0000-000000000001"}` ~ "\n"
    ~ `{"type":"assistant","uuid":"aaaaaaaa-0000-0000-0000-000000000002"}` ~ "\n"
    ~ `{"type":"user","uuid":"aaaaaaaa-0000-0000-0000-000000000003","message":"/fork"}` ~ "\n";
// Copied whole, the /fork row with it.
enum GOES_ON = PARENT;
// Copied before the /fork row.
enum BRANCH = `{"type":"user","uuid":"aaaaaaaa-0000-0000-0000-000000000001"}` ~ "\n"
    ~ `{"type":"assistant","uuid":"aaaaaaaa-0000-0000-0000-000000000002"}` ~ "\n";
enum STRANGER = `{"type":"user","uuid":"bbbbbbbb-0000-0000-0000-000000000001"}` ~ "\n";

unittest {
    assert(lastUuid(PARENT) == "aaaaaaaa-0000-0000-0000-000000000003");
    assert(lastUuid(`{"type":"mode"}`).length == 0, "no uuid is none");
}

unittest {
    assert(lineOf(GOES_ON, PARENT) == Line.continues);
    assert(lineOf(BRANCH, PARENT) == Line.branches);
    assert(lineOf(STRANGER, PARENT) == Line.none, "a transcript the parent never held came from elsewhere");
    assert(lineOf("", PARENT) == Line.none);
}
