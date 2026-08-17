module substitute;

// "the file that was being read, using any command, get's Read into claude as
// it tries to use one of the command line utilities set in the
// substitute_for_read parameter"

// A deny takes the method away and leaves the goal unmet, so the agent does
// neither and stops reading. This answers the goal: the command names a file,
// ground reads that file, and the contents arrive.

import zbuf : ZBuf;

enum MAX_TARGETS = 8;

// Enough for the windows people actually take. A file past it arrives cut,
// and says so rather than pretending it is whole.
enum MAX_HANDOVER = 60_000;

struct Targets {
    const(char)[][MAX_TARGETS] paths;
    size_t count;
}

private void add(ref Targets t, const(char)[] p) {
    if (t.count < MAX_TARGETS) t.paths[t.count++] = p;
}

// A path, or something that only looks like one. Flags are not paths, and
// neither is the script — `sed -n 185,320p file` leaves it unquoted, so the
// script is recognised by what it is rather than by its quoting.
private bool looksLikePath(const(char)[] w) {
    if (w.length == 0) return false;
    if (w[0] == '-') return false;
    if (w[0] == '\'' || w[0] == '"' || w[0] == '`') return false;

    bool sawDigit;
    bool onlyAddress = true;
    foreach (c; w) {
        if (c >= '0' && c <= '9') { sawDigit = true; continue; }
        if (c == ',' || c == ';' || c == '$') continue;
        if (c >= 'a' && c <= 'z') continue;
        onlyAddress = false;
        break;
    }
    if (sawDigit && onlyAddress) return false;

    return true;
}

// The whole word, not the letters. `elapsed` and `unused` contain "sed", and
// `sed_placeholder=1` starts with it — none of them run sed.
private bool isUtility(const(char)[] word, const(string)[] utils) {
    foreach (u; utils) if (word == u) return true;
    return false;
}

// Splits on whitespace, keeping a quoted run as one word so a script with
// spaces in it stays a single token.
private size_t nextWord(const(char)[] s, size_t from, out const(char)[] word) {
    auto i = from;
    while (i < s.length && (s[i] == ' ' || s[i] == '\t')) i++;
    if (i >= s.length) { word = ""; return s.length; }

    auto start = i;
    if (s[i] == '\'' || s[i] == '"') {
        auto q = s[i];
        i++;
        while (i < s.length && s[i] != q) i++;
        if (i < s.length) i++;
    } else {
        while (i < s.length && s[i] != ' ' && s[i] != '\t') i++;
    }
    word = s[start .. i];
    return i;
}

// The file itself, in a buffer the caller owns. A path that will not open is
// not an error here — the command would have failed too, and saying so is the
// command's job, not ground's.
bool handOver(ref ZBuf out_, const(char)[] path, const(char)[] baseDir) {
    import errors : open, read, close, O_RDONLY;

    __gshared ZBuf full;
    full.reset();
    if (path.length > 0 && path[0] != '/' && baseDir.length > 0) {
        full.put(baseDir);
        full.put("/");
    }
    full.put(path);

    auto fd = open(full.ptr(), O_RDONLY, 0);
    if (fd < 0) return false;

    out_.put("--- ");
    out_.put(full.slice());
    out_.put(" ---\n");

    __gshared char[8192] chunk;
    size_t total;
    for (;;) {
        auto n = read(fd, &chunk[0], chunk.length);
        if (n <= 0) break;
        auto got = cast(size_t) n;
        if (total + got > MAX_HANDOVER) {
            out_.put(chunk[0 .. MAX_HANDOVER - total]);
            out_.put("\n--- cut here: the file is longer than ground hands over ---\n");
            total = MAX_HANDOVER;
            break;
        }
        out_.put(chunk[0 .. got]);
        total += got;
    }
    close(fd);
    out_.put("\n");
    return true;
}

// Which files this command was going to read. Empty when it reads a pipe,
// when the utility is not one of ours, or when the read is on another machine.
Targets readTargets(const(char)[] cmd, const(string)[] utils) {
    Targets t;
    if (cmd.length == 0) return t;

    // A pipe means the input is the pipe. Anything feeding one of ours is the
    // producer, and `crowbar "sed …"` runs it on another machine.
    foreach (c; cmd) if (c == '|') return t;

    const(char)[] first;
    nextWord(cmd, 0, first);
    if (!isUtility(first, utils)) return t;

    size_t pos = 0;
    const(char)[] word;
    pos = nextWord(cmd, pos, word);

    for (;;) {
        pos = nextWord(cmd, pos, word);
        if (word.length == 0) break;

        // -e takes the script as its own argument, and a script is not a file.
        if (word == "-e" || word == "-f") {
            pos = nextWord(cmd, pos, word);
            continue;
        }
        if (looksLikePath(word)) t.add(word);
    }
    return t;
}
