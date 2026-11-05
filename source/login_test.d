module login_test;

// 「[Opus 5.5] ground code's sign-in to its QNTX node, against a node that answers as」
// 「[Opus 5.5] QNTX's server/auth/device.go does: /auth/device starts it, /auth/token says」
// 「[Opus 5.5] authorization_pending until the person says yes at the passkey, then gives」
// 「[Opus 5.5] the token, once.」

import code.login;
import code.reply : Reply;

version (Posix):

import core.sys.posix.unistd : pipe, write, close, fork, _exit, read;
import core.sys.posix.sys.socket : socket, bind, listen, accept, getsockname, sockaddr, socklen_t, AF_INET, SOCK_STREAM;
import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
import core.sys.posix.sys.wait : waitpid;
import matcher : indexOf;

// 「[Opus 5.5] A node that answers each request in turn with the next of answers, and」
// 「[Opus 5.5] writes each request it was sent, a NUL after it, into heard.」
private struct Node {
    int pid;
    int heard;
    char[32] urlBuf;
    size_t urlLen;
    const(char)[] url() return { return urlBuf[0 .. urlLen]; }
}

// 「[Opus 5.5] A line the client writes to ground code's input while the node's last request is in flight.」
private __gshared int meanwhileFd = -1;
private __gshared string meanwhile;

private Node node(string[] answers...) {
    Node n;
    auto fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(fd, cast(sockaddr*) &a, a.sizeof) == 0 && listen(fd, 8) == 0);
    socklen_t len = a.sizeof;
    assert(getsockname(fd, cast(sockaddr*) &a, &len) == 0);
    int[2] p;
    assert(pipe(p) == 0);
    auto child = fork();
    if (child == 0) {
        // 「[Opus 5.5] A test that failed before it heard the node leaves it waiting on a」
        // 「[Opus 5.5] request that never comes; it ends on its own rather than holding」
        // 「[Opus 5.5] the test's output open.」
        import core.sys.posix.unistd : alarm;
        alarm(30);
        close(p[0]);
        foreach (answer; answers) {
            auto c = accept(fd, null, null);
            char[8192] got;
            size_t have = 0;
            // 「[Opus 5.5] The head, then as much body as it says.」
            while (have < got.length) {
                auto r = read(c, got.ptr + have, got.length - have);
                if (r <= 0) break;
                have += cast(size_t) r;
                auto head = indexOf(got[0 .. have], "\r\n\r\n");
                if (head < 0) continue;
                auto cl = indexOf(got[0 .. have], "Content-Length: ");
                size_t body_ = 0;
                if (cl >= 0) for (size_t i = cast(size_t) cl + 16; i < have && got[i] >= '0' && got[i] <= '9'; i++) body_ = body_ * 10 + (got[i] - '0');
                if (have >= cast(size_t) head + 4 + body_) break;
            }
            write(p[1], got.ptr, have);
            write(p[1], "\0".ptr, 1);
            // 「[Opus 5.5] What the client says while this request is in flight, before it is answered.」
            if (answer is answers[$ - 1] && meanwhileFd >= 0)
                write(meanwhileFd, meanwhile.ptr, meanwhile.length);
            write(c, answer.ptr, answer.length);
            close(c);
        }
        _exit(0);
    }
    close(fd);
    close(p[1]);
    n.pid = child;
    n.heard = p[0];
    ushort port = htons(a.sin_port);
    foreach (ch; "http://127.0.0.1:") n.urlBuf[n.urlLen++] = ch;
    char[8] d; size_t k = 0;
    do { d[k++] = cast(char)('0' + port % 10); port /= 10; } while (port);
    while (k) n.urlBuf[n.urlLen++] = d[--k];
    return n;
}

// 「[Opus 5.5] Every request the node was sent. What it still waits to be asked never」
// 「[Opus 5.5] comes once the calls are over, so it is stopped first: a request ground」
// 「[Opus 5.5] code did not make fails the test rather than hanging it.」
private const(char)[] heardAll(ref Node n) {
    import core.sys.posix.signal : kill, SIGKILL;
    kill(n.pid, SIGKILL);
    waitpid(n.pid, null, 0);
    __gshared char[65536] all;
    size_t len = 0;
    while (true) {
        auto r = read(n.heard, all.ptr + len, all.length - len);
        if (r <= 0) break;
        len += cast(size_t) r;
    }
    close(n.heard);
    return all[0 .. len];
}

