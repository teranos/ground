module bin.mycelia;

// "so, why would the part that asks the node, not be able to be its own tiny binary"
import mycelia : myceliaMain, verbOf, Verb, SOCKET, DOOR_PATH, homeUrlInto, ticketOf, resultUrlInto,
    sessionSaidPathInto;
static import zbuf;

// The Keychain, behind Touch ID (ug/touch.c).
extern (C) int touch_keep(const(ubyte)* held, int n);
extern (C) int touch_take(ubyte* out_, int cap, const(char)* prompt, int* n);
extern (C) void touch_said(int st, char* out_, int cap);
// The url the system opened Mycelia.app with (ug/door.m).
extern (C) int door_url(char* out_, int cap, double seconds);

// The person's session, once a touch has taken it out of the Keychain or the
// door has just collected it: held until mycelia stops, which a reboot or a
// restart is.
__gshared char[256] session = void;
__gshared size_t sessionLen;

// Apple's words for an OSStatus.
const(char)[] saidOf(int st) {
    __gshared char[256] why = 0;
    why[] = 0;
    touch_said(st, why.ptr, why.length);
    size_t n = 0;
    while (why[n] != 0) n++;
    return why[0 .. n];
}

void putStatus(ref zbuf.ZBuf b, int st) {
    if (st < 0) { b.put("-"); b.putUint(cast(ulong) -st); } else b.putUint(cast(ulong) st);
}

// A press, made in the person's session: the node's status on the first line
// of reply, its body after; 0 and why when it was not asked.
int press(const(char)[] path, const(char)[] body_, ref zbuf.ZBuf reply) {
    import http : httpPostInto;
    import probe : host;
    if (sessionLen == 0) {
        int n = 0;
        auto st = touch_take(cast(ubyte*) session.ptr, session.length,
            "mycelia: trust your presses until this Mac restarts\0".ptr, &n);
        if (st != 0 || n <= 0) {
            reply.put("0\nthe person's session was not taken out of the Keychain: OSStatus ");
            putStatus(reply, st);
            reply.put(" ");
            reply.put(saidOf(st));
            // errSecItemNotFound: nothing was ever collected at the door.
            reply.put(st == -25300 ? " (mycelia connect collects one)" : "");
            return 1;
        }
        sessionLen = n;
    }
    __gshared zbuf.ZBuf url;
    url.reset();
    url.put(host());
    url.put(path);
    __gshared char[65536] answer = void;
    auto r = httpPostInto(url.slice(), body_, session[0 .. sessionLen], answer[], 60);
    reply.putUint(cast(ulong) r.status);
    reply.put("\n");
    if (r.status > 0) reply.put(answer[0 .. r.len]);
    else {
        reply.put(url.slice());
        reply.put(" was not reached: ");
        reply.put(r.why());
    }
    return 0;
}

__gshared const(char)[] homeHeld;

// What mycelia says of the session, beside the row: the moment, then the words.
void sessionSaid(const(char)[] words) {
    import mycelia : keepAt;
    import core.stdc.time : time;
    __gshared char[512] path = void;
    auto n = sessionSaidPathInto(homeHeld, path[]);
    if (n > 0) keepAt(path[0 .. n], cast(long) time(null), words);
}

// The browser came back to the door: the ticket is spent for the session,
// which is kept in the Keychain and held. What happened is said beside the
// row, for mycelia connect, and answered: the node's status on a line, then
// the words.
int door(const(char)[] url, ref zbuf.ZBuf reply) {
    import http : httpGet;
    import probe : host;
    import json : jsonString;
    __gshared zbuf.ZBuf said;
    said.reset();
    scope (exit) {
        sessionSaid(said.slice());
        reply.put(said.slice());
    }
    auto ticket = ticketOf(url);
    if (ticket.length == 0) {
        said.put("0\nthe browser came back to the door with no ticket: ");
        said.put(url);
        return 1;
    }
    __gshared char[1024] at = void;
    auto u = resultUrlInto(host(), ticket, at[]);
    __gshared char[8192] answer = void;
    auto r = httpGet(at[0 .. u], null, answer[], 30);
    auto body_ = answer[0 .. r.len];
    auto held = r.status == 200 ? jsonString(body_, "session") : null;
    if (held is null || held.length == 0 || held.length > session.length) {
        said.putUint(cast(ulong) r.status);
        said.put("\nthe node did not hand over the session: ");
        said.put(r.status > 0 ? body_ : r.why());
        return 1;
    }
    auto st = touch_keep(cast(const(ubyte)*) held.ptr, cast(int) held.length);
    if (st != 0) {
        said.put("0\nthe session was not kept in the Keychain: OSStatus ");
        putStatus(said, st);
        said.put(" ");
        said.put(saidOf(st));
        return 1;
    }
    foreach (i, c; held) session[i] = c;
    sessionLen = held.length;
    said.put("200\nkept, signed in as ");
    auto name = jsonString(body_, "name");
    said.put(name !is null && name.length > 0 ? name : "nobody named");
    said.put(" (");
    said.put(jsonString(body_, "admitted_as"));
    said.put("); presses are made in this session");
    return 0;
}

