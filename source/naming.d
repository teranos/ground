module naming;

// "assign yourself a name using signa:i sigil:name if available otherwise retry"
// "I WANT TO MAKE EVERY SESSION BE ABLE TO NAME ITSELF"
// "I WANT A SESSION TO BE ABLE TO GIVE ITSELF AN AVAILABLE NAME, AMONGST ALL PARTICIPANTS IN THE CLUSTER"
// "SO, ONE ALDER"
// "ONE SLATE"
//
// A session has a key of its own, made where it starts and kept in
// ~/.qntx/sessions/<session id>/key. The key the person said yes to, ~/.qntx/key,
// admits it at the node (QNTX /auth/admit, ADR-059), and the session names
// itself with `i name`, signing as itself. A name another agent holds is taken:
// the next is asked for, up to ten.

import zbuf : ZBuf;
import code.reply : Reply, putEscaped;

enum BOOK_COMMAND = q"EOS
# the session this ground runs in takes a name at its node, by its own key;
# a name another agent holds is refused, and SessionStart took the next one free:
ground name Alder

# the Authorization line for one request to a node, signed by ~/.qntx/key,
# for curl -H "$(ground sign <url>)" <url>:
ground sign https://api.q.sbvh.nl/n/l/api/plugins
EOS";

// What a session came to be called, by what DID; or why it was not.
struct Named {
    ZBuf name;
    ZBuf did;
    ZBuf why;
}

// How many names are asked for before giving up: the one wanted, then -1 .. -9.
enum TRIES = 10;

// Where a session's key is kept: ~/.qntx/sessions/<session id>/key. Null when
// there is no home, no id, or the id is no file name.
const(char)* sessionKeyFile(const(char)[] sessionId) {
    import core.stdc.stdlib : getenv;
    __gshared ZBuf path;
    path.reset();
    auto home = getenv("HOME\0".ptr);
    if (home is null || sessionId.length == 0) return null;
    foreach (c; sessionId) if (c == '/' || c == 0) return null;
    size_t n = 0;
    while (home[n] != 0) n++;
    path.put(home[0 .. n]);
    path.put("/.qntx/sessions/");
    path.put(sessionId);
    path.put("/key");
    return path.ptr();
}

// application/x-www-form-urlencoded, as code/login.d writes a form.
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

// What a request to the node came to, when it did not come to a yes.
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

// The session's key, admitted by ground's at node; then the session named at
// node as wanted, or the next name free. 1 named; -1 not, and why says.
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

    // The key the person said yes to admits this one. Already held is admitted.
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
        auto r = httpPostInto(url.slice(), form.slice(), ToNode(), reply[], 5, "application/x-www-form-urlencoded");
        if (r.status != 200 && r.status != 409) {
            putStatus(out_.why, url.slice(), r.status, r.code, r.why(), reply[0 .. r.len]);
            return -1;
        }
    }

    // The name wanted, else the next one free.
    url.reset();
    url.put(node);
    url.put("/i/name");
    foreach (attempt; 0 .. TRIES) {
        Reply body_;
        scope (exit) body_.dispose();
        body_.add(`{"name":"`);
        putEscaped(body_, wanted);
        if (attempt > 0) {
            char[2] suffix = ['-', cast(char)('0' + attempt)];
            body_.add(suffix[]);
        }
        body_.add(`"}`);
        auto r = httpPostInto(url.slice(), body_.slice(), ToNode(keyAt), reply[], 5);
        auto answer = reply[0 .. r.len];
        if (r.status == 200) {
            char[256] nameBuf;
            auto name = extractJsonString(answer, `"name"`, nameBuf.ptr, nameBuf.length);
            if (name is null) {
                out_.why.put("the node named this session, and its answer carries no name: ");
                out_.why.put(answer);
                return -1;
            }
            out_.name.put(name);
            return 1;
        }
        if (r.status == 403 && indexOf(answer, "is taken") >= 0) continue;
        putStatus(out_.why, url.slice(), r.status, r.code, r.why(), answer);
        return -1;
    }
    out_.why.put(wanted);
    out_.why.put(" and the nine after it are taken");
    return -1;
}

// What Claude Code calls the session whose process is pid: `name` in
// ~/.claude/sessions/<pid>.json. Null when there is none.
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

// ground name <name>: the session this ground runs in names itself, at the
// node it is signed in to. Its key is kept by its CLAUDE_CODE_SESSION_ID.
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

// ground sign <url>: the Authorization line a request to url goes with, signed
// by ~/.qntx/key for that one request, on stdout; for curl -H "$(ground sign
// <url>)". The signature is spent once at the node and lasts a minute; the key
// never leaves the file.
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
