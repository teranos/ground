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

// What the engine was built from, as wind stamped it (tools/wind.d stampVersion): its version, and
// HEAD's whole id beside it, empty where the tree was no repository.
enum VERSION = import(".version");
enum REV = import(".rev");

// "1. the 2nd"
/// The ground revision a version names: git describe's commit after -g, a tag or a commit alone,
/// or the one after "comet" in a comet's version. Empty for none, and for what a URL would read as
/// more than a revision.
const(char)[] groundRevOf(const(char)[] version_) {
    size_t end = 0;
    while (end < version_.length && version_[end] != '\n' && version_[end] != ' ') end++;
    auto word = version_[0 .. end];
    if (word == "comet" && end < version_.length && version_[end] == ' ') {
        auto rest = version_[end + 1 .. $];
        size_t e = 0;
        while (e < rest.length && rest[e] != '\n' && rest[e] != ' ') e++;
        word = rest[0 .. e];
    } else if (end < version_.length && version_[end] == ' ') return version_[0 .. 0];
    foreach (c; word) {
        auto ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || c == '.' || c == '_' || c == '-';
        if (!ok) return version_[0 .. 0];
    }
    // v0.19.1-880-g23a58f7: the commit is what follows the last -g, when only hex follows it.
    foreach_reverse (i; 0 .. word.length) {
        if (word[i] != '-') continue;
        if (i + 2 < word.length && word[i + 1] == 'g') {
            auto hex = word[i + 2 .. $];
            bool all = true;
            foreach (c; hex) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) all = false;
            if (all) return hex;
        }
        break;
    }
    return word;
}

// A commit's whole id, 40 hex, as wind stamps it with a newline; empty for anything else.
private const(char)[] wholeId(const(char)[] stamped) {
    if (stamped.length > 0 && stamped[$ - 1] == '\n') stamped = stamped[0 .. $ - 1];
    if (stamped.length != 40) return stamped[0 .. 0];
    foreach (c; stamped) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return stamped[0 .. 0];
    return stamped;
}

/// The ask for the digest of origin's comet, into url: the comet's url, and the ground this
/// engine was built from: the commit wind stamped when it is a whole id, else what the version names.
void cometAskInto(ref ZBuf url, const(char)[] node, const(char)[] origin, const(char)[] version_,
                  const(char)[] stamped) {
    cometUrlInto(url, node, origin);
    url.put("?digest");
    auto rev = wholeId(stamped);
    if (rev.length == 0) rev = groundRevOf(version_);
    if (rev.length == 0) return;
    url.put("&ground=");
    url.put(rev);
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
    cometAskInto(url, node, origin, VERSION, REV);

    __gshared char[ANSWER_BYTES] answer = 0;
    auto asked = httpGet(url.slice(), token, answer[]);
    if (asked.status == 404) {
        import core.sys.posix.unistd : access, F_OK;
        notKept(r, origin, access(pathBuf.ptr, F_OK) == 0, answer[0 .. asked.len], asked.overran,
                asked.code != 0 ? asked.why() : null);
        return r;
    }
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

/// 「[Opus 5.5] What land() reads of the node's answer to the ask for a digest.」
enum ANSWER_BYTES = 2048;

// "thats problematic seeing how sand chamges are normal"
/// 「[Opus 5.5] The node keeps no comet of origin for this engine's ABI. With none held here the repository」
/// 「[Opus 5.5] has none, and nothing is said; with one held here, that one is what every hook refuses, and」
/// 「[Opus 5.5] the node's answer says which ABIs it keeps. An answer larger than ANSWER_BYTES is said to be;」
/// 「[Opus 5.5] a 404 whose transfer broke, broke says how, and what came of it is not the node's answer.」
void notKept(ref Landing r, const(char)[] origin, bool heldHere, const(char)[] answer, bool overran,
             const(char)[] broke) {
    import sand.view : SAND_ABI;
    if (!heldHere) return;
    r.what = Landed.failed;
    r.said.put("the node keeps no comet of ");
    r.said.put(origin);
    r.said.put(" for engine ABI ");
    r.said.putUint(SAND_ABI);
    r.said.put(", and one is held here: ");
    if (overran) {
        r.said.put("the node's answer was larger than the ");
        r.said.putUint(ANSWER_BYTES);
        r.said.put(" bytes ground reads of it");
        return;
    }
    if (broke.length > 0) {
        r.said.put("the node's answer did not arrive whole: ");
        r.said.put(broke);
        return;
    }
    r.said.put(answer);
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
