module code.login;

// ground code signs in to its QNTX node by its device flow (RFC 8628, QNTX's
// server/auth/device.go), naming the key it holds: the person approves it with
// the passkey at home, and that key is then the person at the node. Nothing is
// handed back. Ground signs each request with the key (signed.d), and the key
// never leaves the machine.
//
// "A signature proves the key, and nothing reusable leaves the node."

import code.reply : Reply, putEscaped, putNumber;
import signed : Key;
import libjsonc : json_object, json_type, json_object_get_type, json_object_get_string, json_object_get_string_len,
    json_object_get_int64, json_object_put, jsonField, parseJson;

// 「[Opus 5.5] The node's own paths: where an agent asks for a sign-in, and where it asks」
// 「[Opus 5.5] whether its yes came.」
enum DEVICE_PATH = "/auth/device";
enum TOKEN_PATH = "/auth/token";
// The name the person reads at home before they say yes, and the grant is labelled with.
enum LABEL = "ground code";
// 「[Opus 5.5] RFC 8628 §3.4's grant_type.」
enum DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code";
// 「[Opus 5.5] RFC 8628 §3.5: "the interval MUST be increased by 5 seconds for this and all subsequent requests".」
enum SLOW_DOWN_SECONDS = 5;
private enum ANSWER_BYTES = 16384;
private enum ASK_SECONDS = 30;

// A sign-in the node started: the code the grant is asked for with, the code
// the person compares, the link they follow, and how long to wait between asks.
struct SignIn {
    Reply deviceCode, userCode, link;
    // The did:key of the key the sign-in is for, which the node answers with once the person said yes.
    Reply did;
    uint interval;
    void dispose() { deviceCode.dispose(); userCode.dispose(); link.dispose(); did.dispose(); }
}

// 「[Opus 5.5] application/x-www-form-urlencoded: unreserved bytes as they are, a space as」
// 「[Opus 5.5] +, every other byte %XX.」
private void putForm(ref Reply r, const(char)[] s) {
    enum hex = "0123456789ABCDEF";
    foreach (c; s) {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~') {
            char[1] one = [c];
            r.add(one[]);
        } else if (c == ' ') r.add("+");
        else {
            char[3] e = ['%', hex[(c >> 4) & 0xf], hex[c & 0xf]];
            r.add(e[]);
        }
    }
}

// 「[Opus 5.5] What a request to the node came to, as ACP error data: where, the status,」
// 「[Opus 5.5] libcurl's code and words, and the node's answer, every byte.」
private void putAsked(ref Reply why, const(char)[] url, int status, int code, const(char)[] said, const(char)[] body_) {
    why.add(`{"url":"`); putEscaped(why, url);
    why.add(`","status":`); putNumber(why, cast(uint) status);
    why.add(`,"curl":`); putNumber(why, cast(uint) code);
    why.add(`,"why":"`); putEscaped(why, said);
    why.add(`","body":"`); putEscaped(why, body_); why.add(`"}`);
}

private const(char)[] stringOf(json_object* value) {
    if (json_object_get_type(value) != json_type.string_) return null;
    auto p = json_object_get_string(value);
    return p[0 .. cast(size_t) json_object_get_string_len(value)];
}

// 「[Opus 5.5] One form POST to the node, its answer in dest: the status, or -1 when it」
// 「[Opus 5.5] was not answered, said in why.」
private int ask(const(char)[] url, const(char)[] form, char[] dest, ref size_t len, ref Reply why) {
    import http : httpPostInto;
    auto h = httpPostInto(url, form, null, dest, ASK_SECONDS, "application/x-www-form-urlencoded");
    len = h.len;
    if (h.code != 0 || h.overran || h.status == 0) {
        putAsked(why, url, h.status, h.code, h.why(), dest[0 .. h.len]);
        return -1;
    }
    return h.status;
}

// "POST /auth/device, a form naming the agent in label", and the did:key of the
// key kept at keyAt, made there first when there is none: 1 the sign-in is
// started, -1 it is not, the node's answer in why.
int startSignIn(const(char)[] node, const(char)* keyAt, ref SignIn s, ref Reply why) {
    import signed : keepKey;
    auto key = keepKey(keyAt);
    if (!key.held) {
        why.add(`{"message":"no key is kept for ground to sign with"}`);
        return -1;
    }
    return startSignInFor(node, key, s, why);
}

