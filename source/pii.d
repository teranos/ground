module pii;

// A value with the shape of something that names a person is written as a
// fixture instead: a mail address, an IPv4 address, a phone number, a Dutch
// postal code, a Dutch street. A domain name has no shape and stays a list (rewrite:).

enum Shape : ubyte { none, mail, ip, phone, postcode, street }

// What the scrub found, by shape, and where the whole went.
struct Scrubbed {
    size_t len;
    bool fit = true;
    size_t[6] count;   // by Shape
    size_t found() const { return count[1] + count[2] + count[3] + count[4] + count[5]; }
}

// One span the scanner recognised.
struct Span {
    size_t start, end;
    Shape shape;
    bool ok() const { return shape != Shape.none; }
}

private bool digit(char c) { return c >= '0' && c <= '9'; }
private bool alpha(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
private bool alnum(char c) { return digit(c) || alpha(c); }
private bool mailLocal(char c) { return alnum(c) || c == '.' || c == '_' || c == '%' || c == '+' || c == '-'; }
private bool mailDomain(char c) { return alnum(c) || c == '-' || c == '.'; }

// mail: a local part, the at sign, dotted labels, the last of them letters, two or more.
private Span mailAround(const(char)[] t, size_t at) {
    size_t s = at;
    while (s > 0 && mailLocal(t[s - 1])) s--;
    if (s == at) return Span.init;
    size_t e = at + 1;
    while (e < t.length && mailDomain(t[e])) e++;
    // The domain ends on a letter: a closing dot or dash is the sentence's.
    while (e > at + 1 && !alnum(t[e - 1])) e--;
    auto domain = t[at + 1 .. e];
    size_t lastDot = 0;
    bool dotted = false;
    foreach (i, c; domain) if (c == '.') { lastDot = i; dotted = true; }
    if (!dotted || lastDot == 0 || lastDot + 3 > domain.length) return Span.init;
    foreach (c; domain[lastDot + 1 .. $]) if (!alpha(c)) return Span.init;
    if (domain[0] == '.' || domain[0] == '-') return Span.init;
    // user@host:path is a host, the way git and scp name one.
    if (e < t.length && t[e] == ':') return Span.init;
    return Span(s, e, Shape.mail);
}

// ip: four octets, each at most 255, standing alone.
private Span ipAt(const(char)[] t, size_t i) {
    if (i > 0 && (alnum(t[i - 1]) || t[i - 1] == '.')) return Span.init;
    size_t p = i;
    foreach (octet; 0 .. 4) {
        size_t d = p;
        uint v = 0;
        while (d < t.length && d - p < 3 && digit(t[d])) { v = v * 10 + (t[d] - '0'); d++; }
        if (d == p || v > 255) return Span.init;
        p = d;
        if (octet < 3) {
            if (p >= t.length || t[p] != '.') return Span.init;
            p++;
        }
    }
    if (p < t.length && (alnum(t[p]) || t[p] == '.')) return Span.init;
    return Span(i, p, Shape.ip);
}

private uint octetOf(const(char)[] ip, size_t which) {
    uint v = 0;
    size_t seen = 0;
    foreach (c; ip) {
        if (c == '.') { if (seen == which) return v; seen++; v = 0; continue; }
        v = v * 10 + (c - '0');
    }
    return v;
}

// Addresses that name no host on the internet: loopback, private, link-local,
// the documentation nets, unspecified and broadcast. Written as they are.
bool ipStays(const(char)[] ip) {
    auto a = octetOf(ip, 0), b = octetOf(ip, 1), c = octetOf(ip, 2);
    if (a == 127 || a == 10 || a == 0) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    if (a == 169 && b == 254) return true;
    if (a == 192 && b == 0 && c == 2) return true;
    if (a == 198 && b == 51 && c == 100) return true;
    if (a == 203 && b == 0 && c == 113) return true;
    if (a == 255 && b == 255 && c == 255) return true;
    return false;
}

// phone: what libphonenumber finds in the text (phone/phone.cc), a Dutch number
// without its country code among them. No country code starts with 0, which is
// what keeps a stand-in a stand-in.
extern (C) size_t phone_find(const(char)* text, size_t len, size_t* starts, size_t* ends, size_t cap);

enum PHONES = 256;

// postcode: four digits, a space or none, two capitals; the first digit never zero.
private Span postcodeAt(const(char)[] t, size_t i) {
    if (i > 0 && alnum(t[i - 1])) return Span.init;
    if (i + 6 > t.length) return Span.init;
    if (t[i] < '1' || t[i] > '9') return Span.init;
    foreach (k; 1 .. 4) if (!digit(t[i + k])) return Span.init;
    size_t p = i + 4;
    if (p < t.length && t[p] == ' ') p++;
    if (p + 2 > t.length) return Span.init;
    foreach (k; 0 .. 2) if (t[p + k] < 'A' || t[p + k] > 'Z') return Span.init;
    if (p + 2 < t.length && alnum(t[p + 2])) return Span.init;
    return Span(i, p + 2, Shape.postcode);
}

// street: a Dutch street name, by the word it ends on, and its house number.
private static immutable string[10] STREET_ENDS = [
    "straat", "laan", "weg", "plein", "gracht", "kade", "singel", "dijk", "steeg", "markt",
];

// The stand-in's own name, kept so a second pass changes nothing.
private enum STREET_STANDIN = "Voorbeeldstraat";

private bool endsWithCI(const(char)[] word, const(char)[] end) {
    if (word.length < end.length) return false;
    foreach (i, c; end) {
        char w = word[word.length - end.length + i];
        if (w >= 'A' && w <= 'Z') w += 32;
        if (w != c) return false;
    }
    return true;
}

private Span streetAt(const(char)[] t, size_t i) {
    if (i > 0 && alnum(t[i - 1])) return Span.init;
    size_t e = i;
    while (e < t.length && alpha(t[e])) e++;
    auto word = t[i .. e];
    bool named = false;
    foreach (end; STREET_ENDS) if (word.length >= end.length + 2 && endsWithCI(word, end)) named = true;
    if (!named) return Span.init;
    size_t p = e;
    if (p < t.length && t[p] == ' ') p++;
    size_t d = p;
    while (d < t.length && d - p < 4 && digit(t[d])) d++;
    if (d == p) return Span.init;
    if (d < t.length && alnum(t[d])) return Span.init;
    return Span(i, d, Shape.street);
}

private bool streetStays(const(char)[] v) {
    return v.length >= STREET_STANDIN.length && v[0 .. STREET_STANDIN.length] == STREET_STANDIN;
}

// The span starting at i, if the scanner recognises one. A phone is not asked
// here: libphonenumber has found them all before the scan begins.
Span spanAt(const(char)[] t, size_t i) {
    if (alpha(t[i])) return streetAt(t, i);
    if (digit(t[i])) {
        auto ip = ipAt(t, i);
        if (ip.ok) return ip;
        auto pc = postcodeAt(t, i);
        if (pc.ok) return pc;
    }
    return Span.init;
}

// What stands in for the n-th distinct value of a shape, n counted from 0. A
// stand-in is itself kept, so a second pass changes nothing.
private bool standIn(Shape shape, size_t n, const(string)[] allowedMail, scope bool delegate(const(char)[]) put) {
    char[20] d = 0;
    size_t k;
    size_t v = n + 1;
    do { d[k++] = cast(char)('0' + v % 10); v /= 10; } while (v > 0);
    bool num() { while (k > 0) { k--; if (!put(d[k .. k + 1])) return false; } return true; }
    final switch (shape) {
        case Shape.mail:
            if (allowedMail.length == 0) return put("tim@example.com");
            return put(allowedMail[n % allowedMail.length]);
        case Shape.ip:
            if (!put("192.0.2.")) return false;
            return num();
        case Shape.phone:
            if (!put("+000 0000 000")) return false;
            return num();
        case Shape.postcode:
            return put("0000 AA");
        case Shape.street:
            if (!put(STREET_STANDIN)) return false;
            if (!put(" ")) return false;
            return num();
        case Shape.none:
            return true;
    }
}

private bool same(const(char)[] a, const(char)[] b) {
    if (a.length != b.length) return false;
    foreach (i, c; a) if (c != b[i]) return false;
    return true;
}

private bool listed(const(char)[] v, const(string)[] list) {
    foreach (a; list) if (same(v, a)) return true;
    return false;
}

enum DISTINCT = 64;

// Every span of a shape written as its stand-in, the rest of the text as it
// was. Distinct values get distinct stand-ins in order of first appearance.
// `allowed` are mail addresses written as they are, and the ones stood in.
Scrubbed scrub(const(char)[] text, char[] dest, const(string)[] allowed = null) {
    Scrubbed r;
    size_t o = 0;
    bool put(const(char)[] s) {
        if (o + s.length > dest.length) return false;
        foreach (c; s) dest[o++] = c;
        return true;
    }
    // Not fitting is no answer: nothing truncated is ever handed on.
    Scrubbed none() { return Scrubbed(0, false); }

    size_t[DISTINCT] seenStart, seenEnd;
    Shape[DISTINCT] seenShape;
    size_t seen;

    // Every phone in the text, as libphonenumber finds them; at compile time no C runs.
    size_t[PHONES] phoneStart, phoneEnd;
    size_t phones = 0, nextPhone = 0;
    if (!__ctfe && text.length > 0) {
        phones = phone_find(text.ptr, text.length, phoneStart.ptr, phoneEnd.ptr, PHONES);
        if (phones > PHONES) return none();
    }

    size_t i = 0;
    while (i < text.length) {
        Span sp;
        if (text[i] == '@') sp = mailAround(text, i);
        else sp = spanAt(text, i);
        while (nextPhone < phones && phoneStart[nextPhone] < i) nextPhone++;
        if (!sp.ok && nextPhone < phones && phoneStart[nextPhone] == i)
            sp = Span(i, phoneEnd[nextPhone], Shape.phone);

        if (!sp.ok) {
            if (o >= dest.length) return none();
            dest[o++] = text[i];
            i++;
            continue;
        }
        // A mail span starts before its '@': what was already written of it
        // is taken back.
        if (sp.start < i) o -= i - sp.start;
        auto value = text[sp.start .. sp.end];

        bool stays = (sp.shape == Shape.mail && listed(value, allowed))
                  || (sp.shape == Shape.ip && ipStays(value))
                  || (sp.shape == Shape.street && streetStays(value));
        if (stays) {
            if (!put(value)) return none();
            i = sp.end;
            continue;
        }

        size_t n = 0;
        size_t which = seen;
        foreach (k; 0 .. seen) {
            if (seenShape[k] != sp.shape) continue;
            if (same(text[seenStart[k] .. seenEnd[k]], value)) { which = k; break; }
            n++;
        }
        if (which == seen) {
            if (seen == DISTINCT) return none();
            seenStart[seen] = sp.start; seenEnd[seen] = sp.end; seenShape[seen] = sp.shape;
            seen++;
        } else {
            // Its number is its place among the distinct values of its shape.
            n = 0;
            foreach (k; 0 .. which) if (seenShape[k] == sp.shape) n++;
        }
        if (!standIn(sp.shape, n, allowed, &put)) return none();
        r.count[sp.shape]++;
        i = sp.end;
    }
    r.len = o;
    return r;
}

// One field of a tool_input object scrubbed, the rest passed through as it
// is, the way homedir.rewriteField treats a field.
private ptrdiff_t indexOf(const(char)[] hay, const(char)[] needle) {
    if (needle.length > hay.length) return -1;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (same(hay[i .. i + needle.length], needle)) return cast(ptrdiff_t) i;
    return -1;
}

Scrubbed scrubField(const(char)[] region, const(char)[] key, char[] dest, const(string)[] allowed = null) {
    size_t o = 0;
    bool put(const(char)[] s) {
        if (o + s.length > dest.length) return false;
        foreach (c; s) dest[o++] = c;
        return true;
    }
    Scrubbed whole() { Scrubbed r; if (!put(region)) return Scrubbed(0, false); r.len = o; return r; }
    if (key.length == 0) return whole();

    char[64] needle = 0;
    if (key.length + 4 > needle.length) return Scrubbed(0, false);
    size_t n = 0;
    needle[n++] = '"';
    foreach (c; key) needle[n++] = c;
    needle[n++] = '"';
    needle[n++] = ':';
    needle[n++] = '"';

    auto at = indexOf(region, needle[0 .. n]);
    if (at < 0) return whole();
    size_t start = cast(size_t) at + n;
    size_t end = start;
    while (end < region.length) {
        if (region[end] == '\\' && end + 1 < region.length) { end += 2; continue; }
        if (region[end] == '"') break;
        end++;
    }
    if (!put(region[0 .. start])) return Scrubbed(0, false);
    auto inner = scrub(region[start .. end], dest[o .. $], allowed);
    if (!inner.fit) return Scrubbed(0, false);
    o += inner.len;
    if (!put(region[end .. $])) return Scrubbed(0, false);
    inner.len = o;
    return inner;
}

// The JSON value text starts with, whole: an object or array to its closing
// bracket, a string to its closing quote, anything else to the next comma or
// bracket. Null when it does not close.
const(char)[] jsonValue(const(char)[] text) {
    if (text.length == 0) return null;
    if (text[0] == '"') {
        size_t i = 1;
        while (i < text.length) {
            if (text[i] == '\\') { i += 2; continue; }
            if (text[i] == '"') return text[0 .. i + 1];
            i++;
        }
        return null;
    }
    if (text[0] == '{' || text[0] == '[') {
        size_t depth = 0;
        size_t i = 0;
        while (i < text.length) {
            auto c = text[i];
            if (c == '"') {
                i++;
                while (i < text.length && text[i] != '"') { if (text[i] == '\\') i++; i++; }
            } else if (c == '{' || c == '[') depth++;
            else if (c == '}' || c == ']') { depth--; if (depth == 0) return text[0 .. i + 1]; }
            i++;
        }
        return null;
    }
    size_t i = 0;
    while (i < text.length && text[i] != ',' && text[i] != '}' && text[i] != ']' && text[i] != '\n') i++;
    return text[0 .. i];
}

// What a scrub did, said in a line: how many of each shape.
size_t said(const ref Scrubbed r, char[] into) {
    size_t n;
    void put(const(char)[] s) { foreach (c; s) if (n < into.length) into[n++] = c; }
    void num(size_t v) {
        char[20] d = 0;
        size_t k;
        do { d[k++] = cast(char)('0' + v % 10); v /= 10; } while (v > 0);
        while (k > 0) { k--; put(d[k .. k + 1]); }
    }
    void one(size_t v, string single, string plural) {
        if (v == 0) return;
        if (n > 0) put(", ");
        num(v);
        put(" ");
        put(v == 1 ? single : plural);
    }
    one(r.count[Shape.mail], "mail address", "mail addresses");
    one(r.count[Shape.ip], "IP address", "IP addresses");
    one(r.count[Shape.phone], "phone number", "phone numbers");
    one(r.count[Shape.postcode], "postal code", "postal codes");
    one(r.count[Shape.street], "street address", "street addresses");
    return n;
}
