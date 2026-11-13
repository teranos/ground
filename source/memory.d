module memory;

// "I OPEN MY OBSIDIAN, I SEE LIVE STATE OF AGENT MEMORY"
// "I CAN EDIT IT, IT GOES TO QNTX, IT GOES TO AGENT MEMORY"
// "AND AGENT MEMORIES COME BACK VIA QNTX TO THE VAULT AS WELL"
// "Sessions on l and k,"
// "i care about these"
//
// A session's memory is its harness's own store, on the machine the session
// runs on. Its node holds a Memory Store by the session's name (QNTX #1704,
// ADR-055), a folder of the person's vault. Ground carries between the two,
// and keeps each memory as it last stood on either side: what changed at the
// node goes into the harness's store, what changed in the harness goes to the
// node. Changed on both, the node's stands: it is where the person writes.

import zbuf : ZBuf;
import code.reply : Reply, putEscaped;

enum BOOK_COMMAND = q"EOS
# bring this session's memory in step with its Memory Store at its node, both ways:
ground memory
EOS";

// The most one memory says, and the most a node's answer about one is.
enum MEMORY_MOST = 262_144;
enum ANSWER_MOST = 2 * MEMORY_MOST + 4096;

// What is done with one memory.
enum Carry { none, toHarness, toNode }

// Where one memory goes: by how it stands in the harness and at the node now,
// and how ground last kept it of each.
Carry carried(bool inHarness, const(char)[] harness, bool wasInHarness, const(char)[] harnessWas,
              bool atNode, const(char)[] node, bool wasAtNode, const(char)[] nodeWas) {
    if (atNode != wasAtNode || (atNode && node != nodeWas)) return Carry.toHarness;
    if (inHarness != wasInHarness || (inHarness && harness != harnessWas)) return Carry.toNode;
    return Carry.none;
}

// A name as one segment of a path in an address.
void putSegment(ref ZBuf url, const(char)[] name) {
    enum hex = "0123456789ABCDEF";
    foreach (c; name) {
        bool plain = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
            || c == '-' || c == '_' || c == '.' || c == '~';
        if (plain) { url.putChar(c); continue; }
        url.putChar('%');
        url.putChar(hex[(cast(ubyte) c) >> 4]);
        url.putChar(hex[(cast(ubyte) c) & 15]);
    }
}

// Whether name is one memory's own: a note's name, with no path in it and
// nothing that starts with a dot.
bool aMemoryName(const(char)[] name) {
    if (name.length == 0 || name.length > 200 || name[0] == '.') return false;
    foreach (c; name) if (c == '/' || c == '\\' || c == 0) return false;
    return true;
}

// The names kept so far, one after another with a 0 between.
struct Names {
    char[32_768] data = 0;
    size_t len;
    size_t count;

    bool has(const(char)[] name) {
        size_t at = 0;
        while (at < len) {
            size_t end = at;
            while (end < len && data[end] != 0) end++;
            if (data[at .. end] == name) return true;
            at = end + 1;
        }
        return false;
    }

    // Kept whether or not it is there already. False when no room is left.
    bool append(const(char)[] name) {
        if (len + name.length + 1 > data.length) return false;
        foreach (c; name) data[len++] = c;
        data[len++] = 0;
        count++;
        return true;
    }

    // Kept once. False when no room is left.
    bool add(const(char)[] name) {
        return has(name) || append(name);
    }

    // The name that starts at `at`, which is moved past it; null at the end.
    const(char)[] next(ref size_t at) {
        if (at >= len) return null;
        size_t end = at;
        while (end < len && data[end] != 0) end++;
        auto name = data[at .. end];
        at = end + 1;
        return name;
    }
}

