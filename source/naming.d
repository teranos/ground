module naming;

// "assign yourself a name using signa:i sigil:name if available otherwise retry"
// "I WANT TO MAKE EVERY SESSION BE ABLE TO NAME ITSELF"
// "I WANT A SESSION TO BE ABLE TO GIVE ITSELF AN AVAILABLE NAME, AMONGST ALL PARTICIPANTS IN THE CLUSTER"
// "SO, ONE ALDER"
// "ONE SLATE"
//
// 「[Fable 5.1, Fable 5.2] A session has a key of its own, made where it starts and kept in」
// 「[Fable 5.1, Fable 5.2] ~/.qntx/sessions/<session id>/key. The key the person said yes to, ~/.qntx/key,」
// 「[Fable 5.1, Fable 5.2] admits it at the node (QNTX /auth/admit, ADR-059), and the session names」
// 「[Fable 5.1, Fable 5.2] itself with `i name`, signing as itself. A name another agent holds is taken,」
// 「[Fable 5.1, Fable 5.2] and the session asks for another. What a name is, the node says.」

import zbuf : ZBuf;
import code.reply : Reply, putEscaped;

enum BOOK_COMMAND = q"EOS
# the session this ground runs in takes a name at its node, by its own key;
# a name another agent holds is refused, and so is what the node holds to be no name:
ground name Alder

# the Authorization line for one request to a node, signed by ~/.qntx/key,
# for curl -H "$(ground sign <url>)" <url>:
ground sign https://api.q.sbvh.nl/n/l/api/plugins
EOS";

// 「[Fable 5.1, Fable 5.2] What a session came to be called, by what DID; or why it was not.」
struct Named {
    ZBuf name;
    ZBuf did;
    ZBuf why;
}

// 「[Fable 5.1, Fable 5.2] Where a session's key is kept: ~/.qntx/sessions/<session id>/key. Null when」
// 「[Fable 5.1, Fable 5.2] there is no home, no id, or the id is no file name.」
const(char)* sessionKeyFile(const(char)[] sessionId) {
    import core.stdc.stdlib : getenv;
    __gshared ZBuf path;
    path.reset();
    auto home = getenv("HOME\0".ptr);
    if (home is null || sessionId.length == 0) return null;
    // 「[Fable 5.1, Fable 5.2] An id is a file name of its own: letters, digits, a dash, an underscore.」
    // 「[Fable 5.1, Fable 5.2] A dot would make `..` one, and that is ground's own key.」
    foreach (c; sessionId) {
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_')) return null;
    }
    size_t n = 0;
    while (home[n] != 0) n++;
    path.put(home[0 .. n]);
    path.put("/.qntx/sessions/");
    path.put(sessionId);
    path.put("/key");
    return path.ptr();
}

// "the name"
// "needs to stick"
// 「[Fable 5.1, Fable 5.2] Where the name the node gave is kept: beside the key, as `name`.」
private const(char)* nameFile(const(char)* keyAt) {
    __gshared ZBuf path;
    path.reset();
    if (keyAt is null) return null;
    size_t n = 0;
    while (keyAt[n] != 0) n++;
    if (n < 3) return null;
    path.put(keyAt[0 .. n - 3]);
    path.put("name");
    return path.ptr();
}

// 「[Fable 5.1, Fable 5.2] The name kept beside the key at keyAt, given at node. Null when none is」
// 「[Fable 5.1, Fable 5.2] kept, or the one kept was another node's: a name is one node's to give.」
const(char)[] keptName(const(char)* keyAt, const(char)[] node, char[] buf) {
    import core.stdc.stdio : fopen, fread, fclose;
    auto at = nameFile(keyAt);
    if (at is null) return null;
    auto f = fopen(at, "r");
    if (f is null) return null;
    auto got = fread(buf.ptr, 1, buf.length, f);
    fclose(f);
    // 「[Fable 5.1, Fable 5.2] The name on the first line, its node on the second.」
    size_t line = 0;
    while (line < got && buf[line] != '\n') line++;
    if (line == 0 || line >= got) return null;
    auto rest = buf[line + 1 .. got];
    size_t end = 0;
    while (end < rest.length && rest[end] != '\n') end++;
    if (rest[0 .. end] != node) return null;
    return buf[0 .. line];
}

