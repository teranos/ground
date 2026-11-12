module say;

// "SESSION ALDER SPEAKS TO SLATE ON K"
// "BY NAME"
// "VIA SAY"
// "AGENTS CAN TALK TO EACH OTHER BY THEIR NAME"
// "A SESSION THATS SENDING TO ANOTHER SESSION BY NAME IS TOLD ABOUT THE MESSAGE BEING RECEIVED OR NOT, AND WE DONT INVENT HERE, WE TAKE THE A2A CONVENTIONS, WE TAKE THE SDK SERIOUSLY"
//
// A name an agent holds is an A2A tenant at its node (QNTX #1671): what is
// said to it is a Task. The session says it with its own key, and asks after
// the Task by its id.

import zbuf : ZBuf;
import code.reply : Reply, putEscaped;

enum BOOK_COMMAND = q"EOS
# say something to the session that holds a name, as this session, by its own key:
ground say Slate "the build on k is red"

# whether what was said was received, by the Task the saying answered with:
ground heard Slate 01a1d0c3-0922-759f-a495-a1e92e3a6851

# say by hand that this session received what a Task said to its name; sky
# says so itself as it hands the words over:
ground received 01a1d0c3-0922-759f-a495-a1e92e3a6851
EOS";

// The node's A2A address of a name: its tenant. A space in a name of two
// words is written as the address writes one.
void tenantUrl(ref ZBuf url, const(char)[] node, const(char)[] name) {
    url.reset();
    url.put(node);
    url.put("/a2a/");
    foreach (c; name) {
        if (c == ' ') url.put("%20");
        else { char[1] one = [c]; url.put(one[]); }
    }
}

// What a Task is in, in the words it is told in.
const(char)[] stateSaid(const(char)[] state) {
    if (state == "TASK_STATE_SUBMITTED") return "is not received yet";
    if (state == "TASK_STATE_WORKING") return "is being received";
    if (state == "TASK_STATE_COMPLETED") return "was received";
    if (state == "TASK_STATE_FAILED") return "was not received";
    if (state == "TASK_STATE_CANCELED") return "was taken back";
    if (state == "TASK_STATE_REJECTED") return "was refused";
    return state;
}

private struct Asking {
    const(char)[] node;
    const(char)* keyAt;
    bool ok;
}

// The node this session is signed in to and the key it says things by, or why
// not, said on stderr.
private Asking asking(const(char)* what) {
    import core.stdc.stdio : stderr, fputs;
    import core.stdc.stdlib : getenv;
    import nodeconfig : nodeHere;
    import naming : sessionKeyFile;
    Asking a;
    void no(const(char)* why) {
        fputs(what, stderr);
        fputs(": ", stderr);
        fputs(why, stderr);
        fputs("\n", stderr);
    }
    auto sid = getenv("CLAUDE_CODE_SESSION_ID\0".ptr);
    if (sid is null) { no("CLAUDE_CODE_SESSION_ID is not set, so this is no session's to say"); return a; }
    size_t n = 0;
    while (sid[n] != 0) n++;
    auto here = nodeHere();
    if (here.sandUrl.length == 0) { no("no node to say it at"); return a; }
    a.keyAt = sessionKeyFile(sid[0 .. n]);
    if (a.keyAt is null) { no("this session has no key of its own to say it by"); return a; }
    a.node = here.sandUrl;
    a.ok = true;
    return a;
}

// "do you think the ground say should show near misses ?"
// What a node says of a name nobody holds, in words: nobody holds it, and the
// names near it when the node gave some (QNTX #1686). Empty when the answer is
// about something else.
const(char)[] nobodyHolds(const(char)[] name, const(char)[] answer, ref ZBuf line) {
    import matcher : indexOf;
    enum none = "no agent is served at tenant ";
    if (indexOf(answer, none) < 0) return "";
    line.reset();
    line.put("nobody holds the name ");
    line.put(name);
    enum near = ". Near it: ";
    auto at = indexOf(answer, near);
    if (at >= 0) {
        auto rest = answer[at + near.length .. $];
        size_t end = 0;
        while (end < rest.length && rest[end] != '"' && rest[end] != '\\') end++;
        line.put(". Near it: ");
        line.put(rest[0 .. end]);
    }
    return line.slice();
}

