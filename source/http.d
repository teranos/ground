module http;

import db : ZBuf;

// Everything over HTTP goes through libcurl, in this process. It was the curl
// program behind a pipe, which cost a fork per request, put the token and the
// body in files under /tmp, and told every failure there is as "0, no answer".
// Written against libcurl 8.18.0, the one flake.lock pins; the numbers below
// are read off its curl.h, not remembered.

extern (C) {
    void* curl_easy_init();
    // Variadic, as curl.h declares it. On arm64 macOS a variadic argument goes
    // on the stack; declared plain, the value lands in a register libcurl
    // never reads.
    int curl_easy_setopt(void* handle, int option, ...);
    int curl_easy_getinfo(void* handle, int info, ...);
    int curl_easy_perform(void* handle);
    void curl_easy_cleanup(void* handle);
    void* curl_slist_append(void* list, const(char)* line);
    void curl_slist_free_all(void* list);
    const(char)* curl_easy_strerror(int code);
}

private enum {
    CURLOPT_WRITEDATA      = 10_001,
    CURLOPT_URL            = 10_002,
    CURLOPT_ERRORBUFFER    = 10_010,
    CURLOPT_WRITEFUNCTION  = 20_011,
    CURLOPT_TIMEOUT        = 13,
    CURLOPT_POSTFIELDS     = 10_015,
    CURLOPT_USERAGENT      = 10_018,
    CURLOPT_HTTPHEADER     = 10_023,
    CURLOPT_POSTFIELDSIZE  = 60,
    CURLOPT_NOSIGNAL       = 99,
    CURLOPT_PROTOCOLS_STR  = 10_318,
    CURLINFO_RESPONSE_CODE = 0x200000 + 2,
    CURL_ERROR_SIZE        = 256,
}

