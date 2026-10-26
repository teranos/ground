module pii_test;

// CTFE tests — failure shows as a compile error. The shapes under test are
// built from parts, so the source of this file carries none of them.

import pii : scrub, scrubField, Scrubbed, Shape, ipStays, said, jsonValue;

static immutable string[3] ALLOWED = ["tim@example.com", "spike@example.com", "jenny@example.com"];

enum AT = "@";
enum GMAIL = "someone" ~ AT ~ "gmail.com";
enum AX = "a" ~ AT ~ "x.nl";
enum BY = "b" ~ AT ~ "y.org";
enum ME = "me" ~ AT ~ "abcd.nl";
enum FAR = "93.184." ~ "216.34";
enum DNS1 = "8.8." ~ "8.8";
enum DNS2 = "1.1." ~ "1.1";
enum MOBILE = "+31 6 " ~ "12345678";
enum MOBILE_NL = "06-" ~ "12345678";
enum LANDLINE = "020 123 " ~ "4567";
enum INTL00 = "0031" ~ "612345678";
enum US = "+1 (415) " ~ "555-0132";
enum POST = "1234" ~ " AB";
enum POST_TIGHT = "1234" ~ "AB";
enum YEAR_POST = "2026" ~ " AD";

char[1024] out_(const(char)[] text)() {
    char[1024] buf = 0;
    scrub(text, buf[], ALLOWED[]);
    return buf;
}

Scrubbed r(const(char)[] text) {
    char[1024] buf = 0;
    return scrub(text, buf[], ALLOWED[]);
}

bool is_(const(char)[] text, const(char)[] want)() {
    enum got = out_!text();
    return got[0 .. want.length] == want && got[want.length] == 0;
}

// A mail address is written as the first allowed one; the rest of the line stands.
static assert(is_!("['—', '" ~ GMAIL ~ "', 'USER']", "['—', 'tim@example.com', 'USER']"));
static assert(r(GMAIL).count[Shape.mail] == 1);

// Two different addresses are two different fixtures; the same one twice is the same.
static assert(is_!(AX ~ " " ~ BY ~ " " ~ AX, "tim@example.com spike@example.com tim@example.com"));
static assert(r(AX ~ " " ~ BY ~ " " ~ AX).count[Shape.mail] == 3);

// An allowed address is written as it is, and takes no number.
static assert(is_!("spike@example.com then " ~ AX, "spike@example.com then tim@example.com"));

// A second pass over the result changes nothing.
static assert(r("tim@example.com spike@example.com 192.0.2.1 +000 0000 0001 0000 AA").found == 0);

// A dot closing the sentence is not part of the address.
static assert(is_!("mail " ~ ME ~ ".", "mail tim@example.com."));

// Not an address: no dot in the domain, a handle, a scoped package, a decorator, a host with a path.
static assert(r("ssh kapteyn" ~ AT ~ "kapteyn").found == 0);
static assert(r(AT ~ "teranos/elements").found == 0);
static assert(r(AT ~ "media (max-width: 600px)").found == 0);
static assert(r("z6MkAgent" ~ AT ~ "localhost").found == 0);
static assert(r("git clone git" ~ AT ~ "github.com:teranos/QNTX.git").found == 0);
static assert(r("scp a deploy" ~ AT ~ "host.example.com:/srv").found == 0);

// An IPv4 address on the internet becomes a documentation one; one that names no host stays.
static assert(is_!("curl http://203.0.113.9/ and " ~ FAR, "curl http://203.0.113.9/ and 192.0.2.1"));
static assert(is_!("127.0.0.1 10.0.0.5 192.168.1.1 0.0.0.0", "127.0.0.1 10.0.0.5 192.168.1.1 0.0.0.0"));
static assert(ipStays("172.16.0.1") && !ipStays("172.32.0.1"));
static assert(is_!(DNS1 ~ " and " ~ DNS2 ~ " and " ~ DNS1, "192.0.2.1 and 192.0.2.2 and 192.0.2.1"));

// A version is not an address: three groups, a fifth one, an octet past 255.
static assert(r("version 1.29.0").found == 0);
static assert(r("2.11.4.1.0").found == 0);
static assert(r("256.1.1.1").found == 0);

