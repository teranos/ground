module fakenode;

// A node for a test: it answers each request with the next answer it was
// given, and keeps every request it heard. From login_test.d, where ground
// code's sign-in is tested against it; naming_test.d asks it too.

version (Posix):

import core.sys.posix.unistd : pipe, write, close, fork, _exit, read;
import core.sys.posix.sys.socket : socket, bind, listen, accept, getsockname, sockaddr, socklen_t, AF_INET, SOCK_STREAM;
import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
import core.sys.posix.sys.wait : waitpid;
import matcher : indexOf;

// 「[Opus 5.5] A node that answers each request in turn with the next of answers, and」
// 「[Opus 5.5] writes each request it was sent, a NUL after it, into heard.」
struct Node {
    int pid;
    int heard;
    char[32] urlBuf;
    size_t urlLen;
    const(char)[] url() return { return urlBuf[0 .. urlLen]; }
}

// 「[Opus 5.5] A line the client writes to ground code's input while the node's last request is in flight.」
__gshared int meanwhileFd = -1;
__gshared string meanwhile;

Node node(string[] answers...) {
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
const(char)[] heardAll(ref Node n) {
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

string digits()(size_t n) {
    string s;
    do { s = cast(char)('0' + n % 10) ~ s; n /= 10; } while (n);
    return s;
}

enum http(string status, string body_) = "HTTP/1.1 " ~ status ~ "\r\nContent-Type: application/json\r\nContent-Length: "
    ~ digits(body_.length) ~ "\r\nConnection: close\r\n\r\n" ~ body_;