private string digits()(size_t n) {
    string s;
    do { s = cast(char)('0' + n % 10) ~ s; n /= 10; } while (n);
    return s;
}

private enum http(string status, string body_) = "HTTP/1.1 " ~ status ~ "\r\nContent-Type: application/json\r\nContent-Length: "
    ~ digits(body_.length) ~ "\r\nConnection: close\r\n\r\n" ~ body_;

enum DEVICE = http!("200 OK", `{"device_code":"dc 1+","user_code":"BCDF-GHJK","verification_uri":"http://q/auth/device/approve",`
    ~ `"verification_uri_complete":"http://q/auth/device/approve?user_code=BCDF-GHJK","expires_in":600,"interval":0}`);
enum PENDING = http!("400 Bad Request", `{"error":"authorization_pending","error_description":"waiting for the passkey at http://q/auth/device/approve"}`);
enum SLOW = http!("400 Bad Request", `{"error":"slow_down","error_description":"ask less often"}`);
enum TOKEN = http!("200 OK", `{"access_token":"qntx_abc123","token_type":"Bearer","expires_in":2592000}`);
enum EXPIRED = http!("400 Bad Request", `{"error":"expired_token","error_description":"nobody said yes within 10m0s"}`);

// "label names the agent asking, which the person reads before saying yes":
// 「[Opus 5.5] the sign-in is asked for as ground code, a form, and what the node answers」
// 「[Opus 5.5] is read whole.」
unittest {
    auto n = node(DEVICE);
    SignIn s;
    Reply why;
    scope(exit) { s.dispose(); why.dispose(); }
    assert(startSignIn(n.url, s, why) == 1);
    auto heard = heardAll(n);
    assert(indexOf(heard, "POST /auth/device HTTP/1.1") == 0);
    assert(indexOf(heard, "Content-Type: application/x-www-form-urlencoded") >= 0);
    assert(indexOf(heard, "Authorization:") < 0);
    assert(indexOf(heard, "\r\n\r\nlabel=ground+code") >= 0);
    assert(s.deviceCode.slice() == "dc 1+");
    assert(s.userCode.slice() == "BCDF-GHJK");
    assert(s.link.slice() == "http://q/auth/device/approve?user_code=BCDF-GHJK");
    assert(s.interval == 0);
}

// 「[Opus 5.5] What the node refuses with is said as it said it.」
unittest {
    auto n = node(http!("400 Bad Request", `{"error":"label names the agent asking"}`));
    SignIn s;
    Reply why;
    scope(exit) { s.dispose(); why.dispose(); }
    assert(startSignIn(n.url, s, why) == -1);
    heardAll(n);
    assert(indexOf(why.slice(), `"status":400`) >= 0);
    assert(indexOf(why.slice(), `label names the agent asking`) >= 0);
    assert(indexOf(why.slice(), `/auth/device`) >= 0);
}

// 「[Opus 5.5] The token endpoint is asked with RFC 8628's grant and the device code, form」
// 「[Opus 5.5] encoded: waiting while it says authorization_pending, five seconds more」
// 「[Opus 5.5] between asks on slow_down, then the token; and over on expired_token, the」
// 「[Opus 5.5] node's words kept.」
unittest {
    auto n = node(PENDING, SLOW, TOKEN);
    SignIn s;
    s.deviceCode.add("dc 1+");
    Reply token, why;
    scope(exit) { s.dispose(); token.dispose(); why.dispose(); }
    assert(pollSignIn(n.url, s, token, why) == 0);
    assert(pollSignIn(n.url, s, token, why) == 0);
    assert(s.interval == 5);
    assert(pollSignIn(n.url, s, token, why) == 1);
    assert(token.slice() == "qntx_abc123");
    auto heard = heardAll(n);
    assert(indexOf(heard, "POST /auth/token HTTP/1.1") == 0);
    assert(indexOf(heard, "\r\n\r\ngrant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&device_code=dc+1%2B") >= 0);

    auto m = node(EXPIRED);
    Reply none, over;
    scope(exit) { none.dispose(); over.dispose(); }
    assert(pollSignIn(m.url, s, none, over) == -1);
    heardAll(m);
    assert(none.len == 0);
    assert(indexOf(over.slice(), `expired_token`) >= 0 && indexOf(over.slice(), `nobody said yes within 10m0s`) >= 0);
}

