module qntx;

// The QNTX row. State model read from collet's QntxState and qntx_info.

// Every state is a claim about what this process measured from this host, and
// none of them is a claim that QNTX is down.

enum GREEN  = "\033[32m";
enum YELLOW = "\033[33m";
enum RED    = "\033[31m";
enum CYAN   = "\033[36m";
enum DIM    = "\033[2m";
enum RESET  = "\033[0m";

enum State {
    ok,
    noToken,
    tokenUnreadable,
    unauthed,
    clientError,
    oddStatus,
    serverError,
    malformedBody,
    dnsFailure,
    refused,
    timeout,
    tlsFailure,
    probeError,
}

// curl's own exit codes, read from `man curl` on this machine, curl 8.7.1.
enum CURL_OK      = 0;
enum CURL_DNS     = 6;   // could not resolve host
enum CURL_CONNECT = 7;   // failed to connect to host
enum CURL_TIMEOUT = 28;  // operation timeout
enum CURL_SSL     = 35;  // SSL connect error, handshaking failed
enum CURL_CACERT  = 60;  // peer certificate cannot be authenticated

// What the probe measured, transport first, so each answer names the step
// that failed.
State classify(int curlExit, int httpStatus) {
    switch (curlExit) {
        case CURL_DNS:     return State.dnsFailure;
        case CURL_CONNECT: return State.refused;
        case CURL_TIMEOUT: return State.timeout;
        case CURL_SSL:     return State.tlsFailure;
        case CURL_CACERT:  return State.tlsFailure;
        case CURL_OK:      break;
        default:           return State.probeError;
    }

    if (httpStatus == 200) return State.ok;
    if (httpStatus == 401 || httpStatus == 403) return State.unauthed;
    if (httpStatus >= 400 && httpStatus <= 499) return State.clientError;
    if (httpStatus >= 500 && httpStatus <= 599) return State.serverError;

    // No status is not a status outside the ranges: curl exited clean and
    // brought nothing back, which is the probe failing rather than the server
    // answering oddly.
    if (httpStatus == 0) return State.probeError;
    return State.oddStatus;
}

// The word the operator would act on. Success says nothing at all, because the
// absence of the row is what fine looks like.
const(char)[] word(State s) {
    switch (s) {
        case State.ok:              return "";
        case State.noToken:         return "token";
        case State.tokenUnreadable: return "unreadable";
        case State.unauthed:        return "auth";
        case State.malformedBody:   return "parse";
        case State.dnsFailure:      return "dns";
        case State.refused:         return "refused";
        case State.timeout:         return "timeout";
        case State.tlsFailure:      return "tls";
        default:                    return "error";
    }
}

// Yellow is ours to fix, red is not.
const(char)[] colourOf(State s) {
    switch (s) {
        case State.noToken:     return YELLOW;
        case State.unauthed:    return YELLOW;
        case State.clientError: return YELLOW;
        case State.oddStatus:   return YELLOW;
        default:                return RED;
    }
}

// A failure line: the name of the thing, then the one word.
size_t failureInto(State s, int status, char[] dest) {
    if (s == State.ok) return 0;

    size_t o = 0;

    void put(const(char)[] t) {
        foreach (c; t) if (o < dest.length) dest[o++] = c;
    }

    put(colourOf(s));
    put("QNTX ");

    // A status the server chose is more use than a word we chose for it.
    if (s == State.clientError || s == State.oddStatus || s == State.serverError) {
        if (status >= 100) { if (o < dest.length) dest[o++] = cast(char)('0' + (status / 100) % 10); }
        if (status >= 10)  { if (o < dest.length) dest[o++] = cast(char)('0' + (status / 10) % 10); }
        if (o < dest.length) dest[o++] = cast(char)('0' + status % 10);
    } else {
        put(word(s));
    }

    put(RESET);
    return o;
}

// One plugin, as the row cares about it.
struct Plugin {
    const(char)[] name;
    const(char)[] version_;
    bool healthy;
}

// Running and healthy is the only healthy. A plugin that reports healthy while
// stopped is not doing anything.
bool isHealthy(bool healthy, const(char)[] state) {
    return healthy && state == "running";
}

// The next object of the plugins array at or after `from`, by brace depth, so
// a nested object does not end the one holding it.
struct Span {
    bool ok;
    size_t start;
    size_t end;
}

// Where a literal sits, or the length when it is not there.
ptrdiff_t indexOf(const(char)[] text, const(char)[] needle) {
    if (needle.length == 0 || needle.length > text.length) return -1;
    foreach (i; 0 .. text.length - needle.length + 1)
        if (text[i .. i + needle.length] == needle) return cast(ptrdiff_t) i;
    return -1;
}

// Where the plugin array starts. Measured against the live endpoint: the body
// carries health_age_ms and health_probed_at before it.
size_t pluginsAt(const(char)[] body_) {
    import json : jsonString;

    auto at = indexOf(body_, `"plugins":`);
    return at < 0 ? body_.length : cast(size_t) at + 10;
}

// A JSON true, for the one boolean the row reads.
bool jsonTrue(const(char)[] object, const(char)[] key) {

    char[32] needle = 0;
    if (key.length + 3 > needle.length) return false;
    size_t n = 0;
    needle[n++] = '"';
    foreach (c; key) needle[n++] = c;
    needle[n++] = '"';
    needle[n++] = ':';

    auto at = indexOf(object, needle[0 .. n]);
    if (at < 0) return false;

    size_t i = cast(size_t) at + n;
    while (i < object.length && object[i] == ' ') i++;
    return i + 4 <= object.length && object[i .. i + 4] == "true";
}

// The plugin list: unhealthy first, because a plugin that is down is the only
// one worth reading. Nothing at all when there are none.
size_t pluginsInto(const(char)[] body_, char[] dest) {
    import json : jsonString;

    size_t o = 0;

    void put(const(char)[] t) {
        foreach (c; t) if (o < dest.length) dest[o++] = c;
    }

    bool first = true;

    void one(const(char)[] obj, bool wantHealthy) {
        auto healthy = isHealthy(jsonTrue(obj, "healthy"), jsonString(obj, "state"));
        if (healthy != wantHealthy) return;

        auto name = jsonString(obj, "name");
        if (name is null) return;

        if (!first) put("  ");
        first = false;

        put(healthy ? GREEN : RED);
        put(name);
        put(RESET);

        auto v = jsonString(obj, "version");
        if (v !is null && v.length > 0) {
            put(" ");
            put(DIM);
            put(v);
            put(RESET);
        }
    }

    // Two passes rather than a sort: the order is unhealthy then healthy, and
    // nothing else about it matters.
    foreach (wantHealthy; [false, true]) {
        size_t at = pluginsAt(body_);
        while (true) {
            auto span = nextObject(body_, at);
            if (!span.ok) break;
            one(body_[span.start .. span.end], wantHealthy);
            at = span.end;
        }
    }

    return o;
}

Span nextObject(const(char)[] text, size_t from) {
    size_t i = from;
    while (i < text.length && text[i] != '{') i++;
    if (i >= text.length) return Span(false, text.length, text.length);

    size_t depth = 0;
    size_t start = i;
    while (i < text.length) {
        if (text[i] == '{') depth++;
        else if (text[i] == '}') {
            depth--;
            if (depth == 0) return Span(true, start, i + 1);
        }
        i++;
    }
    return Span(false, text.length, text.length);
}