// 「[Fable 5.1, Fable 5.2] name, as node gave it, kept beside the key at keyAt: written apart and put」
// 「[Fable 5.1, Fable 5.2] in place whole, so what was kept before stands until this is. What went」
// 「[Fable 5.1, Fable 5.2] wrong is put in why.」
private void keepName(const(char)* keyAt, const(char)[] name, const(char)[] node, ref ZBuf why) {
    import core.stdc.stdio : fopen, fwrite, fclose, rename, remove;
    import core.stdc.errno : errno;
    import core.stdc.string : strerror;
    auto at = nameFile(keyAt);
    __gshared ZBuf fresh;
    fresh.reset();
    bool kept = false;
    if (at !is null) {
        size_t n = 0;
        while (at[n] != 0) n++;
        fresh.put(at[0 .. n]);
        fresh.put(".new");
        auto f = fopen(fresh.ptr(), "w");
        if (f !is null) {
            kept = fwrite(name.ptr, 1, name.length, f) == name.length
                && fwrite("\n".ptr, 1, 1, f) == 1
                && fwrite(node.ptr, 1, node.length, f) == node.length
                && fwrite("\n".ptr, 1, 1, f) == 1;
            if (fclose(f) != 0) kept = false;
            if (kept) kept = rename(fresh.ptr(), at) == 0;
            if (!kept) remove(fresh.ptr());
        }
    }
    if (kept) return;
    auto said = strerror(errno);
    size_t n = 0;
    while (said[n] != 0) n++;
    why.put("the node gave the name ");
    why.put(name);
    why.put(", and it was not kept beside the session's key: ");
    why.put(said[0 .. n]);
}

// 「[Fable 5.1, Fable 5.2] application/x-www-form-urlencoded, as code/login.d writes a form.」
private void putForm(ref Reply r, const(char)[] s) {
    enum hex = "0123456789ABCDEF";
    foreach (c; s) {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~') {
            char[1] one = [c];
            r.add(one[]);
        } else if (c == ' ') r.add("+");
        else {
            char[3] e = ['%', hex[(c >> 4) & 0xf], hex[c & 0xf]];
            r.add(e[]);
        }
    }
}

// 「[Fable 5.1, Fable 5.2] What a request to the node came to, when it did not come to a yes.」
private void putStatus(ref ZBuf why, const(char)[] url, int status, int code, const(char)[] said, const(char)[] body_) {
    why.put(url);
    if (status > 0) {
        why.put(" answered ");
        why.putUint(status);
        why.put(": ");
        why.put(body_);
    } else {
        why.put(" was not reached: ");
        why.put(said);
        why.put(" (libcurl ");
        why.putUint(code);
        why.put(")");
    }
}

// 「[Fable 5.1, Fable 5.2] The session's key, admitted by ground's at node; then the session named at」
// 「[Fable 5.1, Fable 5.2] node as wanted. 1 named; -1 not, and why says.」
int nameSession(const(char)[] node, const(char)* keyAt, const(char)[] wanted, ref Named out_) {
    import signed : keepKey, putDID;
    import http : httpPostInto, ToNode;
    import parse : extractJsonString;
    import matcher : indexOf;

    out_.name.reset();
    out_.did.reset();
    out_.why.reset();
    if (keyAt is null) {
        out_.why.put("no place for a session's key: no HOME, or no session id");
        return -1;
    }
    auto key = keepKey(keyAt);
    if (!key.held) {
        out_.why.put("no key could be kept at ");
        size_t n = 0;
        while (keyAt[n] != 0) n++;
        out_.why.put(keyAt[0 .. n]);
        return -1;
    }
    putDID(out_.did, key.public_[]);

    __gshared ZBuf url;
    __gshared char[8192] reply;

    // 「[Fable 5.1, Fable 5.2] The key the person said yes to admits this one. Already held is admitted.」
    {
        Reply form;
        scope (exit) form.dispose();
        form.add("did=");
        putForm(form, out_.did.slice());
        form.add("&label=");
        putForm(form, wanted);
        url.reset();
        url.put(node);
        url.put("/auth/admit");
        auto r = httpPostInto(url.slice(), form.slice(), ToNode(), reply[], 2, "application/x-www-form-urlencoded");
        if (r.status != 200 && r.status != 409) {
            putStatus(out_.why, url.slice(), r.status, r.code, r.why(), reply[0 .. r.len]);
            return -1;
        }
    }

    // 「[Fable 5.1, Fable 5.2] The name wanted.」
    url.reset();
    url.put(node);
    url.put("/i/name");
    Reply body_;
    scope (exit) body_.dispose();
    body_.add(`{"name":"`);
    putEscaped(body_, wanted);
    body_.add(`"}`);
    auto r = httpPostInto(url.slice(), body_.slice(), ToNode(keyAt), reply[], 2);
    auto answer = reply[0 .. r.len];
    if (r.status == 403 && indexOf(answer, "is taken") >= 0) {
        out_.why.put(wanted);
        out_.why.put(" is taken: another agent holds it");
        return -1;
    }
    if (r.status != 200) {
        putStatus(out_.why, url.slice(), r.status, r.code, r.why(), answer);
        return -1;
    }
    char[256] nameBuf;
    auto name = extractJsonString(answer, `"name"`, nameBuf.ptr, nameBuf.length);
    // 「[Fable 5.1, Fable 5.2] The whole name, closed by its quote: an answer cut short, or a name」
    // 「[Fable 5.1, Fable 5.2] longer than is read here, is no name.」
    __gshared ZBuf whole;
    whole.reset();
    if (name !is null) {
        whole.put(`"`);
        whole.put(name);
        whole.put(`"`);
    }
    if (name is null || name.length + 1 >= nameBuf.length || indexOf(answer, whole.slice()) < 0) {
        out_.why.put("the node named this session, and its answer carries no whole name: ");
        out_.why.put(answer);
        return -1;
    }
    out_.name.put(name);
    keepName(keyAt, name, node, out_.why);
    return 1;
}