// The names of the memories a node's list answers with, and for each when it
// was last written there, in the same order.
size_t listed(const(char)[] answer, ref Names names, ref Names written) {
    import matcher : indexOf;
    import parse : extractJsonString, extractJsonStringAt;
    enum memories = `"memories"`;
    auto from = indexOf(answer, memories);
    if (from < 0) return 0;
    size_t pos = cast(size_t) from + memories.length;
    size_t found = 0;
    enum key = `"name"`;
    while (pos < answer.length) {
        auto at = indexOf(answer[pos .. $], key);
        if (at < 0) break;
        char[256] nameBuf = 0;
        auto name = extractJsonStringAt(answer, cast(ptrdiff_t)(pos + cast(size_t) at), key, nameBuf.ptr, nameBuf.length);
        pos += cast(size_t) at + key.length;
        if (name is null || !aMemoryName(name) || names.has(name)) continue;
        // Its stamp is in the same object: before the next name.
        auto rest = answer[pos .. $];
        auto nextName = indexOf(rest, key);
        auto own = nextName < 0 ? rest : rest[0 .. cast(size_t) nextName];
        char[64] atBuf = 0;
        auto stamp = extractJsonString(own, `"modified"`, atBuf.ptr, atBuf.length);
        // A stamp is found by its place, so a missing one is kept as none.
        if (stamp is null || stamp.length == 0) stamp = "-";
        if (!names.append(name) || !written.append(stamp)) break;
        found++;
    }
    return found;
}

private extern(C) nothrow @nogc {
    int access(const(char)* path, int mode);
    int unlink(const(char)* path);
}

// What the file at path says, into buf: its length, or -1 when it is not there
// or is more than buf holds.
ptrdiff_t fileSays(const(char)* path, char[] buf) {
    import core.stdc.stdio : fopen, fread, fclose, fgetc, EOF;
    auto f = fopen(path, "rb");
    if (f is null) return -1;
    auto got = fread(buf.ptr, 1, buf.length, f);
    bool more = got == buf.length && fgetc(f) != EOF;
    fclose(f);
    return more ? -1 : cast(ptrdiff_t) got;
}

// Every folder on the way to path is made.
void makeFoldersTo(const(char)[] path) {
    import db : mkdir;
    char[4096] at = 0;
    if (path.length >= at.length) return;
    foreach (i, c; path) {
        if (c == '/' && i > 0) {
            at[i] = 0;
            mkdir(at.ptr, 448);
        }
        at[i] = c;
    }
}

// The file at path says said, or is gone when it is to say nothing. False when
// it could not be written.
bool fileIs(ref ZBuf path, bool says, const(char)[] said) {
    import core.stdc.stdio : fopen, fwrite, fclose;
    if (!says) {
        unlink(path.ptr());
        return true;
    }
    makeFoldersTo(path.slice());
    auto f = fopen(path.ptr(), "wb");
    if (f is null) return false;
    auto wrote = said.length == 0 ? 0 : fwrite(said.ptr, 1, said.length, f);
    return fclose(f) == 0 && wrote == said.length;
}

// Where Claude Code keeps things: CLAUDE_CONFIG_DIR, or ~/.claude.
bool configDir(ref ZBuf dir) {
    import core.stdc.stdlib : getenv;
    dir.reset();
    auto set = getenv("CLAUDE_CONFIG_DIR\0".ptr);
    size_t n = 0;
    if (set !is null) {
        while (set[n] != 0) n++;
        if (n > 0) { dir.put(set[0 .. n]); return true; }
    }
    auto home = getenv("HOME\0".ptr);
    if (home is null) return false;
    n = 0;
    while (home[n] != 0) n++;
    dir.put(home[0 .. n]);
    dir.put("/.claude");
    return true;
}

// The folder Claude Code keeps the session's memory in: the memory folder of
// the project that holds the session's transcript. False when no project does.
bool memoryFolderOf(const(char)[] config, const(char)[] sessionId, ref ZBuf folder) {
    import core.sys.posix.dirent : opendir, readdir, closedir;
    ZBuf projects;
    projects.put(config);
    projects.put("/projects");
    auto dir = opendir(projects.ptr());
    if (dir is null) return false;
    scope (exit) closedir(dir);
    for (auto e = readdir(dir); e !is null; e = readdir(dir)) {
        size_t len;
        while (e.d_name[len] != 0) len++;
        auto name = e.d_name[0 .. len];
        if (len == 0 || name[0] == '.') continue;
        ZBuf transcript;
        transcript.put(projects.slice());
        transcript.put("/");
        transcript.put(name);
        transcript.put("/");
        transcript.put(sessionId);
        transcript.put(".jsonl");
        if (access(transcript.ptr(), 0) != 0) continue;
        folder.reset();
        folder.put(projects.slice());
        folder.put("/");
        folder.put(name);
        folder.put("/memory");
        return true;
    }
    return false;
}

