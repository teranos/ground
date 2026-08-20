module qntx_test;

// CTFE tests — failure shows as a compile error.

import qntx : classify, word, colourOf, failureInto, isHealthy, nextObject, State;
import qntx : pluginsAt, pluginsInto, jsonTrue;
import qntx : GREEN, YELLOW, RED, DIM, RESET;
import qntx : CURL_OK, CURL_DNS, CURL_CONNECT, CURL_TIMEOUT, CURL_SSL, CURL_CACERT;

// The transport is measured, not inferred. Each of these is a different fix.
static assert(classify(CURL_DNS, 0) == State.dnsFailure);
static assert(classify(CURL_CONNECT, 0) == State.refused);
static assert(classify(CURL_TIMEOUT, 0) == State.timeout);
static assert(classify(CURL_SSL, 0) == State.tlsFailure);
static assert(classify(CURL_CACERT, 0) == State.tlsFailure);

// A curl that failed for a reason with no word of its own says so, rather
// than being filed under whichever transport failure is nearest.
static assert(classify(63, 0) == State.probeError);

// Past the transport, the status decides.
static assert(classify(CURL_OK, 200) == State.ok);
static assert(classify(CURL_OK, 401) == State.unauthed);
static assert(classify(CURL_OK, 403) == State.unauthed);
static assert(classify(CURL_OK, 404) == State.clientError);
static assert(classify(CURL_OK, 500) == State.serverError);
static assert(classify(CURL_OK, 302) == State.oddStatus);
static assert(classify(CURL_OK, 0) == State.probeError);

// Success says nothing: the absence of the row is what fine looks like.
static assert(word(State.ok).length == 0);

// A token that is not there and a token that would not read are different
// facts with different fixes, so they never share a word.
static assert(word(State.noToken) == "token");
static assert(word(State.tokenUnreadable) == "unreadable");
static assert(colourOf(State.noToken) == YELLOW);
static assert(colourOf(State.tokenUnreadable) == RED);

// Sent and refused is ours to fix; the box breaking is not.
static assert(colourOf(State.unauthed) == YELLOW);
static assert(colourOf(State.serverError) == RED);

// Every state past ok has a word and a colour, so no measurement reaches the
// row with nothing to say.
bool everyStateSpeaks() {
    foreach (s; [State.noToken, State.tokenUnreadable, State.unauthed,
                 State.clientError, State.oddStatus, State.serverError,
                 State.malformedBody, State.dnsFailure, State.refused,
                 State.timeout, State.tlsFailure, State.probeError]) {
        if (word(s).length == 0 || colourOf(s).length == 0) return false;
    }
    return true;
}

static assert(everyStateSpeaks());

char[64] drawn(State s, int status)() {
    char[64] buf = '.';
    failureInto(s, status, buf[]);
    return buf;
}

// A status the server chose beats a word chosen for it.
enum wantAuth = YELLOW ~ "QNTX auth" ~ RESET;
static assert(drawn!(State.unauthed, 401)()[0 .. wantAuth.length] == wantAuth);

enum wantServer = RED ~ "QNTX 503" ~ RESET;
static assert(drawn!(State.serverError, 503)()[0 .. wantServer.length] == wantServer);

enum wantDns = RED ~ "QNTX dns" ~ RESET;
static assert(drawn!(State.dnsFailure, 0)()[0 .. wantDns.length] == wantDns);

// Fine draws nothing at all.
static assert(failureInto(State.ok, 200, new char[64]) == 0);

// Healthy means running as well as saying so.
static assert(isHealthy(true, "running"));
static assert(!isHealthy(true, "stopped"));
static assert(!isHealthy(false, "running"));

// Objects come out one at a time, and a nested one does not end its parent —
// which is what a plugin carrying any object of its own would otherwise do.
enum arr = `[{"name":"copy","meta":{"a":1},"healthy":true},{"name":"duif"}]`;

enum first = nextObject(arr, 0);
static assert(first.ok);
static assert(arr[first.start .. first.end]
              == `{"name":"copy","meta":{"a":1},"healthy":true}`);

enum second = nextObject(arr, first.end);
static assert(second.ok);
static assert(arr[second.start .. second.end] == `{"name":"duif"}`);

enum third = nextObject(arr, second.end);
static assert(!third.ok);

// Scanned from the whole document, the first object found is the document
// itself, so a caller has to enter the array before it iterates.
enum doc = `{"plugins":` ~ arr ~ `}`;
enum whole = nextObject(doc, 0);
static assert(whole.ok);
static assert(doc[whole.start .. whole.end] == doc);

// pluginsAt is what enters the array, and the live body carries two fields
// before it.
static assert(nextObject(doc, pluginsAt(doc)).ok);
static assert(doc[nextObject(doc, pluginsAt(doc)).start .. nextObject(doc, pluginsAt(doc)).end]
              == `{"name":"copy","meta":{"a":1},"healthy":true}`);

static assert(jsonTrue(`{"healthy":true}`, "healthy"));
static assert(!jsonTrue(`{"healthy":false}`, "healthy"));
static assert(!jsonTrue(`{"x":1}`, "healthy"));

// The shape the live endpoint returns, trimmed to the fields the row reads.
enum live = `{"health_age_ms":2556,"plugins":[` ~
    `{"name":"capy","version":"0.244.0","healthy":true,"details":{"capy":"3.13"},"state":"running"},` ~
    `{"name":"duif","version":"0.3.9","healthy":true,"details":{"a":"b"},"state":"running"},` ~
    `{"name":"qntxffmpeg","version":"0.2.4","healthy":true,"details":{"c":"d"},"state":"running"}]}`;

char[512] plugins(const(char)[] b)() {
    char[512] buf = '.';
    pluginsInto(b, buf[]);
    return buf;
}

size_t pluginsLen(const(char)[] b) {
    char[512] buf = '.';
    return pluginsInto(b, buf[]);
}

enum liveWant =
    GREEN ~ "capy" ~ RESET ~ " " ~ DIM ~ "0.244.0" ~ RESET ~ "  " ~
    GREEN ~ "duif" ~ RESET ~ " " ~ DIM ~ "0.3.9" ~ RESET ~ "  " ~
    GREEN ~ "qntxffmpeg" ~ RESET ~ " " ~ DIM ~ "0.2.4" ~ RESET;

static assert(pluginsLen(live) == liveWant.length);
static assert(plugins!live()[0 .. liveWant.length] == liveWant);

// A plugin that is down leads, whatever order the box listed them in, and it
// is red. Reading a healthy list is not the point of the row.
enum mixed = `{"plugins":[` ~
    `{"name":"up","version":"1","healthy":true,"state":"running"},` ~
    `{"name":"down","version":"2","healthy":false,"state":"stopped"}]}`;

enum mixedWant =
    RED ~ "down" ~ RESET ~ " " ~ DIM ~ "2" ~ RESET ~ "  " ~
    GREEN ~ "up" ~ RESET ~ " " ~ DIM ~ "1" ~ RESET;

static assert(plugins!mixed()[0 .. mixedWant.length] == mixedWant);

// Healthy but not running is not healthy, and the row says so in red.
enum paused = `{"plugins":[{"name":"p","version":"1","healthy":true,"state":"paused"}]}`;
enum pausedWant = RED ~ "p" ~ RESET ~ " " ~ DIM ~ "1" ~ RESET;
static assert(plugins!paused()[0 .. pausedWant.length] == pausedWant);

// No plugins is no row: silence is what a healthy box looks like.
static assert(pluginsLen(`{"plugins":[]}`) == 0);
static assert(pluginsLen(`{}`) == 0);