// The same for a key held in memory: mycelia's person key, which lives in the
// Keychain and in no file.
int startSignInFor(const(char)[] node, ref const Key key, ref SignIn s, ref Reply why, const(char)[] label = LABEL) {
    import signed : putDID;
    import zbuf : ZBuf;
    __gshared ZBuf did;
    did.reset();
    putDID(did, key.public_[]);
    s.did.add(did.slice());
    Reply url, form;
    scope(exit) { url.dispose(); form.dispose(); }
    url.add(node); url.add(DEVICE_PATH);
    form.add("label="); putForm(form, label);
    form.add("&did="); putForm(form, did.slice());
    __gshared char[ANSWER_BYTES] dest;
    size_t len;
    auto status = ask(url.slice(), form.slice(), dest[], len, why);
    if (status < 0) return -1;
    auto answered = dest[0 .. len];
    auto o = status == 200 ? parseJson(answered) : null;
    scope(exit) json_object_put(o);
    auto deviceCode = stringOf(jsonField(o, "device_code"));
    auto userCode = stringOf(jsonField(o, "user_code"));
    auto link = stringOf(jsonField(o, "verification_uri_complete"));
    if (link is null) link = stringOf(jsonField(o, "verification_uri"));
    auto interval = jsonField(o, "interval");
    if (deviceCode is null || userCode is null || link is null) {
        putAsked(why, url.slice(), status, 0, status == 200 ? "the node's answer names no device_code, user_code and link" : "", answered);
        return -1;
    }
    s.deviceCode.add(deviceCode);
    s.userCode.add(userCode);
    s.link.add(link);
    // "If no value is provided, clients MUST use 5 as the default."
    auto every = json_object_get_type(interval) == json_type.int_ ? json_object_get_int64(interval) : 5;
    s.interval = every < 0 ? 0 : every > 3600 ? 3600 : cast(uint) every;
    return s.deviceCode.full || s.userCode.full || s.link.full ? -1 : 1;
}

// Whether the person said yes: 1 when the node answers with the key's DID, 0
// still waiting (authorization_pending, or slow_down, which waits longer from
// then on), -1 over, the node's answer in why.
int pollSignIn(const(char)[] node, ref SignIn s, ref Reply why) {
    Reply url, form;
    scope(exit) { url.dispose(); form.dispose(); }
    url.add(node); url.add(TOKEN_PATH);
    form.add("grant_type="); putForm(form, DEVICE_GRANT);
    form.add("&device_code="); putForm(form, s.deviceCode.slice());
    __gshared char[ANSWER_BYTES] dest;
    size_t len;
    auto status = ask(url.slice(), form.slice(), dest[], len, why);
    if (status < 0) return -1;
    auto answered = dest[0 .. len];
    auto o = parseJson(answered);
    scope(exit) json_object_put(o);
    auto said = stringOf(jsonField(o, "did"));
    if (status == 200 && said !is null && said == s.did.slice()) return 1;
    if (status == 200) {
        putAsked(why, url.slice(), status, 0, "the node said yes to another key than the one ground holds", answered);
        return -1;
    }
    auto error = stringOf(jsonField(o, "error"));
    if (status == 400 && error == "authorization_pending") return 0;
    if (status == 400 && error == "slow_down") { s.interval += SLOW_DOWN_SECONDS; return 0; }
    putAsked(why, url.slice(), status, 0, "", answered);
    return -1;
}

// Drops the file kept at file: 1 dropped, 0 none was there, -1 it could not be,
// why in why.
int dropKept(const(char)* file, ref Reply why) {
    import core.sys.posix.unistd : unlink;
    import core.stdc.errno : errno, ENOENT;
    import core.stdc.string : strlen, strerror;
    if (unlink(file) == 0) return 1;
    if (errno == ENOENT) return 0;
    auto e = strerror(errno);
    why.add(`{"message":"could not remove the file","path":"`); putEscaped(why, file[0 .. strlen(file)]);
    why.add(`","errno":`); putNumber(why, cast(uint) errno); why.add(`,"why":"`); putEscaped(why, e[0 .. strlen(e)]); why.add(`"}`);
    return -1;
}

// `ground code login`, as a client's terminal auth method runs it: the link and
// the code said, the node asked until the person said yes to the key kept at
// keyAt, which is what speaks from then on.
// 0 signed in, 1 not, what the node said given to say.
int login(const(char)[] node, const(char)* keyAt, scope void delegate(const(char)[]) say) {
    import core.stdc.string : strlen;
    import signed : keepKey;
    if (node.length == 0) { say("ground code login: the qntx block names no url, so there is no node to sign in to\n"); return 1; }
    if (keyAt is null) { say("ground code login: the key is kept in a home, and HOME names none\n"); return 1; }
    auto key = keepKey(keyAt);
    if (!key.held) { say("ground code login: the node did not start a sign-in: {\"message\":\"no key is kept for ground to sign with\"}\n"); return 1; }
    return loginFor(node, key, keyAt[0 .. strlen(keyAt)], LABEL, say);
}

// The sign-in for a key held in memory, under label; kept names where the key
// is kept, for the line that says it is signed in.
int loginFor(const(char)[] node, ref const Key key, const(char)[] kept, const(char)[] label,
             scope void delegate(const(char)[]) say) {
    import core.sys.posix.unistd : sleep;
    SignIn s;
    Reply why;
    scope(exit) { s.dispose(); why.dispose(); }
    if (node.length == 0) { say("ground code login: the qntx block names no url, so there is no node to sign in to\n"); return 1; }
    if (startSignInFor(node, key, s, why, label) != 1) {
        say("ground code login: the node did not start a sign-in: "); say(why.slice()); say("\n");
        return 1;
    }
    say("Sign in to QNTX as "); say(label); say(": open\n\n  "); say(s.link.slice());
    say("\n\nand check the code there is "); say(s.userCode.slice()); say(".\n");
    while (true) {
        sleep(s.interval);
        why.len = 0;
        auto got = pollSignIn(node, s, why);
        if (got == 0) continue;
        if (got < 0) { say("ground code login: not signed in: "); say(why.slice()); say("\n"); return 1; }
        break;
    }
    say("Signed in as "); say(s.did.slice()); say(". The key is kept in "); say(kept); say(".\n");
    return 0;
}
