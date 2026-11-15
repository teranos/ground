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

// "yes,"
// A branch is shown by the title Claude Code gives it, past its ⑂: what the
// 「[Opus 5.5] person asked the fork to do. Claude Code's own title, not the session's name:」
// 「[Opus 5.5] ground titles a session by its name, and that is written as agentName.」
unittest {
    enum T = `{"type":"ai-title","aiTitle":"Granite name setup ⑂ mycelia on k","sessionId":"x"}` ~ "\n"
        ~ `{"type":"agent-name","agentName":"Mycelia","sessionId":"x"}` ~ "\n"
        ~ `{"type":"user","uuid":"aaaaaaaa-0000-0000-0000-000000000001"}` ~ "\n";
    assert(titleOf(T) == "mycelia on k");
    assert(aiTitleOf(T) == "Granite name setup ⑂ mycelia on k");
    assert(titleOf(`{"type":"ai-title","aiTitle":"Slate","sessionId":"x"}`) == "Slate", "a title with no ⑂ is all of it");
    assert(titleOf(`{"type":"user"}`).length == 0);
}

// "ok, so say i want it, to cohere, using their exposed api"
// 「[Opus 5.5] What Claude Code titles a session is the name it holds. One that gave its」
// 「[Opus 5.5] name away is titled by what Claude Code called it, so two sessions are」
// 「[Opus 5.5] never shown by one name. Nothing is said when the title already is that,」
// 「[Opus 5.5] and a title the person gave a session holding no name stays.」
unittest {
    assert(retitle("Mycelia", "Granite name setup", false, "") == "Mycelia");
    assert(retitle("Mycelia", "", false, "") == "Mycelia", "a session with no title yet takes its name");
    assert(retitle("Mycelia", "Mycelia", false, "").length == 0, "already its name");
    assert(retitle("", "Mycelia", true, "Granite name setup") == "Granite name setup", "a name given away is no title here");
    assert(retitle("", "Granite name setup", false, "Granite name setup").length == 0);
    assert(retitle("", "Rename by hand", false, "Granite name setup").length == 0, "the person's title stays");
    assert(retitle("", "Mycelia", true, "").length == 0, "with no title of Claude Code's, nothing is set");
}

// "i dont thin that ux is good"
// A branch alive in another window cannot be switched to here: Claude Code
// keeps a file for each live session, its pid and its session id.
unittest {
    enum FILE = `{"pid":62251,"sessionId":"fa8a1589-576c-4ecb-84c8-f7d0f357b448","cwd":"/x","kind":"bg"}`;
    assert(pidFor(FILE, "fa8a1589-576c-4ecb-84c8-f7d0f357b448") == 62251);
    assert(pidFor(FILE, "573b42a2-ba1d-41b1-9bf8-52750e6e8cfc") == 0, "another session's file says nothing of this one");
    assert(pidFor(`{"sessionId":"fa8a1589-576c-4ecb-84c8-f7d0f357b448"}`, "fa8a1589-576c-4ecb-84c8-f7d0f357b448") == 0, "no pid is no process");
}