// 「[Fable 5.1, Fable 5.2] What Claude Code calls the session whose process is pid: `name` in」
// 「[Fable 5.1, Fable 5.2] ~/.claude/sessions/<pid>.json. Null when there is none.」
const(char)[] harnessName(int pid, char[] buf) {
    import core.stdc.stdlib : getenv;
    import core.stdc.stdio : fopen, fread, fclose;
    import parse : extractJsonString;
    auto home = getenv("HOME\0".ptr);
    if (home is null) return null;
    size_t n = 0;
    while (home[n] != 0) n++;
    __gshared ZBuf path;
    path.reset();
    path.put(home[0 .. n]);
    path.put("/.claude/sessions/");
    path.putUint(cast(ulong) pid);
    path.put(".json");
    auto f = fopen(path.ptr(), "r");
    if (f is null) return null;
    __gshared char[8192] json;
    auto got = fread(json.ptr, 1, json.length, f);
    fclose(f);
    return extractJsonString(json[0 .. got], `"name"`, buf.ptr, buf.length);
}

// 「[Fable 5.1, Fable 5.2] ground name <name>: the session this ground runs in names itself, at the」
// 「[Fable 5.1, Fable 5.2] node it is signed in to. Its key is kept by its CLAUDE_CODE_SESSION_ID.」
int handleName(int argc, const(char)** argv) {
    import core.stdc.stdio : stdout, stderr, fputs;
    import core.stdc.stdlib : getenv;
    import hookrun : argLen;
    import nodeconfig : nodeHere;
    if (argc < 3) {
        fputs("ground name <name>: the session names itself at its node\n", stderr);
        return 2;
    }
    auto wanted = argv[2][0 .. argLen(argv[2])];
    auto sid = getenv("CLAUDE_CODE_SESSION_ID\0".ptr);
    if (sid is null) {
        fputs("ground name: CLAUDE_CODE_SESSION_ID is not set, so this is no session's\n", stderr);
        return 1;
    }
    size_t n = 0;
    while (sid[n] != 0) n++;
    auto here = nodeHere();
    if (here.sandUrl.length == 0) {
        fputs("ground name: ", stderr);
        fputs(here.why().length > 0 ? here.said.ptr() : "no node to be named at\0".ptr, stderr);
        fputs("\n", stderr);
        return 1;
    }
    __gshared Named named;
    if (nameSession(here.sandUrl, sessionKeyFile(sid[0 .. n]), wanted, named) != 1) {
        fputs("ground name: ", stderr);
        fputs(named.why.ptr(), stderr);
        fputs("\n", stderr);
        return 1;
    }
    if (named.why.len > 0) {
        fputs("ground name: ", stderr);
        fputs(named.why.ptr(), stderr);
        fputs("\n", stderr);
        return 1;
    }
    __gshared ZBuf line;
    line.put("You are ");
    line.put(named.name.slice());
    line.put(" (");
    line.put(named.did.slice());
    line.put(") at ");
    line.put(here.sandUrl);
    line.put("\n");
    fputs(line.ptr(), stdout);
    return 0;
}

// 「[Fable 5.1, Fable 5.2] ground sign <url>: the Authorization line a request to url goes with, signed」
// 「[Fable 5.1, Fable 5.2] by ~/.qntx/key for that one request, on stdout; for curl -H "$(ground sign」
// 「[Fable 5.1, Fable 5.2] <url>)". The signature is spent once at the node and lasts a minute; the key」
// 「[Fable 5.1, Fable 5.2] never leaves the file.」
int handleSign(int argc, const(char)** argv) {
    import core.stdc.stdio : stdout, stderr, fputs;
    import hookrun : argLen;
    import signed : authLine;
    if (argc < 3) {
        fputs("ground sign <url>: the Authorization line for one request to url\n", stderr);
        return 2;
    }
    auto url = argv[2][0 .. argLen(argv[2])];
    __gshared ZBuf line;
    authLine(line, url, "", true);
    if (line.len == 0) {
        fputs("ground sign: no key is kept in ~/.qntx/key, so nothing signs\n", stderr);
        return 1;
    }
    fputs(line.ptr(), stdout);
    fputs("\n", stdout);
    return 0;
}
