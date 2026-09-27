module noul;

// BOOK_GLOSSARY **Noul**: One of Jev's three primitives, with Score and Choice. A rite may carry one where an eval would stand: Jev reads the push as state and answers in its own fields, and the answer is the verdict.

// "see Jev's noul as another way to set a rituals rite"
// "i say Jev is optional, no Jev is autopass"
// "can you get as close to jev api as possible no inventions"
// "TypeSafe has three primitives Choice Score Noul why cant i have that"

import zbuf : ZBuf;

enum JEV_URL = "https://api.typesafe.ai/v1/systemone";
enum JEV_TOKEN_PATH = "~/.qntx/jev-token";
enum JEV_MODEL = "jev-latest";

// The token, or null: no file at the path is no Jev, and no Jev is autopass.
const(char)[] jevToken() {
    import attest : qntxToken;
    return qntxToken(JEV_TOKEN_PATH);
}

// A push's diff does not fit a ZBuf. This holds the state and the body.
struct Wide {
    char[262_144] data = 0;
    size_t len;
    bool over;
    void reset() { len = 0; over = false; }
    void put(const(char)[] s) {
        foreach (c; s) {
            if (len >= data.length - 1) { over = true; return; }
            data[len++] = c;
        }
    }
    void putChar(char c) { put((&c)[0 .. 1]); }
    const(char)[] slice() return { return data[0 .. len]; }
}

private void putJson(S)(ref S b, const(char)[] s) {
    foreach (c; s) {
        if (c == '"') b.put(`\"`);
        else if (c == '\\') b.put(`\\`);
        else if (c == '\n') b.put(`\n`);
        else if (c == '\r') b.put(`\r`);
        else if (c == '\t') b.put(`\t`);
        else if (c < 0x20) continue;
        else b.putChar(c);
    }
}

// One request: the state as given, the model, one question under the rite's
// name with Jev's fields. criteria is a list for a score, a map for a choice
// when keys are given, absent for a noul.
void jevBody(S)(ref S b, const(char)[] stateJson, const(char)[] rite, const(char)[] type,
                const(char)[] instructions, const(char[])[] criteria,
                const(char[])[] keys = []) {
    b.reset();
    b.put(`{"state":`);
    b.put(stateJson);
    b.put(`,"model":"` ~ JEV_MODEL ~ `","questions":{"`);
    putJson(b, rite);
    b.put(`":{"type":"`);
    putJson(b, type);
    b.put(`","instructions":"`);
    putJson(b, instructions);
    b.put(`"`);
    if (criteria.length > 0) {
        b.put(`,"criteria":`);
        if (keys.length > 0) {
            b.put("{");
            foreach (i; 0 .. criteria.length) {
                if (i > 0) b.put(",");
                b.put(`"`); putJson(b, keys[i]); b.put(`":"`); putJson(b, criteria[i]); b.put(`"`);
            }
            b.put("}");
        } else {
            b.put("[");
            foreach (i; 0 .. criteria.length) {
                if (i > 0) b.put(",");
                b.put(`"`); putJson(b, criteria[i]); b.put(`"`);
            }
            b.put("]");
        }
    }
    b.put(`}}}`);
}

// What Jev answered, in its fields. `level` is a score's most probable level;
// `choice` a choice's option name.
struct JevAnswer {
    const(char)[] type;
    double noul;
    double score;
    double confidence;
    int level;
    char[64] choiceBuf = 0;
    size_t choiceLen;
    const(char)[] choice() const return { return choiceBuf[0 .. choiceLen]; }
}

// A decimal as Jev writes one: digits, a point, digits. No C call, so the
// envelope that carries the answer can be built at compile time in a test.
bool parseDecimal(const(char)[] s, ref double v) {
    size_t i = 0;
    while (i < s.length && s[i] == ' ') i++;
    bool neg = false;
    if (i < s.length && s[i] == '-') { neg = true; i++; }
    if (i >= s.length || s[i] < '0' || s[i] > '9') return false;
    double whole = 0;
    while (i < s.length && s[i] >= '0' && s[i] <= '9') { whole = whole * 10 + (s[i] - '0'); i++; }
    double frac = 0, scale = 1;
    if (i < s.length && s[i] == '.') {
        i++;
        while (i < s.length && s[i] >= '0' && s[i] <= '9') { frac = frac * 10 + (s[i] - '0'); scale *= 10; i++; }
    }
    v = whole + frac / scale;
    if (neg) v = -v;
    return true;
}

// The number after `"key":` inside obj, or false.
private bool numberAfter(const(char)[] obj, const(char)[] key, ref double v) {
    import matcher : indexOf;
    auto at = indexOf(obj, key);
    if (at < 0) return false;
    return parseDecimal(obj[cast(size_t) at + key.length .. $], v);
}

