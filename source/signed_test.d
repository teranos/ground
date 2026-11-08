module signed_test;

// "A signature proves the key, and nothing reusable leaves the node."

import signed;
import zbuf : ZBuf;

// The DID a seed is, as QNTX's access.EncodeDIDKey writes it for the same key.
unittest {
    ubyte[SEED_BYTES] zero;
    auto key = keyOf(zero[]);
    assert(key.held, "libsodium made no key of the zero seed");
    ZBuf did;
    putDID(did, key.public_[]);
    assert(did.slice() == "did:key:z6MkiTBz1ymuepAQ4HEHYSF1H8quG5GLVVQR3djdX3mDooWp", did.slice());
}

// base64url as RFC 4648 §5 writes it, with no padding.
unittest {
    ZBuf b;
    putBase64URL(b, cast(const(ubyte)[]) "f");
    assert(b.slice() == "Zg");
    b.reset();
    putBase64URL(b, cast(const(ubyte)[]) "fo");
    assert(b.slice() == "Zm8");
    b.reset();
    putBase64URL(b, cast(const(ubyte)[]) "foo");
    assert(b.slice() == "Zm9v");
    b.reset();
    putBase64URL(b, cast(const(ubyte)[]) "\xfb\xff");
    assert(b.slice() == "-_8");
}

// A node signs for its origin, and a path is not part of it.
unittest {
    assert(originOf("https://api.q.sbvh.nl/api/attestations") == "https://api.q.sbvh.nl");
    assert(originOf("http://127.0.0.1:8770") == "http://127.0.0.1:8770");
    assert(originOf("http://127.0.0.1:41234/mcp?x=1") == "http://127.0.0.1:41234");
}

// What is sent is the scheme and three parts, and the third is the key's
// signature over the first two.
unittest {
    ubyte[SEED_BYTES] zero;
    auto key = keyOf(zero[]);
    ubyte[JTI_BYTES] jti;
    foreach (i; 0 .. JTI_BYTES) jti[i] = cast(ubyte) i;
    ZBuf line;
    putSigned(line, "https://api.q.sbvh.nl/api/attestations", key, 1_800_000_000, jti[]);
    enum head = "Authorization: Signed ";
    auto all = line.slice();
    assert(all.length > head.length && all[0 .. head.length] == head, all);
    auto jwt = all[head.length .. $];
    size_t first = 0, second = 0, dots = 0;
    foreach (i, c; jwt) if (c == '.') { if (dots++ == 0) first = i; else second = i; }
    assert(dots == 2, jwt);

    // The claims, read back: who, for which node, until when, and its id.
    ZBuf claims;
    claims.put(`{"iss":"did:key:z6MkiTBz1ymuepAQ4HEHYSF1H8quG5GLVVQR3djdX3mDooWp","sub":"did:key:z6MkiTBz1ymuepAQ4HEHYSF1H8quG5GLVVQR3djdX3mDooWp","aud":"https://api.q.sbvh.nl","exp":1800000060,"jti":"000102030405060708090a0b0c0d0e0f"}`);
    ZBuf want;
    putBase64URL(want, cast(const(ubyte)[]) claims.slice());
    assert(jwt[first + 1 .. second] == want.slice(), jwt[first + 1 .. second]);

    // The signature verifies against the key's public half.
    ubyte[SIGNATURE_BYTES] sig;
    size_t got = 0;
    auto encoded = jwt[second + 1 .. $];
    uint acc = 0;
    int bits = 0;
    foreach (c; encoded) {
        int v = c >= 'A' && c <= 'Z' ? c - 'A' : c >= 'a' && c <= 'z' ? c - 'a' + 26 : c >= '0' && c <= '9' ? c - '0' + 52 : c == '-' ? 62 : 63;
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            sig[got++] = cast(ubyte)((acc >> bits) & 0xff);
        }
    }
    assert(got == SIGNATURE_BYTES);
    auto over = jwt[0 .. second];
    assert(crypto_sign_verify_detached(sig.ptr, cast(const(ubyte)*) over.ptr, over.length, key.public_.ptr) == 0,
        "the signature does not verify against the key");
}

// A token said goes as a bearer, as it always went; nothing said and no key
// kept is no line at all.
unittest {
    import core.sys.posix.stdlib : setenv;
    ZBuf line;
    authLine(line, "https://api.q.sbvh.nl", "qntx_abc\n");
    assert(line.slice() == "Authorization: Bearer qntx_abc", line.slice());
    setenv("HOME", "/nonexistent-ground-home\0".ptr, 1);
    authLine(line, "https://api.q.sbvh.nl", "");
    assert(line.slice().length == 0, line.slice());
}

// A key is made once, kept owner-only, and read back as the same key.
unittest {
    import core.stdc.stdio : snprintf;
    import core.sys.posix.unistd : getpid, unlink, rmdir;
    import core.sys.posix.sys.stat : stat_t, stat;
    char[256] dir = 0;
    snprintf(dir.ptr, dir.length, "/tmp/ground-key-%d\0", getpid());
    char[256] file = 0;
    snprintf(file.ptr, file.length, "/tmp/ground-key-%d/key\0", getpid());
    auto made = keepKey(file.ptr);
    assert(made.held, "no key was made");
    auto again = keepKey(file.ptr);
    assert(again.held && again.public_ == made.public_, "the key kept is not the key made");
    stat_t st;
    assert(stat(file.ptr, &st) == 0);
    assert((st.st_mode & 511) == 384, // 0777, 0600
           "the key is readable by others than its owner");
    unlink(file.ptr);
    rmdir(dir.ptr);
}
