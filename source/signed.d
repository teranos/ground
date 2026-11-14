module signed;

// "A signature proves the key, and nothing reusable leaves the node."
//
// "Tokens are to be removed from QNTX except for third-party OAuth clients"
//
// Ground speaks to its node as a key of its own: an ed25519 seed kept in
// ~/.qntx/key, named by its did:key, which the node knows from the sign-in the
// person said yes to (QNTX server/auth/device.go). Each request carries a JWT
// signed for that one request and that one node (QNTX server/auth/signed.go):
// what crosses the wire is spent once, and the key never does.

import zbuf : ZBuf;

extern (C) nothrow @nogc {
    int sodium_init();
    int crypto_sign_seed_keypair(ubyte* pk, ubyte* sk, const(ubyte)* seed);
    int crypto_sign_detached(ubyte* sig, ulong* siglen, const(ubyte)* m, ulong mlen, const(ubyte)* sk);
    int crypto_sign_verify_detached(const(ubyte)* sig, const(ubyte)* m, ulong mlen, const(ubyte)* pk);
    void randombytes_buf(void* buf, size_t size);
    // mkdirat, which nothing else in ground or ug declares: mkdir is declared twice over, with
    // Darwin's 16-bit mode_t by druntime and as uint by db, and a binary links one of them.
    int mkdirat(int fd, const(char)* path, uint mode);
}

// The directory a relative path is made in: the working one (fcntl.h's AT_FDCWD).
version (OSX) private enum AT_FDCWD = -2;
else private enum AT_FDCWD = -100;

enum SEED_BYTES = 32;
enum PUBLIC_BYTES = 32;
enum SECRET_BYTES = 64;
enum SIGNATURE_BYTES = 64;
// QNTX's assertionIDBytes: a jti is sixteen random bytes, in hex.
enum JTI_BYTES = 16;
// How long a signature lasts: long enough to reach the node, well inside the
// five minutes the node allows one (assertionMaxLife).
enum SIGNED_LIFE_SECONDS = 60;
// The scheme the node reads a signature under (QNTX signedScheme).
enum SCHEME = "Signed ";

// A key: its seed, the secret libsodium signs with, its public half.
struct Key {
    ubyte[SECRET_BYTES] secret;
    ubyte[PUBLIC_BYTES] public_;
    bool held;
}

// The key a seed is: what libsodium derives, as QNTX's ed25519.NewKeyFromSeed does.
Key keyOf(const(ubyte)[] seed) {
    Key k;
    if (seed.length != SEED_BYTES) return k;
    if (sodium_init() < 0) return k;
    if (crypto_sign_seed_keypair(k.public_.ptr, k.secret.ptr, seed.ptr) != 0) return k;
    k.held = true;
    return k;
}

private enum B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

// The did:key a public key is: did:key:z, then base58btc of the ed25519
// multicodec (0xed 0x01) and the key, as QNTX's access.EncodeDIDKey writes it.
void putDID(ref ZBuf out_, const(ubyte)[] public_) {
    ubyte[2 + PUBLIC_BYTES] raw;
    raw[0] = 0xed;
    raw[1] = 0x01;
    foreach (i, b; public_[0 .. PUBLIC_BYTES]) raw[2 + i] = b;
    // Base58 by long division of the bytes as one big-endian number.
    ubyte[64] digits;
    size_t n = 0;
    foreach (b; raw) {
        uint carry = b;
        foreach (j; 0 .. n) {
            carry += cast(uint) digits[j] << 8;
            digits[j] = cast(ubyte)(carry % 58);
            carry /= 58;
        }
        while (carry > 0) {
            digits[n++] = cast(ubyte)(carry % 58);
            carry /= 58;
        }
    }
    out_.put("did:key:z");
    foreach (b; raw) {
        if (b != 0) break;
        out_.putChar('1');
    }
    foreach_reverse (j; 0 .. n) out_.putChar(B58[digits[j]]);
}

private enum B64URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