// Strip surrounding whitespace from a credential. A token read from a file
// carries the newline the file ends with, and a newline inside a header value
// is a malformed request, not a bad token.
const(char)[] trimToken(const(char)[] s) {
    size_t b = 0;
    size_t e = s.length;
    static bool ws(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
    while (b < e && ws(s[b])) b++;
    while (e > b && ws(s[e - 1])) e--;
    return s[b .. e];
}

// An absent token is an absent header. Sending `Authorization: Bearer ` with
// nothing after it earns a 401, which reads as "your token was rejected" when
// the truth is there was never a token to send.
void bearerLine(ref ZBuf line, const(char)[] token) {
    line.reset();
    auto tok = trimToken(token);
    if (tok.length == 0) return;
    line.put("Authorization: Bearer ");
    line.put(tok);
}

// What a request came to. A status is what the far end said; a code is what
// libcurl said about getting there, and `why` is that in its own words.
struct Http {
    int status;   // the HTTP status, 0 when nothing answered
    int code;     // libcurl's CURLcode, 0 when the transfer completed
    size_t len;   // body bytes in the caller's buffer
    // The body was larger than the buffer it was read into. Not a failure of
    // the far end and not a failure to reach it, so it is neither of those.
    bool overran;
    char[CURL_ERROR_SIZE] whyBuf = 0;
    size_t whyLen;
    const(char)[] why() const return { return whyBuf[0 .. whyLen]; }
}

private struct Sink {
    char[] dest;
    size_t len;
    bool overran;
}

// libcurl hands the body over in pieces. A piece that does not fit ends the
// transfer: a body cut short is not the answer, so none of it is kept.
private extern (C) size_t intoSink(char* ptr, size_t size, size_t nmemb, void* user) {
    auto sink = cast(Sink*) user;
    auto n = size * nmemb;
    if (sink.dest.length == 0) return n;   // a POST's reply is not wanted
    if (sink.len + n > sink.dest.length) {
        sink.overran = true;
        return 0;
    }
    foreach (i; 0 .. n) sink.dest[sink.len + i] = ptr[i];
    sink.len += n;
    return n;
}

// One request. `body_` null is a GET. `protocols` is what the url may speak:
// a caller that did not ask for files cannot be handed one by a url.
private Http perform(const(char)[] url, const(char)[] body_, bool isPost,
                     const(char)[] token, const(char)[] contentType,
                     char[] dest, int timeoutSec, const(char)[] protocols) {
    Http r;

    void say(const(char)[] s) {
        r.whyLen = 0;
        foreach (c; s) if (r.whyLen < r.whyBuf.length) r.whyBuf[r.whyLen++] = c;
    }

    // libcurl reads C strings, and a slice carries no terminator.
    __gshared ZBuf urlZ, protoZ, authZ, typeZ;
    if (url.length + 1 >= urlZ.data.length) {
        r.code = -1;
        say("the url is longer than ground can hand to libcurl");
        return r;
    }
    urlZ.reset();
    urlZ.put(url);
    protoZ.reset();
    protoZ.put(protocols);

    auto h = curl_easy_init();
    if (h is null) {
        r.code = -1;
        say("libcurl could not start a handle");
        return r;
    }
    scope (exit) curl_easy_cleanup(h);

    void* headers = null;
    scope (exit) if (headers !is null) curl_slist_free_all(headers);

    bearerLine(authZ, token);
    if (authZ.len > 0) headers = curl_slist_append(headers, authZ.ptr());
    if (isPost && contentType.length > 0) {
        typeZ.reset();
        typeZ.put("Content-Type: ");
        typeZ.put(contentType);
        headers = curl_slist_append(headers, typeZ.ptr());
    }

    Sink sink;
    sink.dest = dest;
    char[CURL_ERROR_SIZE] errBuf = 0;

    curl_easy_setopt(h, CURLOPT_URL, urlZ.ptr());
    curl_easy_setopt(h, CURLOPT_PROTOCOLS_STR, protoZ.ptr());
    curl_easy_setopt(h, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(h, CURLOPT_TIMEOUT, cast(long) timeoutSec);
    curl_easy_setopt(h, CURLOPT_ERRORBUFFER, &errBuf[0]);
    // GitHub refuses a request that names no agent, and the curl program
    // named itself without being asked.
    curl_easy_setopt(h, CURLOPT_USERAGENT, "ground\0".ptr);
    curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, &intoSink);
    curl_easy_setopt(h, CURLOPT_WRITEDATA, &sink);
    if (headers !is null) curl_easy_setopt(h, CURLOPT_HTTPHEADER, headers);
    if (isPost) {
        // The size goes first: without it libcurl measures the body with
        // strlen, and a slice carries no terminator to stop at.
        curl_easy_setopt(h, CURLOPT_POSTFIELDSIZE, cast(long) body_.length);
        curl_easy_setopt(h, CURLOPT_POSTFIELDS, body_.ptr);
    }

    r.code = curl_easy_perform(h);

    long status = 0;
    curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &status);
    r.status = cast(int) status;

    if (sink.overran) {
        r.overran = true;
        r.len = 0;
        say("the answer was larger than the buffer ground read it into");
        return r;
    }
    r.len = sink.len;

    if (r.code != 0) {
        // The buffer holds the specific account when libcurl wrote one, and
        // strerror the general one when it did not.
        size_t n = 0;
        while (n < errBuf.length && errBuf[n] != 0) n++;
        if (n > 0) say(errBuf[0 .. n]);
        else {
            auto s = curl_easy_strerror(r.code);
            size_t m = 0;
            while (s !is null && s[m] != 0) m++;
            if (m > 0) say(s[0 .. m]);
        }
    }
    return r;
}

private enum WEB = "https,http";

// GET a url, the body into dest.
Http httpGet(const(char)[] url, const(char)[] token, char[] dest, int timeoutSec = 10) {
    return perform(url, null, false, token, null, dest, timeoutSec, WEB);
}

// The same, for a caller that names what the url may speak.
Http httpFetch(const(char)[] url, const(char)[] token, char[] dest, int timeoutSec,
               const(char)[] protocols) {
    return perform(url, null, false, token, null, dest, timeoutSec, protocols);
}

