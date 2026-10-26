module scrubcmd;

// ground scrub: stdin with fixtures in place of what names a person, on stdout,
// and what was found on stderr. The node runs it over what it is handed, so one
// scanner (pii.d) answers for every door. Exit 3 when stdin is more than ground reads.

import core.stdc.stdio : stdin, stdout, stderr, fread, fwrite, fputs;

int handleScrub() {
    import pii : scrub, said;
    import control_handlers : fixtureMail;

    __gshared char[4194304] held = 0;
    __gshared char[4194304] out_ = 0;
    size_t n;
    while (n < held.length) {
        auto got = fread(&held[n], 1, held.length - n, stdin);
        if (got == 0) break;
        n += got;
    }
    if (n == held.length) {
        fputs("ground scrub: more than ground reads (4 MiB); nothing written\n", stderr);
        return 3;
    }
    auto r = scrub(held[0 .. n], out_[], fixtureMail());
    if (!r.fit) {
        fputs("ground scrub: the fixtures would not fit; nothing written\n", stderr);
        return 3;
    }
    fwrite(out_.ptr, 1, r.len, stdout);
    if (r.found > 0) {
        char[256] line = 0;
        auto len = said(r, line[]);
        fputs("ground scrub: ", stderr);
        fwrite(line.ptr, 1, len, stderr);
        fputs("\n", stderr);
    }
    return 0;
}