// base64url without padding, as a JWT writes each of its parts (RFC 7515 §2).
void putBase64URL(ref ZBuf out_, const(ubyte)[] bytes) {
    size_t i = 0;
    while (i + 3 <= bytes.length) {
        uint v = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
        out_.putChar(B64URL[(v >> 18) & 63]);
        out_.putChar(B64URL[(v >> 12) & 63]);
        out_.putChar(B64URL[(v >> 6) & 63]);
        out_.putChar(B64URL[v & 63]);
        i += 3;
    }
    auto rest = bytes.length - i;
    if (rest == 1) {
        uint v = bytes[i] << 16;
        out_.putChar(B64URL[(v >> 18) & 63]);
        out_.putChar(B64URL[(v >> 12) & 63]);
    } else if (rest == 2) {
        uint v = (bytes[i] << 16) | (bytes[i + 1] << 8);
        out_.putChar(B64URL[(v >> 18) & 63]);
        out_.putChar(B64URL[(v >> 12) & 63]);
        out_.putChar(B64URL[(v >> 6) & 63]);
    }
}

// The origin a URL is reached at: its scheme and host, the port if it names
// one, nothing after. A node signs for its public origin (QNTX publicOrigin).
const(char)[] originOf(const(char)[] url) {
    size_t at = 0;
    while (at + 2 < url.length && !(url[at] == ':' && url[at + 1] == '/' && url[at + 2] == '/')) at++;
    if (at + 2 >= url.length) return url;
    size_t end = at + 3;
    while (end < url.length && url[end] != '/' && url[end] != '?' && url[end] != '#') end++;
    return url[0 .. end];
}

// The Authorization line a request to url goes with, signed by key at now
// (seconds since the epoch), with jti as its id: the scheme, a header, the
// claims, and the signature over both.
void putSigned(ref ZBuf out_, const(char)[] url, ref const Key key, long now, const(ubyte)[] jti) {
    __gshared ZBuf did, claims, signing;
    did.reset();
    putDID(did, key.public_[]);

    claims.reset();
    claims.put(`{"iss":"`);
    claims.put(did.slice());
    claims.put(`","sub":"`);
    claims.put(did.slice());
    claims.put(`","aud":"`);
    claims.put(originOf(url));
    claims.put(`","exp":`);
    claims.putUint(cast(ulong)(now + SIGNED_LIFE_SECONDS));
    claims.put(`,"jti":"`);
    enum hex = "0123456789abcdef";
    foreach (b; jti) {
        claims.putChar(hex[b >> 4]);
        claims.putChar(hex[b & 15]);
    }
    claims.put(`"}`);

    signing.reset();
    putBase64URL(signing, cast(const(ubyte)[]) `{"alg":"EdDSA","typ":"JWT"}`);
    signing.putChar('.');
    putBase64URL(signing, cast(const(ubyte)[]) claims.slice());

    ubyte[SIGNATURE_BYTES] sig;
    ulong sigLen;
    auto signed_ = signing.slice();
    crypto_sign_detached(sig.ptr, &sigLen, cast(const(ubyte)*) signed_.ptr, signed_.length, key.secret.ptr);

    out_.put("Authorization: ");
    out_.put(SCHEME);
    out_.put(signed_);
    out_.putChar('.');
    putBase64URL(out_, sig[0 .. cast(size_t) sigLen]);
}

// The file ground's key is kept in: ~/.qntx/key, beside the token every
// ground used to read. Null when there is no home.
const(char)* keyFile() {
    import core.stdc.stdlib : getenv;
    __gshared ZBuf path;
    path.reset();
    auto home = getenv("HOME\0".ptr);
    if (home is null) return null;
    size_t n = 0;
    while (home[n] != 0) n++;
    path.put(home[0 .. n]);
    path.put("/.qntx/key");
    return path.ptr();
}

