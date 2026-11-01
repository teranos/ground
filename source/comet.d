module comet;

// "i want a coment per project essentially"

// "or like, a generalised project, like universal ground"

// The universal ground answers its own global controls; a repository with a comet
// landed for it is answered from that comet's sand, the engine held in ground (ADR-050).

import zbuf : ZBuf;

// "A comet is one sand for one user, one project and one platform."

// The platform as ground's flake names it: the one this ground was built for.
version (OSX) {
    version (AArch64) enum PLATFORM = "aarch64-darwin";
    version (X86_64) enum PLATFORM = "x86_64-darwin";
}
version (linux) {
    version (AArch64) enum PLATFORM = "aarch64-linux";
    version (X86_64) enum PLATFORM = "x86_64-linux";
}
static assert(is(typeof(PLATFORM)), "ground's flake names four platforms, and this is none of them");

// The file a comet is, as make sand names it.
version (OSX) enum SAND_FILE = "libground_sand.dylib";
else enum SAND_FILE = "libground_sand.so";

/// The node's comet of origin for this platform and this engine's ABI, into url.
void cometUrlInto(ref ZBuf url, const(char)[] node, const(char)[] origin) {
    import sand.view : SAND_ABI;
    url.reset();
    url.put(node);
    url.put("/comet/");
    url.put(origin);
    url.put("/");
    url.put(PLATFORM);
    url.put("/");
    url.putUint(SAND_ABI);
}

/// What a pass asking the node for this repository's comet came to.
enum Landed {
    none,    // the node keeps no comet for this repository on this platform
    same,    // the comet here is the one the node keeps
    landed,  // the node's comet is now the one here
    failed,  // why() says
}

struct Landing {
    Landed what;
    ZBuf said;
    const(char)[] why() return { return said.slice(); }
}

// "sky polls every five seconds"

// Asks the node for the digest of origin's comet on this platform. When it is not the one
// landed here, the comet is downloaded beside it, checked against that digest, and renamed over it.
Landing land(const(char)[] node, const(char)[] token, const(char)[] home, const(char)[] origin) {
    import core.stdc.stdio : fopen, fread, fwrite, fclose, rename;
    import http : httpGet, httpGetToFile;
    import errors : mkdir, unlink;
    import exec : chmod;
    import sha256 : Sha256;

    Landing r;
    __gshared char[1024] pathBuf = 0;
    auto path = cometPathInto(home, origin, pathBuf[]);
    if (path.length == 0) return r;

    __gshared ZBuf url;
    cometUrlInto(url, node, origin);
    auto bare = url.len;
    url.put("?digest");

    char[512] answer = 0;
    auto asked = httpGet(url.slice(), token, answer[]);
    if (asked.status == 404) return r;
    if (asked.status != 200) {
        r.what = Landed.failed;
        r.said.put("the node did not answer the digest of the comet of ");
        r.said.put(origin);
        if (asked.status > 0) {
            r.said.put(": HTTP ");
            r.said.putUint(cast(ulong) asked.status);
        }
        if (asked.whyLen > 0) {
            r.said.put(": ");
            r.said.put(asked.why());
        }
        return r;
    }
    auto want = digestOf(answer[0 .. asked.len]);
    if (want.length != 64) {
        r.what = Landed.failed;
        r.said.put("the node's answer names no digest: ");
        r.said.put(answer[0 .. asked.len]);
        return r;
    }

    __gshared ZBuf side;
    side.reset();
    side.put(path);
    side.put(".digest");
    char[64] here = 0;
    auto sf = fopen(side.ptr(), "rb");
    if (sf !is null) {
        auto n = fread(here.ptr, 1, here.length, sf);
        fclose(sf);
        if (n == 64 && here[] == want) {
            r.what = Landed.same;
            return r;
        }
    }

    // Every directory down to the comet's own; one that stands already is the one wanted.
    foreach (i, c; path) {
        if (i > home.length && c == '/') {
            pathBuf[i] = 0;
            cast(void) mkdir(pathBuf.ptr, 493); // 0755
            pathBuf[i] = '/';
        }
    }

    __gshared ZBuf staged;
    staged.reset();
    staged.put(path);
    staged.put(".new");
    auto got = httpGetToFile(url.data[0 .. bare], token, staged.ptr(), 600);
    if (got.code != 0 || got.status != 200) {
        cast(void) unlink(staged.ptr());
        r.what = Landed.failed;
        r.said.put("the comet of ");
        r.said.put(origin);
        r.said.put(" did not download");
        if (got.status > 0) {
            r.said.put(": HTTP ");
            r.said.putUint(cast(ulong) got.status);
        }
        if (got.whyLen > 0) {
            r.said.put(": ");
            r.said.put(got.why());
        }
        return r;
    }

    // The bytes are the ones the node said it built, or nothing lands.
    Sha256 sum;
    auto bf = fopen(staged.ptr(), "rb");
    if (bf is null) {
        r.what = Landed.failed;
        r.said.put("the downloaded comet would not open to be checked: ");
        r.said.put(staged.slice());
        return r;
    }
    __gshared ubyte[65536] chunk;
    while (true) {
        auto n = fread(chunk.ptr, 1, chunk.length, bf);
        if (n == 0) break;
        sum.put(chunk[0 .. n]);
    }
    fclose(bf);
    char[64] have = 0;
    sum.hexInto(have);
    if (have[] != want) {
        cast(void) unlink(staged.ptr());
        r.what = Landed.failed;
        r.said.put("the comet of ");
        r.said.put(origin);
        r.said.put(" downloaded as ");
        r.said.put(have[]);
        r.said.put(", not the ");
        r.said.put(want);
        r.said.put(" the node answered");
        return r;
    }

    if (chmod(staged.ptr(), 420) != 0) { // 0644: a sand is loaded, never run
        r.what = Landed.failed;
        r.said.put("the downloaded comet could not be made readable: ");
        r.said.put(staged.slice());
        return r;
    }

    // "`codesign -s -` runs on the machine that lands it."

    version (OSX) {
        const(char)*[4] argv = ["/usr/bin/codesign".ptr, "-s".ptr, "-".ptr, "-f".ptr];
        auto signed = runQuiet(argv[], staged.ptr());
        if (signed != 0) {
            r.what = Landed.failed;
            r.said.put("codesign -s - refused the comet of ");
            r.said.put(origin);
            r.said.put(", exit ");
            r.said.putUint(cast(ulong) signed);
            return r;
        }
    }
    // Renamed over the one running, never copied onto it.
    if (rename(staged.ptr(), pathBuf.ptr) != 0) {
        r.what = Landed.failed;
        r.said.put("the comet would not rename into place at ");
        r.said.put(path);
        return r;
    }
    __gshared ZBuf sideNew;
    sideNew.reset();
    sideNew.put(side.slice());
    sideNew.put(".new");
    auto df = fopen(sideNew.ptr(), "wb");
    if (df is null) {
        r.what = Landed.failed;
        r.said.put("the comet landed, and its digest would not be written beside it: ");
        r.said.put(sideNew.slice());
        return r;
    }
    auto wrote = fwrite(want.ptr, 1, want.length, df);
    fclose(df);
    if (wrote != want.length || rename(sideNew.ptr(), side.ptr()) != 0) {
        r.what = Landed.failed;
        r.said.put("the comet landed, and its digest did not land beside it: ");
        r.said.put(side.slice());
        return r;
    }
    r.what = Landed.landed;
    r.said.put("the comet of ");
    r.said.put(origin);
    r.said.put(" landed: ");
    r.said.put(want);
    return r;
}

