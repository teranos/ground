module fable;

// "i wish we also knew about fable usage better"
// "i had no idea i was getting to 70 so fast"
//
// Claude Code hands the status line five_hour and seven_day and no window
// scoped to a model. Its /usage dialog asks GET /api/oauth/usage with the
// login's OAuth token, and that answer carries the model window inside limits.
// Proven 2026-09-18 21:13 on this account: every seven_day_* key null, and
//   {"kind":"weekly_scoped","group":"weekly","percent":76,"severity":"warning",
//    "resets_at":"2026-09-23T18:59:59.517964+00:00",
//    "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":true}
// So ug asks the same endpoint, at its own rhythm, and writes the window down
// beside the two it is handed.

import json : jsonString;
import statusline : nextObject;

enum FABLE = "fable_week";
enum MODEL = "Fable";

// The one entry of limits scoped to the model, or absent.
struct Limit {
    const(char)[] percent;
    long resetsAt;
    bool present;
}

Limit fableIn(const(char)[] body_) {
    Limit none;
    auto limits = arrayOf(body_, "limits");
    if (limits.length == 0) return none;

    size_t at = 0;
    while (true) {
        auto span = nextObject(limits, at);
        if (!span.ok) break;
        at = span.end;
        auto entry = limits[span.start .. span.end];
        if (jsonString(entry, "kind") != "weekly_scoped") continue;
        auto scope_ = objectOf(entry, "scope");
        if (scope_.length == 0) continue;
        auto model = objectOf(scope_, "model");
        if (model.length == 0 || jsonString(model, "display_name") != MODEL) continue;

        auto pct = numberOf(entry, "percent");
        if (pct.length == 0) continue;
        return Limit(pct, epochOf(jsonString(entry, "resets_at")), true);
    }
    return none;
}

// 2026-09-23T18:59:59.517964+00:00 as an epoch, in whole seconds. Fractions
// are dropped, the offset is honoured, and anything else is 0: no reset.
long epochOf(const(char)[] iso) {
    size_t i = 0;
    bool bad = false;
    long digits(size_t n) {
        long v = 0;
        foreach (_; 0 .. n) {
            if (i >= iso.length || iso[i] < '0' || iso[i] > '9') { bad = true; return 0; }
            v = v * 10 + (iso[i] - '0');
            i++;
        }
        return v;
    }
    void expect(char c) {
        if (i >= iso.length || iso[i] != c) { bad = true; return; }
        i++;
    }

    auto year = digits(4); expect('-');
    auto month = digits(2); expect('-');
    auto day = digits(2); expect('T');
    auto hour = digits(2); expect(':');
    auto minute = digits(2); expect(':');
    auto second = digits(2);
    if (bad || month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60)
        return 0;

    if (i < iso.length && iso[i] == '.') {
        i++;
        while (i < iso.length && iso[i] >= '0' && iso[i] <= '9') i++;
    }

    long offset = 0;
    if (i < iso.length && (iso[i] == '+' || iso[i] == '-')) {
        auto sign = iso[i] == '-' ? -1 : 1;
        i++;
        auto oh = digits(2); expect(':');
        auto om = digits(2);
        if (bad) return 0;
        offset = sign * (oh * 3600 + om * 60);
    } else if (i < iso.length && iso[i] == 'Z') {
        i++;
    } else {
        return 0;
    }
    if (i != iso.length) return 0;

    return daysFromCivil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second - offset;
}

// Days since 1970-01-01 of a proleptic Gregorian date. Howard Hinnant's
// days_from_civil, which the C library's timegm is not there to do in -betterC.
long daysFromCivil(long y, long m, long d) {
    y -= m <= 2;
    auto era = (y >= 0 ? y : y - 399) / 400;
    auto yoe = y - era * 400;
    auto doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    auto doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146_097 + doe - 719_468;
}

// The array a key holds, brackets included, or empty when the key holds none.
private const(char)[] arrayOf(const(char)[] text, const(char)[] key) {
    auto at = valueAt(text, key);
    if (at >= text.length || text[at] != '[') return null;
    return spanFrom(text, at, '[', ']');
}