// 「[Opus 5.5] The token is kept where every ground reads it: its directory made, the file」
// 「[Opus 5.5] only its owner's, replaced whole; and dropped again, a file that is not」
// 「[Opus 5.5] there being nothing to drop.」
unittest {
    import core.sys.posix.sys.stat : stat_t, stat, S_IFMT, S_IFDIR;
    import core.sys.posix.unistd : getpid;
    import core.stdc.stdio : snprintf;
    import attest : qntxToken;
    char[128] dir;
    auto dl = snprintf(dir.ptr, dir.length, "/tmp/ground-login-%d", getpid());
    char[160] file;
    snprintf(file.ptr, file.length, "%s/.qntx/token", dir.ptr);
    Reply why;
    scope(exit) why.dispose();
    assert(keepToken(file.ptr, "qntx_first", why));
    assert(keepToken(file.ptr, "qntx_second", why));
    stat_t st;
    assert(stat(file.ptr, &st) == 0);
    assert((st.st_mode & 0x1ff) == 0x180); // 0600
    char[160] parent;
    snprintf(parent.ptr, parent.length, "%s/.qntx", dir.ptr);
    assert(stat(parent.ptr, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR && (st.st_mode & 0x1ff) == 0x1c0); // 0700
    size_t fl = 0; while (file[fl] != 0) fl++;
    assert(qntxToken(file[0 .. fl]) == "qntx_second");
    assert(dropToken(file.ptr, why) == 1);
    assert(qntxToken(file[0 .. fl]) is null);
    assert(dropToken(file.ptr, why) == 0);
    import core.sys.posix.unistd : rmdir;
    rmdir(parent.ptr);
    rmdir(dir.ptr);
    cast(void) dl;
}

// 「[Opus 5.5] `ground code login`: the link and the code said, the node asked until the」
// 「[Opus 5.5] person said yes, and the token kept; exit 0. A sign-in nobody said yes to」
// 「[Opus 5.5] is said as the node said it; exit 1 and nothing kept.」
unittest {
    import core.sys.posix.unistd : getpid, unlink, rmdir;
    import core.stdc.stdio : snprintf;
    import attest : qntxToken;
    char[160] file;
    snprintf(file.ptr, file.length, "/tmp/ground-login-run-%d", getpid());
    size_t fl = 0; while (file[fl] != 0) fl++;
    Reply said;
    scope(exit) said.dispose();
    void say(const(char)[] s) { said.add(s); }

    auto n = node(DEVICE, PENDING, TOKEN);
    assert(login(n.url, file.ptr, &say) == 0);
    heardAll(n);
    assert(indexOf(said.slice(), "http://q/auth/device/approve?user_code=BCDF-GHJK") >= 0);
    assert(indexOf(said.slice(), "BCDF-GHJK") >= 0);
    assert(qntxToken(file[0 .. fl]) == "qntx_abc123");
    unlink(file.ptr);

    said.len = 0;
    auto m = node(DEVICE, EXPIRED);
    assert(login(m.url, file.ptr, &say) == 1);
    heardAll(m);
    assert(indexOf(said.slice(), "nobody said yes within 10m0s") >= 0);
    assert(qntxToken(file[0 .. fl]) is null);
}

// 「[Opus 5.5] ---- What ground code says of signing in, over ACP. ----」

import code : Sessions, answer, Input;

enum METHODS_BOTH = `[{"id":"qntx","name":"Sign in to QNTX","description":"Open the link ground code gives, and approve it at your QNTX node with your passkey"},`
    ~ `{"type":"terminal","id":"qntx-terminal","name":"Sign in to QNTX in a terminal","description":"Runs ground_code login, which prints the link to approve at your QNTX node with your passkey","args":["login"]}]`;

// 「[Opus 5.5] "Agents MUST advertise this method only when the client enabled its」
// 「[Opus 5.5] terminal authentication capability": the terminal method to a client that」
// 「[Opus 5.5] runs one, the agent method to a client that can send the person to a link,」
// 「[Opus 5.5] and logout to every client.」
unittest {
    Sessions s = Sessions(100, 7); s.initialized = true;
    Reply r;
    scope(exit) r.dispose();
    assert(answer(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"auth":{"terminal":true},"elicitation":{"url":{}}}}}`, r, s));
    assert(indexOf(r.slice(), `"authMethods":` ~ METHODS_BOTH ~ `,"agentInfo"`) >= 0);
    assert(indexOf(r.slice(), `"auth":{"logout":{}}`) >= 0);
    r.len = 0;
    assert(answer(`{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"auth":{"terminal":true}}}}`, r, s));
    assert(indexOf(r.slice(), `"authMethods":[{"type":"terminal","id":"qntx-terminal"`) >= 0);
    assert(indexOf(r.slice(), `{"id":"qntx",`) < 0);
    r.len = 0;
    assert(answer(`{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}`, r, s));
    assert(indexOf(r.slice(), `"authMethods":[]`) >= 0);
}

// 「[Opus 5.5] "The client MUST NOT pass this method to authenticate"; and the agent」
// 「[Opus 5.5] method sends the person to a link, which a client offering no url」
// 「[Opus 5.5] elicitation cannot be asked to.」
unittest {
    Sessions s = Sessions(100, 7); s.initialized = true;
    Reply r;
    scope(exit) r.dispose();
    answer(`{"jsonrpc":"2.0","id":4,"method":"authenticate","params":{"methodId":"qntx-terminal"}}`, r, s);
    assert(r.slice() == `{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"qntx-terminal is a terminal method: the client runs ground_code login itself, and does not pass it to authenticate"}}`);
    r.len = 0;
    answer(`{"jsonrpc":"2.0","id":5,"method":"authenticate","params":{"methodId":"qntx"}}`, r, s);
    assert(r.slice() == `{"jsonrpc":"2.0","id":5,"error":{"code":-32602,"message":"qntx sends the person to their node's link, and the client offers no url elicitation"}}`);
}

// 「[Opus 5.5] A turn's worth of ACP: ground code answers line with the client's answers」
// 「[Opus 5.5] already queued in its input, and what it writes the client is kept.」
private struct Spoken {
    Reply reply;
    char[65536] said = 0;
    size_t saidLen;
    const(char)[] told() return { return said[0 .. saidLen]; }
}

private void speak(ref Sessions s, string line, string queued, ref Spoken out_) {
    import core.sys.posix.unistd : dup, dup2;
    import core.stdc.stdio : fflush, stdout;
    int[2] p;
    assert(pipe(p) == 0);
    write(p[1], queued.ptr, queued.length);
    close(p[1]);
    Input input = Input(p[0]);
    s.input = &input;
    scope(exit) { input.dispose(); close(p[0]); s.input = null; }
    int[2] o;
    assert(pipe(o) == 0);
    fflush(stdout);
    auto saved = dup(1);
    dup2(o[1], 1);
    answer(line, out_.reply, s);
    fflush(stdout); dup2(saved, 1); close(saved); close(o[1]);
    while (true) {
        auto got = read(o[0], out_.said.ptr + out_.saidLen, out_.said.length - out_.saidLen);
        if (got <= 0) break;
        out_.saidLen += cast(size_t) got;
    }
    close(o[0]);
}

private const(char)[] tokenFile(ref char[160] buf, string name) {
    import core.sys.posix.unistd : getpid;
    import core.stdc.stdio : snprintf;
    auto n = snprintf(buf.ptr, buf.length, "/tmp/ground-%s-%d", name.ptr, getpid());
    return buf[0 .. cast(size_t) n];
}

// 「[Opus 5.5] q's token is kept in ~/.qntx/token: a test borrows a home of its own, so nobody's token is touched,」
// 「[Opus 5.5] and gives back the home the tests after it run in, every byte. QNTX_TOKEN, read first, is unset.」
private __gshared char[512] keptHome = 0;
private __gshared size_t keptLen;
private __gshared bool hadHome;
private __gshared char[160] borrowed;

private void borrowHome(string name) {
    import core.stdc.stdlib : getenv;
    import core.sys.posix.stdlib : setenv, unsetenv;
    auto was = getenv("HOME");
    hadHome = was !is null;
    keptLen = 0;
    if (hadHome) while (was[keptLen] != 0 && keptLen + 1 < keptHome.length) { keptHome[keptLen] = was[keptLen]; keptLen++; }
    keptHome[keptLen] = 0;
    tokenFile(borrowed, name);
    setenv("HOME", borrowed.ptr, 1);
    unsetenv("QNTX_TOKEN");
}

private void giveBackHome() {
    import core.sys.posix.stdlib : setenv, unsetenv;
    if (hadHome) setenv("HOME", keptHome.ptr, 1); else unsetenv("HOME");
}

// 「[Opus 5.5] Auth is q's, the block's gateway; its url and token file are k's, the hooks' node, and are left alone.」
enum K_URL = "http://127.0.0.1:9";
enum K_TOKEN = "/tmp/ground-k-token-left-alone";

// 「[Opus 5.5] authenticate qntx: q starts a sign-in, the person is sent to its link by an elicitation tied to the」
// 「[Opus 5.5] authenticate request, q is asked until they said yes, its token is kept in ~/.qntx/token, the」
// 「[Opus 5.5] elicitation is said complete, and authenticate is answered.」
unittest {
    import attest : qntxToken;
    import core.sys.posix.unistd : unlink, access, F_OK;
    auto n = node(DEVICE, PENDING, TOKEN);
    Sessions s = Sessions(100, 7); s.initialized = true;
    s.elicitsUrls = true;
    s.node.gateway = cast(string) n.url;
    s.node.url = K_URL;
    s.node.token = K_TOKEN;
    // 「[Opus 5.5] From no k token, so one an aborted run left cannot stand in for one this run wrote.」
    unlink(K_TOKEN.ptr);
    borrowHome("auth");
    scope(exit) giveBackHome();
    __gshared Spoken spoken;
    speak(s, `{"jsonrpc":"2.0","id":3,"method":"authenticate","params":{"methodId":"qntx"}}`,
        `{"jsonrpc":"2.0","id":"login-1","result":{"action":"accept"}}` ~ "\n", spoken);
    heardAll(n);
    scope(exit) spoken.reply.dispose();
    assert(spoken.reply.slice() == `{"jsonrpc":"2.0","id":3,"result":{}}`);
    assert(spoken.told() ==
          `{"jsonrpc":"2.0","id":"login-1","method":"elicitation/create","params":{"requestId":3,"mode":"url",`
        ~ `"message":"Sign in to QNTX as ground code. The code there is BCDF-GHJK.","elicitationId":"qntx-BCDF-GHJK",`
        ~ `"url":"http://q/auth/device/approve?user_code=BCDF-GHJK"}}` ~ "\n"
        ~ `{"jsonrpc":"2.0","method":"elicitation/complete","params":{"elicitationId":"qntx-BCDF-GHJK"}}` ~ "\n");
    assert(qntxToken("") == "qntx_abc123");
    assert(access(K_TOKEN.ptr, F_OK) != 0);
    char[200] kept;
    import core.stdc.stdio : snprintf;
    snprintf(kept.ptr, kept.length, "%s/.qntx/token", borrowed.ptr);
    unlink(kept.ptr);
}

// 「[Opus 5.5] The person declines, the client calls authenticate off, or nobody says yes:」
// 「[Opus 5.5] each is said to the client as it happened, and nothing is kept.」
unittest {
    import attest : qntxToken;
    Sessions s = Sessions(100, 7); s.initialized = true;
    s.elicitsUrls = true;
    s.node.url = K_URL;
    s.node.token = K_TOKEN;
    borrowHome("auth-no");
    scope(exit) giveBackHome();

    auto n = node(DEVICE);
    s.node.gateway = cast(string) n.url;
    __gshared Spoken declined;
    speak(s, `{"jsonrpc":"2.0","id":4,"method":"authenticate","params":{"methodId":"qntx"}}`,
        `{"jsonrpc":"2.0","id":"login-1","result":{"action":"decline"}}` ~ "\n", declined);
    heardAll(n);
    assert(declined.reply.slice() == `{"jsonrpc":"2.0","id":4,"error":{"code":-32000,"message":"the person did not sign in to QNTX","data":{"action":"decline"}}}`);
    declined.reply.dispose();

    auto m = node(DEVICE, PENDING);
    s.node.gateway = cast(string) m.url;
    __gshared Spoken called;
    speak(s, `{"jsonrpc":"2.0","id":5,"method":"authenticate","params":{"methodId":"qntx"}}`,
        `{"jsonrpc":"2.0","id":"login-2","result":{"action":"accept"}}` ~ "\n"
        ~ `{"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":5}}` ~ "\n", called);
    heardAll(m);
    assert(called.reply.slice() == `{"jsonrpc":"2.0","id":5,"error":{"code":-32800,"message":"the client cancelled the sign-in"}}`);
    called.reply.dispose();

    auto o = node(DEVICE, EXPIRED);
    s.node.gateway = cast(string) o.url;
    __gshared Spoken over;
    speak(s, `{"jsonrpc":"2.0","id":6,"method":"authenticate","params":{"methodId":"qntx"}}`,
        `{"jsonrpc":"2.0","id":"login-3","result":{"action":"accept"}}` ~ "\n", over);
    heardAll(o);
    assert(indexOf(over.reply.slice(), `{"jsonrpc":"2.0","id":6,"error":{"code":-32000,"message":"the node did not sign ground code in","data":{"url":"`) == 0);
    assert(indexOf(over.reply.slice(), `nobody said yes within 10m0s`) >= 0);
    over.reply.dispose();
    assert(qntxToken("") is null);
}

// 「[Opus 5.5] logout drops q's token, the one ground code signed in with; k's is left alone:」
// "Terminates the current authenticated session."
// 「[Opus 5.5] A second logout has nothing left to drop, and one QNTX_TOKEN gives, read before the file, it cannot end.」
unittest {
    import attest : qntxToken, qntxTokenFile;
    import core.sys.posix.stdlib : setenv, unsetenv;
    import core.stdc.stdlib : getenv;
    import core.stdc.string : strlen;
    import core.sys.posix.unistd : unlink;
    auto wasHome = getenv("HOME");
    size_t wasLen = wasHome is null ? 0 : strlen(wasHome);
    borrowHome("logout");
    Reply why;
    scope(exit) why.dispose();
    assert(keepToken(qntxTokenFile(""), "qntx_abc123", why));
    assert(keepToken(K_TOKEN.ptr, "qntx_k", why));
    scope(exit) unlink(K_TOKEN.ptr);
    Sessions s = Sessions(100, 7); s.initialized = true;
    s.node.token = K_TOKEN;
    Reply r;
    scope(exit) r.dispose();
    {
        scope(exit) giveBackHome();
        answer(`{"jsonrpc":"2.0","id":7,"method":"logout","params":{}}`, r, s);
        assert(r.slice() == `{"jsonrpc":"2.0","id":7,"result":{}}`);
        assert(qntxToken("") is null);
        assert(qntxToken(K_TOKEN) == "qntx_k");
        r.len = 0;
        answer(`{"jsonrpc":"2.0","id":8,"method":"logout"}`, r, s);
        assert(r.slice() == `{"jsonrpc":"2.0","id":8,"result":{}}`);

        setenv("QNTX_TOKEN", "qntx_env", 1);
        scope(exit) unsetenv("QNTX_TOKEN");
        r.len = 0;
        answer(`{"jsonrpc":"2.0","id":9,"method":"logout","params":{}}`, r, s);
        assert(r.slice() == `{"jsonrpc":"2.0","id":9,"error":{"code":-32603,"message":"QNTX_TOKEN in ground code's environment is read before the token file, and logout cannot drop it"}}`);
    }
    // 「[Opus 5.5] The home the tests after this one run in is the one they were given, every byte.」
    auto isHome = getenv("HOME");
    assert((wasHome is null) == (isHome is null));
    if (isHome !is null) assert(strlen(isHome) == wasLen && isHome[0 .. wasLen] == keptHome[0 .. wasLen]);
}

// 「[Opus 5.5] A 401 from the node is "Authentication required": its answer is the」
// 「[Opus 5.5] client's, and the client can sign in again.」
unittest {
    enum refused = http!("401 Unauthorized", `{"error":"token expired"}`);
    auto n = node(refused);
    Sessions s = Sessions(100, 7); s.initialized = true; s.clock = 1_700_000_000;
    s.node.url = cast(string) n.url; s.node.model = "m"; s.node.token = "/nonexistent"; s.contextSize = 200_000;
    __gshared Spoken opened, prompted;
    speak(s, `{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, "", opened);
    opened.reply.dispose();
    speak(s, `{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"hi"}]}}`, "", prompted);
    heardAll(n);
    assert(indexOf(prompted.reply.slice(), `{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"the node did not accept ground code's sign-in","data":{"url":"`) == 0);
    assert(indexOf(prompted.reply.slice(), `"status":401`) >= 0);
    assert(indexOf(prompted.reply.slice(), `token expired`) >= 0);
    prompted.reply.dispose();
    if (s.open[0].history !is null) s.open[0].history.dispose();
}

// 「[Opus 5.5] One token: what ground code signed in with, ~/.qntx/token, is what it prompts q with. The block's」
// 「[Opus 5.5] token file is k's, and no prompt carries it.」
unittest {
    import attest : qntxTokenFile;
    import core.sys.posix.unistd : unlink;
    enum refused = http!("401 Unauthorized", `{"error":"token expired"}`);
    auto n = node(refused);
    borrowHome("prompt");
    scope(exit) giveBackHome();
    Reply why;
    scope(exit) why.dispose();
    assert(keepToken(qntxTokenFile(""), "qntx_signed_in", why));
    scope(exit) unlink(qntxTokenFile(""));
    assert(keepToken(K_TOKEN.ptr, "qntx_k", why));
    scope(exit) unlink(K_TOKEN.ptr);
    Sessions s = Sessions(100, 7); s.initialized = true; s.clock = 1_700_000_000;
    s.node.gateway = cast(string) n.url; s.node.url = K_URL; s.node.model = "m"; s.node.token = K_TOKEN; s.contextSize = 200_000;
    __gshared Spoken opened, prompted;
    speak(s, `{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, "", opened);
    opened.reply.dispose();
    speak(s, `{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[{"type":"text","text":"hi"}]}}`, "", prompted);
    auto heard = heardAll(n);
    prompted.reply.dispose();
    if (s.open[0].history !is null) s.open[0].history.dispose();
    assert(indexOf(heard, "Authorization: Bearer qntx_signed_in\r\n") >= 0);
    assert(indexOf(heard, "qntx_k") < 0);
}

// 「[Opus 5.5] A token longer than ground reads back is not kept, and says so: it was kept whole and read back」
// 「[Opus 5.5] cut to 512 bytes, so every later request sent the cut one and was refused. One on disk that is」
// 「[Opus 5.5] longer than ground reads is no token, never the start of one.」
unittest {
    import core.sys.posix.unistd : getpid, unlink, rmdir;
    import core.sys.posix.fcntl : open, O_WRONLY, O_CREAT, O_TRUNC;
    import core.sys.posix.unistd : write, close;
    import core.stdc.stdio : snprintf;
    import attest : qntxToken;
    import token : TOKEN_MAX;
    char[160] file;
    snprintf(file.ptr, file.length, "/tmp/ground-login-long-%d", getpid());
    size_t fl = 0; while (file[fl] != 0) fl++;
    __gshared char[TOKEN_MAX + 1] long_ = 'a';
    Reply why;
    scope(exit) why.dispose();
    assert(!keepToken(file.ptr, long_[], why));
    assert(indexOf(why.slice(), "longer than") >= 0, why.slice());
    assert(qntxToken(file[0 .. fl]) is null);

    // 「[Opus 5.5] At the most ground reads, it is kept and read back whole.」
    why.dispose();
    assert(keepToken(file.ptr, long_[0 .. TOKEN_MAX], why), why.slice());
    assert(qntxToken(file[0 .. fl]) == long_[0 .. TOKEN_MAX]);

    // 「[Opus 5.5] Written longer by something else, it is no token.」
    auto fd = open(file.ptr, O_WRONLY | O_CREAT | O_TRUNC, 0x180);
    assert(fd >= 0);
    assert(write(fd, long_.ptr, long_.length) == long_.length);
    close(fd);
    assert(qntxToken(file[0 .. fl]) is null);
    unlink(file.ptr);
}

// 「[Opus 5.5] A sign-in the client calls off while the node is being asked for the token is called off, and」
// 「[Opus 5.5] keeps nothing, though the node's answer is the token: the cancel was asked before only.」
unittest {
    import attest : qntxToken;
    import core.sys.posix.unistd : dup, dup2;
    import core.stdc.stdio : fflush, stdout;
    Sessions s = Sessions(100, 7); s.initialized = true;
    s.elicitsUrls = true;
    s.node.url = K_URL;
    s.node.token = K_TOKEN;
    borrowHome("auth-late");
    scope(exit) giveBackHome();

    int[2] p;
    assert(pipe(p) == 0);
    meanwhileFd = p[1];
    meanwhile = `{"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":8}}` ~ "\n";
    scope(exit) meanwhileFd = -1;
    auto n = node(DEVICE, TOKEN);
    s.node.gateway = cast(string) n.url;
    enum accepted = `{"jsonrpc":"2.0","id":"login-1","result":{"action":"accept"}}` ~ "\n";
    write(p[1], accepted.ptr, accepted.length);
    close(p[1]);
    Input input = Input(p[0]);
    s.input = &input;
    scope(exit) { input.dispose(); close(p[0]); s.input = null; }
    int[2] o;
    assert(pipe(o) == 0);
    fflush(stdout);
    auto saved = dup(1);
    dup2(o[1], 1);
    Reply reply;
    scope(exit) reply.dispose();
    answer(`{"jsonrpc":"2.0","id":8,"method":"authenticate","params":{"methodId":"qntx"}}`, reply, s);
    fflush(stdout); dup2(saved, 1); close(saved); close(o[1]); close(o[0]);
    heardAll(n);
    assert(reply.slice() == `{"jsonrpc":"2.0","id":8,"error":{"code":-32800,"message":"the client cancelled the sign-in"}}`, reply.slice());
    assert(qntxToken("") is null);
}

// 「[Opus 5.5] The token is written to a file only this sign-in made: one standing at its name beforehand, a」
// 「[Opus 5.5] link another user planted to read what comes, is not written through.」
unittest {
    import core.sys.posix.unistd : getpid, unlink, symlink, read, close;
    import core.sys.posix.fcntl : open, O_RDONLY, O_WRONLY, O_CREAT, O_TRUNC;
    import core.sys.posix.unistd : write;
    import core.stdc.stdio : snprintf;
    import attest : qntxToken;
    char[160] file, temp, victim;
    snprintf(file.ptr, file.length, "/tmp/ground-login-link-%d", getpid());
    snprintf(temp.ptr, temp.length, "/tmp/ground-login-link-%d.login", getpid());
    snprintf(victim.ptr, victim.length, "/tmp/ground-login-victim-%d", getpid());
    auto vf = open(victim.ptr, O_WRONLY | O_CREAT | O_TRUNC, 0x1a4);
    assert(vf >= 0);
    write(vf, "before".ptr, 6);
    close(vf);
    assert(symlink(victim.ptr, temp.ptr) == 0);
    scope(exit) { unlink(file.ptr); unlink(temp.ptr); unlink(victim.ptr); }

    Reply why;
    scope(exit) why.dispose();
    assert(keepToken(file.ptr, "qntx_mine", why), why.slice());
    char[16] got = 0;
    auto rf = open(victim.ptr, O_RDONLY);
    auto n = read(rf, got.ptr, got.length);
    close(rf);
    assert(got[0 .. cast(size_t) n] == "before", got[0 .. cast(size_t) n]);
    size_t fl = 0; while (file[fl] != 0) fl++;
    assert(qntxToken(file[0 .. fl]) == "qntx_mine");
}