// What the node answered with, said whole when it was no Task.
private int refused(const(char)* what, const(char)[] url, int status, int code, const(char)[] why, const(char)[] answer) {
    import core.stdc.stdio : stderr, fputs;
    __gshared ZBuf line;
    line.reset();
    line.put(url);
    if (status > 0) {
        line.put(" answered ");
        line.putUint(status);
        line.put(": ");
        line.put(answer);
    } else {
        line.put(" was not reached: ");
        line.put(why);
        line.put(" (libcurl ");
        line.putUint(code);
        line.put(")");
    }
    line.put("\n");
    fputs(what, stderr);
    fputs(": ", stderr);
    fputs(line.ptr(), stderr);
    return 1;
}

// The row ug writes news as: the item's id after it, which for what was said
// to a name is its Task's.
enum NEWS_ROW = "immediate:news:";

// The session asks its node for the whole of a news item, by its own key: for
// what was said to its name, that is the node hearing it was received (QNTX
// #1684). Any other news is asked for and nothing follows. Empty when the node
// answered, whatever it answered; else why it was not reached.
const(char)[] toldTheNode(const(char)[] sessionId, const(char)[] item) {
    import http : httpGet, ToNode;
    import nodeconfig : nodeHere;
    import naming : sessionKeyFile;
    foreach (c; item) {
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-')) return "";
    }
    auto here = nodeHere();
    auto keyAt = sessionKeyFile(sessionId);
    // No node to say it to, or no key to say it by, is not said: and is said so.
    if (here.sandUrl.length == 0) return "this ground is signed in to no node, so nothing was said as received";
    if (keyAt is null) return "this session has no key of its own, so nothing was said as received";
    __gshared ZBuf url;
    url.reset();
    url.put(here.sandUrl);
    url.put("/am/statusline/");
    url.put(item);
    __gshared char[4096] reply;
    auto r = httpGet(url.slice(), ToNode(keyAt), reply[], 15);
    // The node answered with the item: it heard who asked.
    if (r.status == 200) return "";
    __gshared ZBuf why;
    why.reset();
    why.put(url.slice());
    if (r.status > 0) {
        why.put(" answered ");
        why.putUint(r.status);
        why.put(": ");
        why.put(reply[0 .. r.len]);
    } else {
        why.put(" was not reached: ");
        why.put(r.why());
    }
    return why.slice();
}

// ground received <task>: this session says to its node, by its own key, that
// it received what a Task said to its name. sky says so as it hands news over;
// this is the same said by hand.
int handleReceived(int argc, const(char)** argv) {
    import core.stdc.stdio : stdout, stderr, fputs;
    import core.stdc.stdlib : getenv;
    import hookrun : argLen;
    if (argc < 3) {
        fputs("ground received <task>: say to the node that this session received what was said to its name\n", stderr);
        return 2;
    }
    auto sid = getenv("CLAUDE_CODE_SESSION_ID\0".ptr);
    if (sid is null) {
        fputs("ground received: CLAUDE_CODE_SESSION_ID is not set, so this is no session's to say\n", stderr);
        return 1;
    }
    size_t n = 0;
    while (sid[n] != 0) n++;
    auto why = toldTheNode(sid[0 .. n], argv[2][0 .. argLen(argv[2])]);
    if (why.length > 0) {
        fputs("ground received: ", stderr);
        __gshared ZBuf line;
        line.reset();
        line.put(why);
        line.put("\n");
        fputs(line.ptr(), stderr);
        return 1;
    }
    fputs("Said to the node as received.\n", stdout);
    return 0;
}