private int nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// The key kept in file: a seed, sixty-four hex characters. Not held when there
// is no file, what is in it is no seed, or it is not its owner's alone: a
// link, not a regular file, someone else's, or readable by anyone else.
Key keptKey(const(char)* file) {
    import core.sys.posix.fcntl : open, O_RDONLY, O_NOFOLLOW;
    import core.sys.posix.unistd : read, close, geteuid;
    import core.sys.posix.sys.stat : stat_t, fstat, S_IFMT, S_IFREG;
    Key none;
    if (file is null) return none;
    auto fd = open(file, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return none;
    stat_t st;
    if (fstat(fd, &st) != 0 || (st.st_mode & S_IFMT) != S_IFREG
        || st.st_uid != geteuid() || (st.st_mode & 0x3f) != 0) { // 077: group and others
        close(fd);
        return none;
    }
    char[2 * SEED_BYTES + 2] text = 0;
    auto n = read(fd, text.ptr, text.length);
    close(fd);
    if (n < 2 * SEED_BYTES) return none;
    ubyte[SEED_BYTES] seed;
    foreach (i; 0 .. SEED_BYTES) {
        auto hi = nibble(text[2 * i]), lo = nibble(text[2 * i + 1]);
        if (hi < 0 || lo < 0) return none;
        seed[i] = cast(ubyte)((hi << 4) | lo);
    }
    return keyOf(seed[]);
}

// The key in file, made and kept there first when there is none: a seed of
// random bytes, written readable by its owner alone.
Key keepKey(const(char)* file) {
    auto held = keptKey(file);
    if (held.held || file is null) return held;
    import core.sys.posix.fcntl : open, O_WRONLY, O_CREAT, O_EXCL;
    import core.sys.posix.unistd : write, close;
    if (sodium_init() < 0) return held;
    ubyte[SEED_BYTES] seed;
    randombytes_buf(seed.ptr, seed.length);
    // Every directory on the way, as mkdir -p makes them, each its owner's alone.
    __gshared ZBuf dir;
    dir.reset();
    size_t n = 0;
    while (file[n] != 0) n++;
    auto path = file[0 .. n];
    size_t slash = path.length;
    while (slash > 0 && path[slash - 1] != '/') slash--;
    if (slash > 1) {
        dir.put(path[0 .. slash - 1]);
        auto d = cast(char*) dir.ptr();
        foreach (i; 1 .. dir.len + 1) {
            if (d[i] != '/' && d[i] != 0) continue;
            auto was = d[i];
            d[i] = 0;
            mkdirat(AT_FDCWD, d, 448); // 0700
            d[i] = was;
            if (was == 0) break;
        }
    }
    auto fd = open(file, O_WRONLY | O_CREAT | O_EXCL, 384); // 0600
    if (fd < 0) return held;
    enum hex = "0123456789abcdef";
    char[2 * SEED_BYTES + 1] text;
    foreach (i, b; seed) {
        text[2 * i] = hex[b >> 4];
        text[2 * i + 1] = hex[b & 15];
    }
    text[2 * SEED_BYTES] = '\n';
    auto wrote = write(fd, text.ptr, text.length);
    auto closed = close(fd);
    if (wrote != text.length || closed != 0) {
        // A seed half written is no key, and O_EXCL would keep the next sign-in
        // from making one: what this attempt made goes.
        import core.sys.posix.unistd : unlink;
        unlink(file);
        return held;
    }
    return keyOf(seed[]);
}

// The Authorization line for a request to url. To a node (signs), a signature
// by the key kept in ~/.qntx/key, and nothing when no key is kept. Anywhere
// else, the far end's own token as a bearer, or nothing. An absent line is an
// absent header.
void authLine(ref ZBuf line, const(char)[] url, const(char)[] token, bool signs, const(char)* keyAt = null) {
    import token : trimToken;
    line.reset();
    if (!signs) {
        auto tok = trimToken(token);
        if (tok.length == 0) return;
        line.put("Authorization: Bearer ");
        line.put(tok);
        return;
    }
    auto key = keptKey(keyAt is null ? keyFile() : keyAt);
    if (!key.held) return;
    import core.stdc.time : time;
    ubyte[JTI_BYTES] jti;
    randombytes_buf(jti.ptr, jti.length);
    putSigned(line, url, key, cast(long) time(null), jti[]);
}