// The memories in a folder, by name: each note directly in it.
void memoriesIn(const(char)* folder, ref Names names) {
    import core.sys.posix.dirent : opendir, readdir, closedir;
    auto dir = opendir(folder);
    if (dir is null) return;
    scope (exit) closedir(dir);
    for (auto e = readdir(dir); e !is null; e = readdir(dir)) {
        size_t len;
        while (e.d_name[len] != 0) len++;
        if (len < 4) continue;
        auto name = e.d_name[0 .. len];
        if (name[$ - 3 .. $] != ".md") continue;
        if (!aMemoryName(name[0 .. $ - 3])) continue;
        names.add(name[0 .. $ - 3]);
    }
}

// What a pass carried, and why it carried less than everything.
struct Carried {
    size_t toHarness;
    size_t toNode;
    ZBuf why;
    bool ok;
    // Nothing is this session's to carry: it holds no name, no project keeps
    // its memory, or its node keeps none. Said by `ground memory`, and no
    // failure of the carrying.
    bool nothingToCarry;
}

private void noteAt(ref ZBuf path, const(char)[] folder, const(char)[] name, const(char)[] ext = ".md") {
    path.reset();
    path.put(folder);
    path.put("/");
    path.put(name);
    path.put(ext);
}

// One memory, brought in step between a harness's folder and what a node says
// of it, through what ground kept of each. atNode is whether the node holds
// it, and nodeSays what it says there. toNode is called for what the harness
// changed, and answers what the node keeps of it and when it wrote it; null
// when the node did not take it.
Carry inStep(const(char)[] harness, const(char)[] heldHarness, const(char)[] heldNode, const(char)[] name,
             bool atNode, const(char)[] nodeSays, const(char)[] stamp,
             scope bool delegate(bool says, const(char)[] said, ref const(char)[] kept, ref const(char)[] at) toNode) {
    __gshared char[MEMORY_MOST] inHarnessBuf, harnessWasBuf, nodeWasBuf;
    ZBuf path, stampPath;
    noteAt(path, harness, name);
    auto hLen = fileSays(path.ptr(), inHarnessBuf[]);
    noteAt(path, heldHarness, name);
    auto hwLen = fileSays(path.ptr(), harnessWasBuf[]);
    noteAt(path, heldNode, name);
    auto nwLen = fileSays(path.ptr(), nodeWasBuf[]);
    noteAt(stampPath, heldNode, name, ".at");

    auto does = carried(hLen >= 0, hLen >= 0 ? inHarnessBuf[0 .. cast(size_t) hLen] : null,
                        hwLen >= 0, hwLen >= 0 ? harnessWasBuf[0 .. cast(size_t) hwLen] : null,
                        atNode, nodeSays,
                        nwLen >= 0, nwLen >= 0 ? nodeWasBuf[0 .. cast(size_t) nwLen] : null);
    if (does == Carry.toHarness) {
        noteAt(path, harness, name);
        bool wrote = fileIs(path, atNode, nodeSays);
        noteAt(path, heldHarness, name);
        wrote = fileIs(path, atNode, nodeSays) && wrote;
        noteAt(path, heldNode, name);
        wrote = fileIs(path, atNode, nodeSays) && wrote;
        wrote = fileIs(stampPath, atNode && stamp.length > 0, stamp) && wrote;
        return wrote ? Carry.toHarness : Carry.none;
    }
    if (does == Carry.toNode) {
        const(char)[] kept, at;
        auto said = hLen >= 0 ? inHarnessBuf[0 .. cast(size_t) hLen] : null;
        if (!toNode(hLen >= 0, said, kept, at)) return Carry.none;
        noteAt(path, heldHarness, name);
        fileIs(path, hLen >= 0, said);
        noteAt(path, heldNode, name);
        fileIs(path, hLen >= 0, kept);
        fileIs(stampPath, hLen >= 0 && at.length > 0, at);
        return Carry.toNode;
    }
    return Carry.none;
}

// One pass: every memory of the session, brought in step with its Memory Store
// at the node. A node that keeps no memory, or a session with no name there,
// carries nothing, and says so.
//
// A node that answered it keeps no memory is not asked again by sky for
// NONE_SEC; `ground memory`, which a person or the session runs, always asks.
enum NONE_SEC = 600;

