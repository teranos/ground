module login_test;

// ground code's sign-in to its QNTX node, against a node that answers as
// QNTX's server/auth/device.go does: /auth/device starts it, /auth/token says
// authorization_pending until the person says yes at the passkey, then gives
// the token, once.

import code.login;
import code.reply : Reply;

version (Posix):

import core.sys.posix.unistd : pipe, write, close, fork, _exit, read;
import core.sys.posix.sys.socket : socket, bind, listen, accept, getsockname, sockaddr, socklen_t, AF_INET, SOCK_STREAM;
import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
import core.sys.posix.sys.wait : waitpid;
import matcher : indexOf;

// A node that answers each request in turn with the next of answers, and
// writes each request it was sent, a NUL after it, into heard.
private struct Node {
    int pid;
    int heard;
    char[32] urlBuf;
    size_t urlLen;
    const(char)[] url() return { return urlBuf[0 .. urlLen]; }
}

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
        // A test that failed before it heard the node leaves it waiting on a
        // request that never comes; it ends on its own rather than holding
        // the test's output open.
        import core.sys.posix.unistd : alarm;
        alarm(30);
        close(p[0]);
        foreach (answer; answers) {
            auto c = accept(fd, null, null);
            char[8192] got;
            size_t have = 0;
            // The head, then as much body as it says.
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

// Every request the node was sent. What it still waits to be asked never
// comes once the calls are over, so it is stopped first: a request ground
// code did not make fails the test rather than hanging it.
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
// the sign-in is asked for as ground code, a form, and what the node answers
// is read whole.
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

// What the node refuses with is said as it said it.
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

// The token endpoint is asked with RFC 8628's grant and the device code, form
// encoded: waiting while it says authorization_pending, five seconds more
// between asks on slow_down, then the token; and over on expired_token, the
// node's words kept.
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

// The token is kept where every ground reads it: its directory made, the file
// only its owner's, replaced whole; and dropped again, a file that is not
// there being nothing to drop.
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

// `ground code login`: the link and the code said, the node asked until the
// person said yes, and the token kept; exit 0. A sign-in nobody said yes to
// is said as the node said it; exit 1 and nothing kept.
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

// ---- What ground code says of signing in, over ACP. ----

import code : Sessions, answer, Input;

enum METHODS_BOTH = `[{"id":"qntx","name":"Sign in to QNTX","description":"Open the link ground code gives, and approve it at your QNTX node with your passkey"},`
    ~ `{"type":"terminal","id":"qntx-terminal","name":"Sign in to QNTX in a terminal","description":"Runs ground_code login, which prints the link to approve at your QNTX node with your passkey","args":["login"]}]`;

// "Agents MUST advertise this method only when the client enabled its
// terminal authentication capability": the terminal method to a client that
// runs one, the agent method to a client that can send the person to a link,
// and logout to every client.
unittest {
    Sessions s = Sessions(100, 7);
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

// "The client MUST NOT pass this method to authenticate"; and the agent
// method sends the person to a link, which a client offering no url
// elicitation cannot be asked to.
unittest {
    Sessions s = Sessions(100, 7);
    Reply r;
    scope(exit) r.dispose();
    answer(`{"jsonrpc":"2.0","id":4,"method":"authenticate","params":{"methodId":"qntx-terminal"}}`, r, s);
    assert(r.slice() == `{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"qntx-terminal is a terminal method: the client runs ground_code login itself, and does not pass it to authenticate"}}`);
    r.len = 0;
    answer(`{"jsonrpc":"2.0","id":5,"method":"authenticate","params":{"methodId":"qntx"}}`, r, s);
    assert(r.slice() == `{"jsonrpc":"2.0","id":5,"error":{"code":-32602,"message":"qntx sends the person to their node's link, and the client offers no url elicitation"}}`);
}

// A turn's worth of ACP: ground code answers line with the client's answers
// already queued in its input, and what it writes the client is kept.
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

// q's token is kept in ~/.qntx/token: a test borrows a home of its own, so nobody's token is touched,
// and gives back the home the tests after it run in, every byte. QNTX_TOKEN, read first, is unset.
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

// Auth is q's, the block's gateway; its url and token file are k's, the hooks' node, and are left alone.
enum K_URL = "http://127.0.0.1:9";
enum K_TOKEN = "/tmp/ground-k-token-left-alone";

// authenticate qntx: q starts a sign-in, the person is sent to its link by an elicitation tied to the
// authenticate request, q is asked until they said yes, its token is kept in ~/.qntx/token, the
// elicitation is said complete, and authenticate is answered.
unittest {
    import attest : qntxToken;
    import core.sys.posix.unistd : unlink, access, F_OK;
    auto n = node(DEVICE, PENDING, TOKEN);
    Sessions s = Sessions(100, 7);
    s.elicitsUrls = true;
    s.node.gateway = cast(string) n.url;
    s.node.url = K_URL;
    s.node.token = K_TOKEN;
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

// The person declines, the client calls authenticate off, or nobody says yes:
// each is said to the client as it happened, and nothing is kept.
unittest {
    import attest : qntxToken;
    Sessions s = Sessions(100, 7);
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

// logout drops q's token, the one ground code signed in with; k's is left alone:
// "Terminates the current authenticated session."
// A second logout has nothing left to drop, and one QNTX_TOKEN gives, read before the file, it cannot end.
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
    Sessions s = Sessions(100, 7);
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
    // The home the tests after this one run in is the one they were given, every byte.
    auto isHome = getenv("HOME");
    assert((wasHome is null) == (isHome is null));
    if (isHome !is null) assert(strlen(isHome) == wasLen && isHome[0 .. wasLen] == keptHome[0 .. wasLen]);
}

// A 401 from the node is "Authentication required": its answer is the
// client's, and the client can sign in again.
unittest {
    enum refused = http!("401 Unauthorized", `{"error":"token expired"}`);
    auto n = node(refused);
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
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