// The reply, read by the rite's name.
bool jevAnswer(const(char)[] reply, const(char)[] rite, ref JevAnswer a) {
    import matcher : indexOf;
    a = JevAnswer.init;
    char[128] key = 0;
    size_t n = 0;
    void put(const(char)[] s) { foreach (c; s) if (n < key.length - 1) key[n++] = c; }
    put(`"`); put(rite); put(`":{`);
    auto at = indexOf(reply, key[0 .. n]);
    if (at < 0) return false;
    auto obj = reply[cast(size_t) at + n .. $];

    auto t = indexOf(obj, `"type":"`);
    if (t < 0) return false;
    auto tt = obj[cast(size_t) t + 8 .. $];
    size_t tl = 0;
    while (tl < tt.length && tt[tl] != '"') tl++;
    a.type = tt[0 .. tl];

    if (a.type == "noul") return numberAfter(obj, `"noul":`, a.noul);

    if (a.type == "score") {
        if (!numberAfter(obj, `"score":`, a.score)) return false;
        numberAfter(obj, `"confidence":`, a.confidence);
        // The level with the most probability: walk "probabilities":{"0":p,...}
        auto pr = indexOf(obj, `"probabilities":{`);
        if (pr < 0) return false;
        auto ps = obj[cast(size_t) pr + 17 .. $];
        double best = -1;
        size_t i = 0;
        while (i < ps.length && ps[i] != '}') {
            if (ps[i] != '"') { i++; continue; }
            i++;
            int lvl = 0;
            while (i < ps.length && ps[i] >= '0' && ps[i] <= '9') { lvl = lvl * 10 + (ps[i] - '0'); i++; }
            if (i < ps.length && ps[i] == '"') i++;
            if (i < ps.length && ps[i] == ':') i++;
            double p;
            if (!numberAfter(ps[i - 1 .. $], ":", p)) break;
            if (p > best) { best = p; a.level = lvl; }
            while (i < ps.length && ps[i] != ',' && ps[i] != '}') i++;
        }
        return best >= 0;
    }

    if (a.type == "choice") {
        auto c = indexOf(obj, `"choice":"`);
        if (c < 0) return false;
        auto cs = obj[cast(size_t) c + 10 .. $];
        while (a.choiceLen < cs.length && cs[a.choiceLen] != '"' && a.choiceLen < a.choiceBuf.length) {
            a.choiceBuf[a.choiceLen] = cs[a.choiceLen];
            a.choiceLen++;
        }
        numberAfter(obj, `"confidence":`, a.confidence);
        return a.choiceLen > 0;
    }
    return false;
}

// The push as state: git facts about the tree, nothing invented.
void jevState(ref Wide s, const(char)[] worktree, const(char)[] branch) {
    s.reset();
    s.put(`{"repo":"`);
    size_t start = worktree.length;
    while (start > 0 && worktree[start - 1] != '/') start--;
    putJson(s, worktree[start .. $]);
    s.put(`","branch":"`); putJson(s, branch);
    s.put(`","commit":"`); gitJson(s, worktree, "log -1 --format=%h");
    s.put(`","subject":"`); gitJson(s, worktree, "log -1 --format=%s");
    s.put(`","summary":"`); gitJson(s, worktree, "diff --shortstat HEAD~1 HEAD");
    s.put(`","files_changed":"`); gitJson(s, worktree, "diff --name-only HEAD~1 HEAD");
    s.put(`","diff":"`); gitJson(s, worktree, "diff HEAD~1 HEAD");
    s.put(`"}`);
}

private void gitJson(ref Wide s, const(char)[] worktree, const(char)[] args) {
    import db : popen, pclose;
    import core.stdc.stdio : fread;
    __gshared ZBuf cmd;
    cmd.reset();
    cmd.put("git -C '");
    foreach (c; worktree) { if (c == '\'') cmd.put(`'\''`); else cmd.putChar(c); }
    cmd.put("' ");
    cmd.put(args);
    cmd.put(" 2>&1");
    auto pipe = popen(cmd.ptr(), "r");
    if (pipe is null) return;
    char[4096] chunk;
    for (;;) {
        auto got = fread(&chunk[0], 1, chunk.length, pipe);
        if (got == 0) break;
        putJson(s, chunk[0 .. got]);
        if (s.over) break;
    }
    pclose(pipe);
    // A trailing newline is git's, not the value's.
    if (s.len >= 2 && s.data[s.len - 2] == '\\' && s.data[s.len - 1] == 'n') s.len -= 2;
}

// How the asking went. `answer` is only an answer when `ok`.
struct JevAsk {
    bool ok;
    JevAnswer answer;
    int status;
    int curl;
    size_t replyLen;  // what Jev sent, in the caller's buffer; the rest is old
    char[256] whyBuf = 0;
    size_t whyLen;
    const(char)[] why() const return { return whyBuf[0 .. whyLen]; }
}

private void say(ref JevAsk a, const(char)[] s) {
    foreach (c; s) if (a.whyLen < a.whyBuf.length) a.whyBuf[a.whyLen++] = c;
}

// Ask Jev one question about the push. The reply is kept in full for the
// row and for the reason when it refuses.
JevAsk askJev(const(char)[] stateJson, const(char)[] rite, const(char)[] type,
              const(char)[] instructions, const(char[])[] criteria, const(char[])[] keys,
              const(char)[] token, ref char[8192] reply) {
    import http : httpPostInto;
    JevAsk a;
    __gshared Wide body_;
    jevBody(body_, stateJson, rite, type, instructions, criteria, keys);
    if (body_.over) { say(a, "the push is larger than the request ground can send"); return a; }
    auto r = httpPostInto(JEV_URL, body_.slice(), token, reply[], 20);
    a.status = r.status;
    a.curl = r.code;
    a.replyLen = r.len;
    if (r.code != 0) { say(a, "jev unreachable: "); say(a, r.why()); return a; }
    if (r.status != 200) {
        say(a, "jev answered ");
        char[12] d = 0; size_t dl; auto v = r.status;
        while (v > 0 && dl < d.length) { d[dl++] = cast(char)('0' + v % 10); v /= 10; }
        foreach_reverse (i; 0 .. dl) say(a, d[i .. i + 1]);
        say(a, ": ");
        say(a, reply[0 .. r.len > 200 ? 200 : r.len]);
        return a;
    }
    if (!jevAnswer(reply[0 .. r.len], rite, a.answer)) {
        say(a, "jev answered 200 without an answer for this rite: ");
        say(a, reply[0 .. r.len > 200 ? 200 : r.len]);
        return a;
    }
    a.ok = true;
    return a;
}