// A phone number, written as people write them, becomes one no network assigns.
static assert(is_!("bel " ~ MOBILE, "bel +000 0000 0001"));
static assert(is_!(MOBILE_NL ~ " of " ~ LANDLINE, "+000 0000 0001 of +000 0000 0002"));
static assert(is_!(INTL00, "+000 0000 0001"));
static assert(is_!(US, "+000 0000 0001"));

// Not a phone: a timestamp, an id, a short number, a hash.
static assert(r("2026-10-08 21:41:54").found == 0);
static assert(r("0100019a-ses").found == 0);
static assert(r("0612345").found == 0);
static assert(r("0dcb90b4").found == 0);
static assert(r("+1").found == 0);

// A Dutch postal code becomes one that is not one.
static assert(is_!(POST ~ " Amsterdam", "0000 AA Amsterdam"));
static assert(is_!(POST_TIGHT, "0000 AA"));
static assert(r("AS-" ~ POST).found == 1);
static assert(r("a" ~ POST).found == 0);
static assert(r(YEAR_POST).count[Shape.postcode] == 1);

// A Dutch street with its house number becomes the example street; the second street is number two.
enum KERK = "Kerk" ~ "straat 12";
enum PRINSEN = "Prinsen" ~ "gracht 263";
static assert(is_!(KERK ~ ", " ~ POST ~ " Amsterdam", "Voorbeeldstraat 1, 0000 AA Amsterdam"));
static assert(is_!(KERK ~ " en " ~ PRINSEN ~ " en " ~ KERK, "Voorbeeldstraat 1 en Voorbeeldstraat 2 en Voorbeeldstraat 1"));
static assert(r("Voorbeeldstraat 1").found == 0);

// Not a street: the word alone, a number glued to letters, a word too short to carry a name.
static assert(r("de straat 12").found == 0);
static assert(r("Kerk" ~ "straat12a").found == 0);
static assert(r("onderweg naar 3").found == 0);

// Everything else is bytes in, bytes out.
static assert(is_!("", ""));
static assert(is_!("plain text, no shapes", "plain text, no shapes"));
static assert(is_!("{\"a\":1}", "{\"a\":1}"));

// Too small is no answer.
Scrubbed tight(const(char)[] text, size_t room) {
    char[64] buf = 0;
    return scrub(text, buf[0 .. room], ALLOWED[]);
}
static assert(!tight(AX, 4).fit);
static assert(tight(AX, 4).len == 0);

// A field is scrubbed and the object around it is not.
char[512] field(const(char)[] region, const(char)[] key)() {
    char[512] buf = 0;
    scrubField(region, key, buf[], ALLOWED[]);
    return buf;
}
enum AB = "a" ~ AT ~ "b.cc";
enum write = `{"file_path":"/x/` ~ AB ~ `/t.ts","content":"to: ` ~ AB ~ `"}`;
enum writeWant = `{"file_path":"/x/` ~ AB ~ `/t.ts","content":"to: tim@example.com"}`;
static assert(field!(write, "content")()[0 .. writeWant.length] == writeWant);
static assert(field!(write, "nope")()[0 .. write.length] == write);

// A value is taken whole, brackets and quotes balanced, and nothing after it.
static assert(jsonValue(`{"a":{"b":[1,2]},"c":"}"} ,"next":1`) == `{"a":{"b":[1,2]},"c":"}"}`);
static assert(jsonValue(`[{"type":"text","text":"` ~ AX ~ `"}],"z":2`) == `[{"type":"text","text":"` ~ AX ~ `"}]`);
static assert(jsonValue(`"a \"quoted\" string", 1`) == `"a \"quoted\" string"`);
static assert(jsonValue(`{"open":1`) is null);

// What it says.
char[128] saying(const(char)[] text)() {
    char[128] buf = 0;
    auto s = r(text);
    said(s, buf[]);
    return buf;
}
static assert(saying!(AX ~ " " ~ BY ~ " " ~ DNS1)()[0 .. 30] == "2 mail addresses, 1 IP address");
