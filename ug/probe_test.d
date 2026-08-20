module probe_test;

// CTFE tests — failure shows as a compile error.

import probe : trimToken, split, Answer;
import qntx : State, CURL_OK, CURL_DNS, CURL_TIMEOUT;

// A file written by echo ends in a newline, and a newline inside a header
// value is a malformed request rather than a bad token.
static assert(trimToken("abc") == "abc");
static assert(trimToken("abc\n") == "abc");
static assert(trimToken("  abc\r\n") == "abc");
static assert(trimToken("\n\n") == "");
static assert(trimToken("") == "");

// The status curl appends is taken off the end, and the body is what is left.
enum ok = `{"plugins":[]}` ~ "\nHTTP 200";
static assert(split(ok, CURL_OK).status == 200);
static assert(split(ok, CURL_OK).state == State.ok);
static assert(split(ok, CURL_OK).body_ == `{"plugins":[]}`);

enum unauth = "\nHTTP 401";
static assert(split(unauth, CURL_OK).status == 401);
static assert(split(unauth, CURL_OK).state == State.unauthed);
static assert(split(unauth, CURL_OK).body_ == "");

// A transport that failed brought no status back, and the exit code is what
// says which step failed.
static assert(split("", CURL_DNS).state == State.dnsFailure);
static assert(split("", CURL_TIMEOUT).state == State.timeout);
static assert(split("", CURL_TIMEOUT).status == 0);

// Output with no marker at all is not a 200 with an odd body: nothing was
// measured, so the exit code decides alone.
static assert(split("garbage", CURL_OK).state == State.probeError);
static assert(split("garbage", CURL_OK).status == 0);
static assert(split("garbage", CURL_OK).body_ == "garbage");

// A message carrying the marker's own text does not end the body early. In
// JSON that text is two characters and not a line break, and the marker is
// found from the end regardless.
enum escaped = `{"m":"\nHTTP 500 in a message"}` ~ "\nHTTP 200";
static assert(split(escaped, CURL_OK).status == 200);
static assert(split(escaped, CURL_OK).body_ == `{"m":"\nHTTP 500 in a message"}`);

// Even a body with a real line break in it, which JSON cannot produce but a
// proxy or an error page can, leaves the trailing marker as the answer.
enum multi = "line one\nHTTP 500 not the marker\nHTTP 200";
static assert(split(multi, CURL_OK).status == 200);
