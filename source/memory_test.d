module memory_test;

// "I OPEN MY OBSIDIAN, I SEE LIVE STATE OF AGENT MEMORY"
// "I CAN EDIT IT, IT GOES TO QNTX, IT GOES TO AGENT MEMORY"
// "AND AGENT MEMORIES COME BACK VIA QNTX TO THE VAULT AS WELL"

version (Posix):

import memory;
import zbuf : ZBuf;

// Where one memory goes, by how it stands on each side and how ground kept it.
unittest {
    // Nothing changed on either side.
    assert(carried(true, "a", true, "a", true, "a", true, "a") == Carry.none);
    // The session wrote one the node has not seen.
    assert(carried(true, "a", false, null, false, null, false, null) == Carry.toNode);
    // The session wrote on.
    assert(carried(true, "b", true, "a", true, "a", true, "a") == Carry.toNode);
    // The session let one go.
    assert(carried(false, null, true, "a", true, "a", true, "a") == Carry.toNode);
    // The person edited it in the vault.
    assert(carried(true, "a", true, "a", true, "b", true, "a") == Carry.toHarness);
    // The person wrote one the session never had.
    assert(carried(false, null, false, null, true, "a", false, null) == Carry.toHarness);
    // The person deleted it.
    assert(carried(true, "a", true, "a", false, null, true, "a") == Carry.toHarness);
    // Written on both since ground kept it: the person's stands.
    assert(carried(true, "the session's", true, "a", true, "the person's", true, "a") == Carry.toHarness);
    // The node keeps an agent's words in the agent's quotation: what the
    // session wrote and what the node keeps of it differ, and nothing moves.
    assert(carried(true, "a", true, "a", true, "「[Alder] a」", true, "「[Alder] a」") == Carry.none);
}

// A name with a space or a slash in it is one segment of an address.
unittest {
    ZBuf url;
    putSegment(url, "Ada Lovelace");
    assert(url.slice() == "Ada%20Lovelace", url.slice());
    url.reset();
    putSegment(url, "feedback_a-b.c");
    assert(url.slice() == "feedback_a-b.c", url.slice());
    assert(!aMemoryName("../key") && !aMemoryName(".obsidian") && !aMemoryName("") && !aMemoryName("a/b"));
    assert(aMemoryName("the pond"));
}

// What a node's list answers with: each memory's name, and when it was written.
unittest {
    enum answer = `{"store":"Alder","memories":[{"store":"Alder","name":"MEMORY","text":"","modified":"2026-11-13T06:00:00Z"},{"store":"Alder","name":"the pond","text":"","modified":"2026-11-13T06:00:05Z"}]}`;
    __gshared Names names, written;
    names = Names.init;
    written = Names.init;
    assert(listed(answer, names, written) == 2);
    size_t n = 0, w = 0;
    assert(names.next(n) == "MEMORY");
    assert(written.next(w) == "2026-11-13T06:00:00Z");
    assert(names.next(n) == "the pond");
    assert(written.next(w) == "2026-11-13T06:00:05Z");
    assert(names.next(n) is null);

    // A store with no memory answers none.
    names = Names.init;
    written = Names.init;
    assert(listed(`{"store":"Alder","memories":[]}`, names, written) == 0);
}