// The socket of the mycelia that is running, connected; -1 when none answers.
int running(const(char)[] home) {
    import core.sys.posix.sys.socket : socket, connect, AF_UNIX, SOCK_STREAM, sockaddr;
    import core.sys.posix.sys.un : sockaddr_un;
    import core.sys.posix.unistd : close;
    sockaddr_un at;
    if (home.length == 0 || home.length + SOCKET.length + 2 > at.sun_path.length) return -1;
    size_t o = 0;
    foreach (c; home) at.sun_path[o++] = cast(byte) c;
    if (at.sun_path[o - 1] != '/') at.sun_path[o++] = '/';
    foreach (c; SOCKET) at.sun_path[o++] = cast(byte) c;
    at.sun_path[o] = 0;
    at.sun_family = AF_UNIX;
    auto fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (connect(fd, cast(sockaddr*) &at, cast(uint) sockaddr_un.sizeof) != 0) { close(fd); return -1; }
    return fd;
}

// The system started this Mycelia.app for a url while another mycelia runs:
// the url is that one's to collect.
int handOver(int fd) {
    import core.sys.posix.sys.socket : shutdown, SHUT_WR;
    import core.sys.posix.unistd : read, write, close;
    import core.stdc.stdio : fwrite, stderr;
    __gshared char[4096] url = void;
    auto n = door_url(url.ptr, url.length, 10.0);
    if (n <= 0) {
        close(fd);
        enum none = "mycelia: another mycelia is running, and no url came for its door\n";
        fwrite(none.ptr, 1, none.length, stderr);
        return 1;
    }
    write(fd, DOOR_PATH.ptr, DOOR_PATH.length);
    write(fd, "\n".ptr, 1);
    write(fd, url.ptr, n);
    shutdown(fd, SHUT_WR);
    __gshared char[4096] answer = void;
    size_t got = 0;
    while (got < answer.length) {
        auto r = read(fd, &answer[got], answer.length - got);
        if (r <= 0) break;
        got += r;
    }
    close(fd);
    fwrite(answer.ptr, 1, got, stderr);
    fwrite("\n".ptr, 1, 1, stderr);
    return 0;
}

// The person is sent home for the passkey, in the browser; the node sends the
// browser back to the door, and the mycelia that is running collects the
// session. This waits for what it says of it.
int connectMain(const(char)[] home) {
    import probe : host;
    import mycelia : keptOf;
    import core.stdc.stdio : fwrite, fflush, stdout, fopen, fread, fclose;
    import core.stdc.time : time;
    import core.sys.posix.unistd : close, sleep;
    import core.sys.posix.spawn : posix_spawn;
    import core.sys.posix.sys.wait : waitpid;
    void say(const(char)[] s) { fwrite(s.ptr, 1, s.length, stdout); fflush(stdout); }

    auto fd = running(home);
    if (fd < 0) { say("mycelia connect: no mycelia is running, so nobody is at the door to collect the session\n"); return 1; }
    close(fd);

    __gshared char[512] url = void;
    auto u = homeUrlInto(host(), url[]);
    if (u == 0) { say("mycelia connect: no node is named to sign in to\n"); return 1; }
    auto since = cast(long) time(null);
    const(char)*[3] argv = ["/usr/bin/open\0".ptr, &url[0], null];
    int pid;
    if (posix_spawn(&pid, argv[0], null, null, cast(char**) argv.ptr, null) != 0) {
        say("mycelia connect: the browser could not be opened at "); say(url[0 .. u]); say("\n");
        return 1;
    }
    int status;
    waitpid(pid, &status, 0);
    say("The passkey is asked for in the browser, at "); say(url[0 .. u]);
    say("\nmycelia collects the session the node sends back.\n");

    __gshared char[512] path = void;
    sessionSaidPathInto(home, path[]);
    // The node keeps a journey home for ten minutes (QNTX homewardTTL).
    foreach (_; 0 .. 600) {
        sleep(1);
        auto f = fopen(&path[0], "rb");
        if (f is null) continue;
        __gshared char[4096] buf = void;
        auto n = fread(&buf[0], 1, buf.length, f);
        fclose(f);
        auto kept = keptOf(buf[0 .. n]);
        if (kept.at < since) continue;
        // The node's status on a line, then what happened.
        auto words = kept.line;
        size_t nl = 0;
        while (nl < words.length && words[nl] != '\n') nl++;
        auto ok = words[0 .. nl] == "200";
        say(ok ? "mycelia connect: " : "mycelia connect: not connected: ");
        say(nl < words.length ? words[nl + 1 .. $] : words);
        say("\n");
        return ok ? 0 : 1;
    }
    say("mycelia connect: nothing came back to the door within ten minutes, which is as long as the node keeps the journey\n");
    return 1;
}

extern (C) int main(int argc, char** argv) {
    import core.stdc.stdlib : getenv;
    import core.stdc.stdio : fputs, stderr;

    const(char)[] verb;
    if (argc >= 2 && argv[1] !is null) {
        size_t al = 0;
        while (argv[1][al] != 0) al++;
        verb = argv[1][0 .. al];
    }
    auto h = getenv("HOME\0".ptr);
    size_t hl = 0;
    if (h !is null) while (h[hl] != 0) hl++;
    homeHeld = h[0 .. hl];
    final switch (verbOf(verb)) {
        case Verb.connect:
            return connectMain(h[0 .. hl]);
        case Verb.unknown:
            fputs(USAGE.ptr, stderr);
            return 2;
        case Verb.ask:
            // One mycelia asks the node. Another started while it runs is the
            // system opening the door's url, and hands it over.
            auto fd = running(h[0 .. hl]);
            if (fd >= 0) return handOver(fd);
            return myceliaMain(h[0 .. hl], &press, &door);
    }
}

enum USAGE = `usage: mycelia           ask the node, pass after pass
       mycelia connect   sign in at the node with your passkey; the session is kept behind Touch ID
` ~ "\0";