private const(char)[] objectOf(const(char)[] text, const(char)[] key) {
    auto at = valueAt(text, key);
    if (at >= text.length || text[at] != '{') return null;
    return spanFrom(text, at, '{', '}');
}

// From an opener to its closer, by depth, with strings stepped over.
private const(char)[] spanFrom(const(char)[] text, size_t at, char open, char close) {
    size_t depth = 0;
    bool inString = false;
    size_t i = at;
    while (i < text.length) {
        auto c = text[i];
        if (inString) {
            if (c == '\\') { i += 2; continue; }
            if (c == '"') inString = false;
            i++;
            continue;
        }
        if (c == '"') inString = true;
        else if (c == open) depth++;
        else if (c == close) {
            depth--;
            if (depth == 0) return text[at .. i + 1];
        }
        i++;
    }
    return null;
}

// The number a key holds, as written, or empty when it holds none.
private const(char)[] numberOf(const(char)[] obj, const(char)[] key) {
    auto at = valueAt(obj, key);
    if (at >= obj.length) return null;
    auto c0 = obj[at];
    if (!(c0 == '-' || (c0 >= '0' && c0 <= '9'))) return null;
    size_t e = at;
    while (e < obj.length) {
        auto c = obj[e];
        if ((c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+' || c == 'e' || c == 'E') e++;
        else break;
    }
    return obj[at .. e];
}

private size_t valueAt(const(char)[] text, const(char)[] key) {
    if (key.length == 0) return text.length;
    size_t i = 0;
    while (i + key.length + 2 < text.length) {
        if (text[i] != '"' || text[i + 1 .. i + 1 + key.length] != key
            || text[i + 1 + key.length] != '"') { i++; continue; }
        size_t j = i + 2 + key.length;
        while (j < text.length && (text[j] == ' ' || text[j] == '\t')) j++;
        if (j >= text.length || text[j] != ':') { i++; continue; }
        j++;
        while (j < text.length && (text[j] == ' ' || text[j] == '\t')) j++;
        return j;
    }
    return text.length;
}

// ---- the ask: everything below spends a process, not a frame ----

enum USAGE_HOST = "https://api.anthropic.com";
enum USAGE_PATH = "/api/oauth/usage";

// The keychain item Claude Code keeps its login in: service
// "Claude Code-credentials", a JSON with claudeAiOauth.accessToken inside.
// Read by /usr/bin/security and held for one request; never written anywhere.
enum SECURITY = "/usr/bin/security";
enum CREDENTIALS = "Claude Code-credentials";

enum CURL = "/usr/bin/curl";
enum MAX_TIME = 10;

// CLAUDE_USAGE_HOST and CLAUDE_CREDENTIALS_SERVICE replace the two for one
// process. The live test points the host at an address that never answers and
// the service at a name nothing holds, so a test reads no credential.
private const(char)[] envOr(const(char)* name, const(char)[] fallback) {
    import core.stdc.stdlib : getenv;
    auto e = getenv(name);
    if (e is null) return fallback;
    size_t n = 0;
    while (e[n] != 0) n++;
    return n > 0 ? e[0 .. n] : fallback;
}

const(char)[] usageHost() { return envOr("CLAUDE_USAGE_HOST\0".ptr, USAGE_HOST); }
const(char)[] credentialsService() { return envOr("CLAUDE_CREDENTIALS_SERVICE\0".ptr, CREDENTIALS); }

// How an ask went: the window it found, the HTTP status, and curl's exit.
// curlExit -1 is no token to send with, a request never made.
struct Asked {
    Limit limit;
    int status;
    int curlExit;
}

// The access token out of the keychain, into `dest`. 0 when the item is not
// there, cannot be read, or holds no claudeAiOauth.accessToken.
size_t tokenInto(char[] dest) {
    import core.stdc.stdio : FILE, fread;
    import core.sys.posix.stdio : popen, pclose;

    __gshared char[512] cmd = void;
    size_t m = 0;
    void putCmd(const(char)[] s) { foreach (ch; s) if (m + 1 < cmd.length) cmd[m++] = ch; }
    putCmd(SECURITY);
    putCmd(" find-generic-password -s '");
    foreach (ch; credentialsService()) if (ch != '\'') { if (m + 1 < cmd.length) cmd[m++] = ch; }
    putCmd("' -w 2>/dev/null");
    cmd[m] = 0;

    auto pipe = popen(&cmd[0], "r");
    if (pipe is null) return 0;

    __gshared char[16384] blob = void;
    size_t total = 0;
    while (total < blob.length) {
        auto n = fread(&blob[total], 1, blob.length - total, cast(FILE*) pipe);
        if (n == 0) break;
        total += n;
    }
    pclose(pipe);

    auto oauth = objectOf(blob[0 .. total], "claudeAiOauth");
    auto token = jsonString(oauth, "accessToken");
    size_t o = 0;
    foreach (ch; token) if (o < dest.length) dest[o++] = ch;
    // Wiped: the blob held the refresh token too.
    foreach (ref ch; blob[0 .. total]) ch = 0;
    return o;
}

// One GET. The token goes in a config file curl reads, not on the argv, and
// the file is gone before the answer is looked at.
Asked askFable() {
    import core.stdc.stdio : FILE, fopen, fwrite, fclose, fread, remove;
    import core.sys.posix.stdio : popen, pclose;
    import core.sys.posix.unistd : getpid;
    import probe : split;

    __gshared char[4096] token = void;
    auto tl = tokenInto(token[]);
    if (tl == 0) return Asked(Limit.init, 0, -1);

    __gshared char[256] conf = void;
    size_t c = 0;
    foreach (ch; "/tmp/ug-usage-") conf[c++] = ch;
    {
        char[12] d = void;
        size_t dl = 0;
        int v = getpid();
        if (v <= 0) d[dl++] = '0';
        while (v > 0 && dl < 11) { d[dl++] = cast(char)('0' + v % 10); v /= 10; }
        foreach_reverse (i; 0 .. dl) conf[c++] = d[i];
    }
    foreach (ch; ".conf") conf[c++] = ch;
    conf[c] = 0;

    {
        auto f = fopen(&conf[0], "wb");
        if (f is null) { foreach (ref ch; token[0 .. tl]) ch = 0; return Asked(Limit.init, 0, 0); }
        void line(const(char)[] s) { fwrite(s.ptr, 1, s.length, f); }
        line("silent\nshow-error\nmax-time = 10\n");
        line("header = \"Authorization: Bearer ");
        line(token[0 .. tl]);
        line("\"\nheader = \"anthropic-beta: oauth-2025-04-20\"\n");
        fclose(f);
    }
    foreach (ref ch; token[0 .. tl]) ch = 0;

    __gshared char[512] cmd = void;
    size_t m = 0;
    bool overflowed = false;
    void putCmd(const(char)[] s) {
        if (m + s.length + 1 > cmd.length) { overflowed = true; return; }
        foreach (ch; s) cmd[m++] = ch;
    }
    putCmd(CURL);
    putCmd(" --config ");
    putCmd(conf[0 .. c]);
    putCmd(" --write-out '\\nHTTP %{http_code}' ");
    putCmd(usageHost());
    putCmd(USAGE_PATH);
    putCmd(" 2>/dev/null");
    cmd[m] = 0;
    if (overflowed) { remove(&conf[0]); return Asked(Limit.init, 0, 0); }

    auto pipe = popen(&cmd[0], "r");
    if (pipe is null) { remove(&conf[0]); return Asked(Limit.init, 0, 0); }

    __gshared char[65536] out_ = void;
    size_t total = 0;
    while (total < out_.length) {
        auto n = fread(&out_[total], 1, out_.length - total, cast(FILE*) pipe);
        if (n == 0) break;
        total += n;
    }
    auto status = pclose(pipe);
    remove(&conf[0]);
    auto curlExit = (status & 0x7f) == 0 ? (status >> 8) & 0xff : status;

    auto answer = split(out_[0 .. total], curlExit);
    Asked asked;
    asked.status = answer.status;
    asked.curlExit = curlExit;
    if (curlExit == 0 && answer.status == 200) asked.limit = fableIn(answer.body_);
    return asked;
}