// POST a body to a url. The reply's body is not kept.
Http httpPost(const(char)[] url, const(char)[] body_, const(char)[] token,
              int timeoutSec = 10, const(char)[] contentType = "application/json") {
    return perform(url, body_, true, token, contentType, null, timeoutSec, WEB);
}

// The HTTP status, or 0 when there was none. For a caller that reads only the
// status; one that owes somebody the reason asks httpPost.
int curlPost(const(char)[] url, const(char)[] body_, const(char)[] token,
             int timeoutSec = 10, const(char)[] contentType = "application/json") {
    return httpPost(url, body_, token, timeoutSec, contentType).status;
}

// The length written, or 0 when nothing arrived or it did not fit: a body cut
// short is not the answer either.
size_t curlGet(const(char)[] url, const(char)[] token, char[] dest, int timeoutSec = 10) {
    auto r = httpGet(url, token, dest, timeoutSec);
    if (r.code != 0 || r.overran) return 0;
    return r.len;
}

// --- Tests ---

unittest {
    // A request that failed says why in libcurl's own words and under its own
    // code. "0, no answer" was every failure there is, told as one.
    char[64] dest = 0;
    auto r = httpGet("http://127.0.0.1:1/", null, dest[], 5);
    assert(r.status == 0, "nothing answered, so there is no status");
    assert(r.code == 7, "CURLE_COULDNT_CONNECT, as libcurl numbers it");
    assert(r.why().length > 0, "and it says so in words");
    assert(!r.overran);
}

unittest {
    // The body arrives in the caller's buffer, whole.
    import errors : open, write, close, unlink, O_WRONLY, O_CREAT, O_TRUNC;
    enum path = "/tmp/ground-http-body-test\0";
    auto fd = open(path.ptr, O_WRONLY | O_CREAT | O_TRUNC, cast(uint) 0x1A4);
    assert(fd >= 0);
    write(fd, "hello".ptr, 5);
    close(fd);
    scope (exit) unlink(path.ptr);

    char[64] dest = 0;
    auto r = httpFetch("file:///tmp/ground-http-body-test", null, dest[], 5, "file");
    assert(r.code == 0);
    assert(r.len == 5);
    assert(dest[0 .. r.len] == "hello");
    assert(!r.overran);

    // A body larger than the buffer is its own outcome. Through a pipe it
    // killed the writer, and that read as the tool having failed.
    char[3] small = 0;
    auto cut = httpFetch("file:///tmp/ground-http-body-test", null, small[], 5, "file");
    assert(cut.overran, "the answer did not fit, and that is what is said");
    assert(cut.len == 0, "a body cut short is not the answer");

    // Only what ground speaks. A url that names a file is refused where the
    // caller did not ask for files.
    auto refused = httpGet("file:///tmp/ground-http-body-test", null, dest[], 5);
    assert(refused.code != 0, "file is not a protocol a caller gets by default");
}

unittest {
    // The token is a header and the header is memory: no config file, no body
    // file, nothing on a command line and nothing in /tmp.
    ZBuf line;
    bearerLine(line, "sekrit");
    assert(line.slice() == "Authorization: Bearer sekrit");

    // An absent token is an absent header. An empty Bearer earns a 401 that
    // reads as a rejected token when there was never one to reject.
    bearerLine(line, null);
    assert(line.len == 0);
    bearerLine(line, "  \n");
    assert(line.len == 0, "whitespace is not a credential");
    bearerLine(line, "sekrit\n");
    assert(line.slice() == "Authorization: Bearer sekrit", "a trailing newline is not part of it");
}

unittest {
    // trimToken: surrounding whitespace and a trailing newline are not
    // part of the credential. A file written by `echo` has one.
    assert(trimToken("abc") == "abc");
    assert(trimToken("abc\n") == "abc");
    assert(trimToken("  abc\r\n") == "abc");
    assert(trimToken("\n\n") == "");
    assert(trimToken("") == "");
    assert(trimToken("   ") == "");
}