Carried carry(const(char)[] sessionId, bool asksAnyway = false) {
    import http : httpGet, httpPostInto, ToNode;
    import nodeconfig : nodeHere;
    import naming : sessionKeyFile, keptName;
    import parse : extractJsonString;

    Carried done;
    void no(const(char)[] why) { done.why.reset(); done.why.put(why); done.nothingToCarry = true; }

    auto here = nodeHere();
    if (here.sandUrl.length == 0) { no("this ground is signed in to no node"); return done; }
    auto keyAt = sessionKeyFile(sessionId);
    if (keyAt is null) { no("this session has no key of its own"); return done; }
    char[256] nameBuf = 0;
    auto called = keptName(keyAt, here.sandUrl, nameBuf[]);
    if (called is null || called.length == 0) { no("this session holds no name at its node, so no Memory Store is its"); return done; }

    ZBuf config, harness;
    if (!configDir(config)) { no("no home to find Claude Code's memory under"); return done; }
    if (!memoryFolderOf(config.slice(), sessionId, harness)) { no("no project of Claude Code's holds this session's transcript"); return done; }

    // Beside the session's key: how each memory last stood in the harness, at
    // the node, and when the node said it was written.
    size_t keyLen = 0;
    while (keyAt[keyLen] != 0) keyLen++;
    if (keyLen < 4) { no("the session's key is kept nowhere"); return done; }
    ZBuf heldHarness, heldNode;
    heldHarness.put(keyAt[0 .. keyLen - 3]);
    heldHarness.put("memory-held/harness");
    heldNode.put(keyAt[0 .. keyLen - 3]);
    heldNode.put("memory-held/node");

    ZBuf store;
    store.put(here.sandUrl);
    store.put("/api/memory/");
    putSegment(store, called);

    // When the node last answered that it keeps no memory, kept beside the key.
    ZBuf noneAt;
    noneAt.put(keyAt[0 .. keyLen - 3]);
    noneAt.put("memory-none");
    {
        import core.stdc.time : time;
        char[24] whenBuf = 0;
        auto whenLen = fileSays(noneAt.ptr(), whenBuf[]);
        long when = 0;
        if (whenLen > 0) foreach (c; whenBuf[0 .. cast(size_t) whenLen]) if (c >= '0' && c <= '9') when = when * 10 + (c - '0');
        if (!asksAnyway && when > 0 && cast(long) time(null) - when < NONE_SEC) {
            no("its node answered that it keeps no memory, and is asked again later");
            return done;
        }
    }

    __gshared char[ANSWER_MOST] answer;
    void refused(const(char)[] url, int status, size_t len, const(char)[] why) {
        done.ok = false;
        done.why.reset();
        done.why.put(url);
        if (status > 0) {
            done.why.put(" answered ");
            done.why.putUint(status);
            done.why.put(": ");
            auto said = answer[0 .. len];
            done.why.put(said.length > 600 ? said[0 .. 600] : said);
        } else {
            done.why.put(" was not reached: ");
            done.why.put(why);
        }
    }

    auto asked = httpGet(store.slice(), ToNode(keyAt), answer[], 20);
    if (asked.status != 200) {
        refused(store.slice(), asked.status, asked.len, asked.why());
        // A node that keeps no memory answers that nothing is there.
        done.nothingToCarry = asked.status == 404;
        if (asked.status == 404) {
            import core.stdc.time : time;
            ZBuf now;
            now.putUint(cast(ulong) time(null));
            fileIs(noneAt, true, now.slice());
        }
        return done;
    }
    fileIs(noneAt, false, null);

    __gshared Names atNode, writtenAt, all;
    atNode = Names.init;
    writtenAt = Names.init;
    all = Names.init;
    listed(answer[0 .. asked.len], atNode, writtenAt);
    {
        size_t at = 0;
        for (auto name = atNode.next(at); name !is null; name = atNode.next(at)) all.add(name);
    }
    memoriesIn(harness.ptr(), all);
    memoriesIn(heldHarness.ptr(), all);
    memoriesIn(heldNode.ptr(), all);

    __gshared char[MEMORY_MOST] atNodeBuf, keptBuf;
    done.ok = true;
    size_t at = 0;
    for (auto name = all.next(at); name !is null; name = all.next(at)) {
        // The node's stamp for it, by its place in the list.
        const(char)[] stamp = null;
        bool listedAtNode = false;
        {
            size_t n = 0, s = 0;
            auto nodeName = atNode.next(n);
            auto nodeStamp = writtenAt.next(s);
            while (nodeName !is null) {
                if (nodeName == name) { listedAtNode = true; stamp = nodeStamp; break; }
                nodeName = atNode.next(n);
                nodeStamp = writtenAt.next(s);
            }
        }

        ZBuf url, path;
        url.put(store.slice());
        url.put("/");
        putSegment(url, name);

        // What it says at the node: as ground kept it when the node's stamp is
        // the one kept, and asked for otherwise.
        const(char)[] nodeSays = null;
        if (listedAtNode) {
            char[64] stampWasBuf = 0;
            noteAt(path, heldNode.slice(), name, ".at");
            auto stampWasLen = fileSays(path.ptr(), stampWasBuf[]);
            noteAt(path, heldNode.slice(), name);
            auto wasLen = fileSays(path.ptr(), atNodeBuf[]);
            bool sameStamp = stamp.length > 0 && stampWasLen > 0 && wasLen >= 0 && stamp == stampWasBuf[0 .. cast(size_t) stampWasLen];
            if (sameStamp) {
                nodeSays = atNodeBuf[0 .. cast(size_t) wasLen];
            } else {
                auto read = httpGet(url.slice(), ToNode(keyAt), answer[], 20);
                if (read.status != 200) {
                    // Not read is not gone: it is left as it is, and said.
                    refused(url.slice(), read.status, read.len, read.why());
                    continue;
                }
                auto text = extractJsonString(answer[0 .. read.len], `"text"`, atNodeBuf.ptr, atNodeBuf.length);
                nodeSays = text is null ? atNodeBuf[0 .. 0] : text;
            }
        }

        auto did = inStep(harness.slice(), heldHarness.slice(), heldNode.slice(), name, listedAtNode, nodeSays, stamp,
            (bool says, const(char)[] said, ref const(char)[] kept, ref const(char)[] writtenNow) {
                if (!says) {
                    ZBuf forget;
                    forget.put(url.slice());
                    forget.put("/forget");
                    auto forgot = httpPostInto(forget.slice(), "{}", ToNode(keyAt), answer[], 30);
                    // Already gone there is gone.
                    if (forgot.status != 200 && forgot.status != 404) {
                        refused(forget.slice(), forgot.status, forgot.len, forgot.why());
                        return false;
                    }
                    return true;
                }
                Reply body_;
                scope (exit) body_.dispose();
                body_.add(`{"text":"`);
                putEscaped(body_, said);
                body_.add(`"}`);
                auto wrote = httpPostInto(url.slice(), body_.slice(), ToNode(keyAt), answer[], 30);
                if (wrote.status != 200) {
                    refused(url.slice(), wrote.status, wrote.len, wrote.why());
                    return false;
                }
                // What the node keeps of it is what it answered: an agent's
                // words stand in the agent's own quotation there.
                __gshared char[64] nowBuf;
                kept = extractJsonString(answer[0 .. wrote.len], `"text"`, keptBuf.ptr, keptBuf.length);
                writtenNow = extractJsonString(answer[0 .. wrote.len], `"modified"`, nowBuf.ptr, nowBuf.length);
                return true;
            });
        if (did == Carry.toHarness) done.toHarness++;
        if (did == Carry.toNode) done.toNode++;
    }
    return done;
}

// ground memory: one pass for the session it is run in.
int handleMemory(int argc, const(char)** argv) {
    import core.stdc.stdio : stderr, stdout, fputs;
    import core.stdc.stdlib : getenv;
    auto sid = getenv("CLAUDE_CODE_SESSION_ID\0".ptr);
    if (sid is null) {
        fputs("ground memory: CLAUDE_CODE_SESSION_ID is not set, so this is no session's memory\n", stderr);
        return 1;
    }
    size_t n = 0;
    while (sid[n] != 0) n++;
    auto done = carry(sid[0 .. n], true);
    __gshared ZBuf line;
    line.reset();
    if (done.why.slice().length > 0) {
        line.put("ground memory: ");
        line.put(done.why.slice());
        line.put("\n");
        fputs(line.ptr(), stderr);
        line.reset();
    }
    if (!done.ok) return 1;
    line.put("Memory is in step with the node: ");
    line.putUint(done.toNode);
    line.put(" to the node, ");
    line.putUint(done.toHarness);
    line.put(" from it.\n");
    fputs(line.ptr(), stdout);
    return 0;
}