// One memory through its whole life, with a stand-in for the node: the session
// writes it, the person edits it at the node, the person deletes it.
unittest {
    import core.stdc.stdio : snprintf, fopen, fputs, fclose;
    import core.sys.posix.unistd : getpid;

    char[256] top = 0;
    auto tn = snprintf(top.ptr, top.length, "/tmp/ground-memory-%d", getpid());
    ZBuf harness, heldHarness, heldNode, path;
    harness.put(top[0 .. tn]); harness.put("/harness");
    heldHarness.put(top[0 .. tn]); heldHarness.put("/held/harness");
    heldNode.put(top[0 .. tn]); heldNode.put("/held/node");

    __gshared char[4096] said;
    const(char)[] onDisk(const(char)[] folder) {
        path.reset();
        path.put(folder);
        path.put("/frost.md");
        auto len = fileSays(path.ptr(), said[]);
        return len < 0 ? null : said[0 .. cast(size_t) len];
    }

    // The node, standing in: what it holds of the memory, and what it was sent.
    __gshared bool nodeHolds;
    __gshared char[256] nodeSays;
    __gshared size_t nodeLen;
    nodeHolds = false;
    nodeLen = 0;
    bool toNode(bool says, const(char)[] text, ref const(char)[] kept, ref const(char)[] at) {
        nodeHolds = says;
        nodeLen = 0;
        if (says) {
            // It stands what an agent wrote in the agent's own quotation.
            enum opens = "「[Alder] ", closes = "」";
            foreach (c; opens) nodeSays[nodeLen++] = c;
            foreach (c; text) nodeSays[nodeLen++] = c;
            foreach (c; closes) nodeSays[nodeLen++] = c;
            kept = nodeSays[0 .. nodeLen];
            at = "2026-11-13T06:00:00Z";
        }
        return true;
    }

    // The session writes a memory: it goes to the node.
    path.put(harness.slice()); path.put("/frost.md");
    assert(fileIs(path, true, "Cover the beds."));
    auto did = inStep(harness.slice(), heldHarness.slice(), heldNode.slice(), "frost", false, null, null, &toNode);
    assert(did == Carry.toNode);
    assert(nodeHolds && nodeSays[0 .. nodeLen] == "「[Alder] Cover the beds.」", nodeSays[0 .. nodeLen]);
    assert(onDisk(harness.slice()) == "Cover the beds.", "what the session wrote was changed under it");

    // In step: a second pass moves nothing.
    did = inStep(harness.slice(), heldHarness.slice(), heldNode.slice(), "frost", true, nodeSays[0 .. nodeLen], "2026-11-13T06:00:00Z", &toNode);
    assert(did == Carry.none);

    // The person edits it in the vault: it is the session's memory.
    did = inStep(harness.slice(), heldHarness.slice(), heldNode.slice(), "frost", true, "Never cover the beds.", "2026-11-13T06:10:00Z", &toNode);
    assert(did == Carry.toHarness);
    assert(onDisk(harness.slice()) == "Never cover the beds.", onDisk(harness.slice()));

    // The person deletes it: the session holds it no more.
    did = inStep(harness.slice(), heldHarness.slice(), heldNode.slice(), "frost", false, null, null, &toNode);
    assert(did == Carry.toHarness);
    assert(onDisk(harness.slice()) is null, "a memory the person deleted is still the session's");
    assert(onDisk(heldHarness.slice()) is null && onDisk(heldNode.slice()) is null);

    // A node that did not take what the session wrote: nothing is kept as
    // carried, so it is carried again.
    path.reset();
    path.put(harness.slice()); path.put("/frost.md");
    assert(fileIs(path, true, "Again."));
    bool refuses(bool says, const(char)[] text, ref const(char)[] kept, ref const(char)[] at) { return false; }
    did = inStep(harness.slice(), heldHarness.slice(), heldNode.slice(), "frost", false, null, null, &refuses);
    assert(did == Carry.none);
    assert(onDisk(heldHarness.slice()) is null, "what the node refused was kept as carried");
    did = inStep(harness.slice(), heldHarness.slice(), heldNode.slice(), "frost", false, null, null, &toNode);
    assert(did == Carry.toNode);
}

// The folder a session's memory is in: the project that holds its transcript.
unittest {
    import core.stdc.stdio : snprintf;
    import core.sys.posix.unistd : getpid;
    char[256] top = 0;
    auto tn = snprintf(top.ptr, top.length, "/tmp/ground-memory-config-%d", getpid());
    ZBuf transcript, folder;
    transcript.put(top[0 .. tn]);
    transcript.put("/projects/-home-ada-garden/s-1.jsonl");
    assert(fileIs(transcript, true, "{}"));
    assert(memoryFolderOf(top[0 .. tn], "s-1", folder));
    ZBuf expected;
    expected.put(top[0 .. tn]);
    expected.put("/projects/-home-ada-garden/memory");
    assert(folder.slice() == expected.slice(), folder.slice());
    assert(!memoryFolderOf(top[0 .. tn], "s-2", folder), "a session with no transcript was given a project's memory");
}