/// The 64 hex characters of the digest key in the node's answer, or empty when it names none.
const(char)[] digestOf(const(char)[] answer) {
    enum key = "\"digest\":\"";
    if (answer.length < key.length + 64) return answer[0 .. 0];
    foreach (i; 0 .. answer.length - key.length - 64 + 1) {
        if (answer[i .. i + key.length] != key) continue;
        auto d = answer[i + key.length .. i + key.length + 64];
        foreach (c; d) {
            auto hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
            if (!hex) return answer[0 .. 0];
        }
        return d;
    }
    return answer[0 .. 0];
}

/// Runs args then last, with ground's stdin, and answers the exit code; one that could not start answers 127.
private int runQuiet(const(char)*[] args, const(char)* last) {
    import exec : fork, execv, _exit, waitpid;
    __gshared const(char)*[8] argv;
    foreach (i, a; args) argv[i] = a;
    argv[args.length] = last;
    argv[args.length + 1] = null;
    auto pid = fork();
    if (pid < 0) return 127;
    if (pid == 0) {
        execv(argv[0], argv.ptr);
        _exit(127);
    }
    int status;
    waitpid(pid, &status, 0);
    if ((status & 0x7f) != 0) return 128 + (status & 0x7f);
    return (status >> 8) & 0xff;
}

/// Where this machine's own sand is installed by make install: ~/.local/share/ground/sand/SAND_FILE.
const(char)[] localSandPathInto(const(char)[] home, char[] buf) {
    enum rest = "/.local/share/ground/sand/" ~ SAND_FILE;
    if (home.length == 0 || home.length + rest.length >= buf.length) return buf[0 .. 0];
    size_t n = 0;
    foreach (c; home) buf[n++] = c;
    foreach (c; rest) buf[n++] = c;
    buf[n] = 0;
    return buf[0 .. n];
}

/// Where a repository's comet lands: ~/.local/share/ground/comets/<owner>/<repo>/SAND_FILE.
/// Empty for no origin: a repository with no name has no comet.
const(char)[] cometPathInto(const(char)[] home, const(char)[] origin, char[] buf) {
    enum middle = "/.local/share/ground/comets/";
    enum tail = "/" ~ SAND_FILE;
    if (origin.length == 0 || home.length == 0) return buf[0 .. 0];
    auto need = home.length + middle.length + origin.length + tail.length;
    if (need >= buf.length) return buf[0 .. 0];
    size_t n = 0;
    foreach (s; [home, middle, origin, tail]) {
        foreach (c; s) buf[n++] = c;
    }
    buf[n] = 0;
    return buf[0 .. n];
}