// ground say <Name> <words>: said to the agent that holds the name, as a Task.
int handleSay(int argc, const(char)** argv) {
    import core.stdc.stdio : stdout, stderr, fputs;
    import core.stdc.time : time;
    import core.sys.posix.unistd : getpid;
    import hookrun : argLen;
    import http : httpPostInto, ToNode;
    import parse : extractJsonString;

    if (argc < 4) {
        fputs("ground say <Name> <words>: say something to the session that holds the name\n", stderr);
        return 2;
    }
    auto name = argv[2][0 .. argLen(argv[2])];
    auto who = asking("ground say");
    if (!who.ok) return 1;

    __gshared ZBuf url;
    tenantUrl(url, who.node, name);
    url.put("/message:send");

    Reply body_;
    scope (exit) body_.dispose();
    body_.add(`{"message":{"messageId":"ground-say-`);
    __gshared ZBuf id;
    id.reset();
    id.putUint(cast(ulong) time(null));
    id.put("-");
    id.putUint(cast(ulong) getpid());
    body_.add(id.slice());
    body_.add(`","role":"ROLE_USER","parts":[{"text":"`);
    foreach (i; 3 .. argc) {
        if (i > 3) body_.add(" ");
        putEscaped(body_, argv[i][0 .. argLen(argv[i])]);
    }
    body_.add(`"}]},"configuration":{"returnImmediately":true}}`);

    __gshared char[16384] reply;
    auto r = httpPostInto(url.slice(), body_.slice(), ToNode(who.keyAt), reply[], 60);
    auto answer = reply[0 .. r.len];
    if (r.status == 404) {
        __gshared ZBuf nobody;
        auto said = nobodyHolds(name, answer, nobody);
        if (said.length > 0) {
            fputs("ground say: ", stderr);
            nobody.put("\n");
            fputs(nobody.ptr(), stderr);
            return 1;
        }
    }
    if (r.status != 200) return refused("ground say", url.slice(), r.status, r.code, r.why(), answer);

    char[128] taskBuf, stateBuf;
    auto task = extractJsonString(answer, `"id"`, taskBuf.ptr, taskBuf.length);
    auto state = extractJsonString(answer, `"state"`, stateBuf.ptr, stateBuf.length);
    if (task is null || state is null) return refused("ground say", url.slice(), r.status, r.code, r.why(), answer);

    __gshared ZBuf line;
    line.reset();
    line.put("Said to ");
    line.put(name);
    line.put(", and it ");
    line.put(stateSaid(state));
    line.put(". Task ");
    line.put(task);
    line.put(": `ground heard ");
    line.put(name);
    line.put(" ");
    line.put(task);
    line.put("` says whether it was received.\n");
    fputs(line.ptr(), stdout);
    return 0;
}

// ground heard <Name> <task>: whether what was said to the name was received.
int handleHeard(int argc, const(char)** argv) {
    import core.stdc.stdio : stdout, stderr, fputs;
    import hookrun : argLen;
    import http : httpGet, ToNode;
    import parse : extractJsonString;

    if (argc < 4) {
        fputs("ground heard <Name> <task>: whether what was said to the name was received\n", stderr);
        return 2;
    }
    auto name = argv[2][0 .. argLen(argv[2])];
    auto task = argv[3][0 .. argLen(argv[3])];
    foreach (c; task) {
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-')) {
            fputs("ground heard: that is no Task's id\n", stderr);
            return 2;
        }
    }
    auto who = asking("ground heard");
    if (!who.ok) return 1;

    __gshared ZBuf url;
    tenantUrl(url, who.node, name);
    url.put("/tasks/");
    url.put(task);

    __gshared char[16384] reply;
    auto r = httpGet(url.slice(), ToNode(who.keyAt), reply[], 30);
    auto answer = reply[0 .. r.len];
    if (r.status != 200) return refused("ground heard", url.slice(), r.status, r.code, r.why(), answer);
    char[128] stateBuf;
    auto state = extractJsonString(answer, `"state"`, stateBuf.ptr, stateBuf.length);
    if (state is null) return refused("ground heard", url.slice(), r.status, r.code, r.why(), answer);

    __gshared ZBuf line;
    line.reset();
    line.put("What was said to ");
    line.put(name);
    line.put(" ");
    line.put(stateSaid(state));
    line.put(".\n");
    fputs(line.ptr(), stdout);
    return 0;
}
