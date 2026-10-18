module sha256_test;

import sha256 : Sha256;

// FIPS 180-2 appendix B: "abc", and the 448-bit message that pads into a second block.
unittest {
    char[64] got = 0;
    Sha256 s;
    s.put(cast(const(ubyte)[]) "abc");
    s.hexInto(got);
    assert(got[] == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");

    Sha256 t;
    t.put(cast(const(ubyte)[]) "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq");
    t.hexInto(got);
    assert(got[] == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
}
