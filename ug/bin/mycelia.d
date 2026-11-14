module bin.mycelia;

// "so, why would the part that asks the node, not be able to be its own tiny binary"
import mycelia : myceliaMain, verbOf, Verb, personPathInto;
static import signed;
static import zbuf;

// The Keychain, behind Touch ID (ug/touch.c).
extern (C) int touch_keep(const(ubyte)* seed, int n);
extern (C) int touch_take(ubyte* out_, int cap, const(char)* prompt, int* n);
extern (C) void touch_said(int st, char* out_, int cap);

// "kept. kept bro, i want to put my finger on, and then not have to thing about it anymore"
// mycelia connect: the person's own key, signed in to the node the person says
// yes to with a passkey. Made here the first time and kept in the Keychain,
// where only this signed binary sees it and taking it out asks for a touch;
// its DID is written down, so knowing who the person is takes no touch. Here
// and not in mycelia.d, so only this binary carries the sign-in.
int connectMain(const(char)[] home) {
    import code.login : loginFor;
    import signed : Key, keyOf, putDID, randombytes_buf, SEED_BYTES;
    import probe : host;
    import zbuf : ZBuf;
    import core.stdc.stdio : fwrite, fflush, stdout, fopen, fclose, fread, rename;
    void say(const(char)[] s) { fwrite(s.ptr, 1, s.length, stdout); fflush(stdout); }
    void refused(const(char)[] what, int st) {
        char[256] why = 0;
        touch_said(st, why.ptr, why.length);
        size_t n = 0;
        while (why[n] != 0) n++;
        __gshared ZBuf line;
        line.reset();
        line.put("mycelia connect: ");
        line.put(what);
        line.put(": OSStatus ");
        if (st < 0) { line.put("-"); line.putUint(cast(ulong) -st); } else line.putUint(cast(ulong) st);
        line.put(" ");
        line.put(why[0 .. n]);
        line.put("\n");
        say(line.slice());
    }

    __gshared char[512] path = void;
    auto pn = personPathInto(home, path[]);
    if (pn == 0) { say("mycelia connect: HOME names no home to keep the person's DID in\n"); return 1; }

    ubyte[SEED_BYTES] seed;
    Key key;
    auto kept = fopen(&path[0], "rb");
    if (kept !is null) {
        fclose(kept);
        int n = 0;
        auto st = touch_take(seed.ptr, seed.length, "mycelia: sign your key in to the node\0".ptr, &n);
        if (st != 0 || n != SEED_BYTES) { refused("the key was not taken out of the Keychain", st); return 1; }
        key = keyOf(seed[]);
    } else {
        randombytes_buf(seed.ptr, seed.length);
        auto st = touch_keep(seed.ptr, seed.length);
        if (st != 0) { refused("the key was not kept in the Keychain", st); return 1; }
        key = keyOf(seed[]);
        __gshared ZBuf did;
        did.reset();
        putDID(did, key.public_[]);
        did.put("\n");
        __gshared char[520] beside = void;
        foreach (i; 0 .. pn) beside[i] = path[i];
        foreach (i, c; ".new") beside[pn + i] = c;
        beside[pn + 4] = 0;
        auto f = fopen(&beside[0], "wb");
        if (f is null) { say("mycelia connect: the person's DID could not be written down\n"); return 1; }
        fwrite(did.ptr(), 1, did.len, f);
        fclose(f);
        rename(&beside[0], &path[0]);
    }
    seed[] = 0;
    if (!key.held) { say("mycelia connect: no key could be made of the seed\n"); return 1; }
    return loginFor(host(), key, "the Keychain, behind Touch ID", "you, through mycelia", &say);
}

// The person's key, once a touch has taken it out of the Keychain: held from
// the first press until mycelia stops, which a reboot or a restart is.
// "next reboot i expect to have to put my finger again."
__gshared signed.Key held;

// A press, signed as the person and asked of the node: the node's status on
// the first line of reply, its body after; 0 and why when it was not asked.
int press(const(char)[] path, const(char)[] body_, ref zbuf.ZBuf reply) {
    import signed : keyOf, SEED_BYTES;
    import http : httpPostInto, ToNode;
    import probe : host;
    if (!held.held) {
        ubyte[SEED_BYTES] seed;
        int n = 0;
        auto st = touch_take(seed.ptr, seed.length, "mycelia: trust your presses until this Mac restarts\0".ptr, &n);
        if (st != 0 || n != SEED_BYTES) {
            char[256] why = 0;
            touch_said(st, why.ptr, why.length);
            size_t w = 0;
            while (why[w] != 0) w++;
            reply.put("0\nthe person's key was not taken out of the Keychain: ");
            reply.put(why[0 .. w]);
            return 1;
        }
        held = keyOf(seed[]);
        seed[] = 0;
    }
    __gshared zbuf.ZBuf url;
    url.reset();
    url.put(host());
    url.put(path);
    __gshared char[65536] answer = void;
    auto r = httpPostInto(url.slice(), body_, ToNode(null, &held), answer[], 60);
    reply.putUint(cast(ulong) r.status);
    reply.put("\n");
    if (r.status > 0) reply.put(answer[0 .. r.len]);
    else {
        reply.put(url.slice());
        reply.put(" was not reached: ");
        reply.put(r.why());
    }
    return 0;
}

extern (C) int main(int argc, char** argv) {
    import core.stdc.stdlib : getenv;
    import core.stdc.stdio : fputs, stderr;

    const(char)[] verb;
    if (argc >= 2 && argv[1] !is null) {
        size_t al = 0;
        while (argv[1][al] != 0) al++;
        verb = argv[1][0 .. al];
    }
    auto h = getenv("HOME\0".ptr);
    size_t hl = 0;
    if (h !is null) while (h[hl] != 0) hl++;
    final switch (verbOf(verb)) {
        case Verb.connect:
            return connectMain(h[0 .. hl]);
        case Verb.unknown:
            fputs(USAGE.ptr, stderr);
            return 2;
        case Verb.ask:
            return myceliaMain(h[0 .. hl], &press);
    }
}

enum USAGE = `usage: mycelia           ask the node, pass after pass
       mycelia connect   make your key, kept behind Touch ID, and sign it in to the node
` ~ "\0";
