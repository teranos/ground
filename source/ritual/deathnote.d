module ritual.deathnote;

// A driver ended by a signal it can catch writes which one to a file named by
// its pid, and the sweep that finds it gone reads the file. SIGKILL cannot be
// caught, so a driver it ends is still gone without a word.

const(char)[] signalName(int sig) @nogc nothrow {
    switch (sig) {
        case 1:  return "SIGHUP";
        case 2:  return "SIGINT";
        case 3:  return "SIGQUIT";
        case 15: return "SIGTERM";
        default: return "";
    }
}

// The note is the number and a newline: written from a signal handler, which
// may call nothing that allocates or locks.
size_t deathNoteInto(int sig, char[] dest) @nogc nothrow {
    char[12] d = 0;
    size_t n;
    int v = sig < 0 ? 0 : sig;
    do { d[n++] = cast(char)('0' + v % 10); v /= 10; } while (v > 0 && n < d.length);
    size_t o;
    foreach_reverse (i; 0 .. n) { if (o >= dest.length) return o; dest[o++] = d[i]; }
    if (o < dest.length) dest[o++] = '\n';
    return o;
}

int signalIn(const(char)[] note) @nogc nothrow {
    int v;
    size_t i;
    while (i < note.length && note[i] >= '0' && note[i] <= '9') { v = v * 10 + (note[i] - '0'); i++; }
    return i == 0 ? 0 : v;
}

private __gshared char[512] notePath = 0;

// ~/.local/share/ground/drive-<pid>.died, zero-terminated into dest.
// Built once at start: the handler only reads what this wrote.
private size_t notePathInto(long pid, ref char[512] dest) {
    import sky : buildGroundPath;
    char[24] digits = 0;
    size_t n;
    long v = pid < 0 ? 0 : pid;
    do { digits[n++] = cast(char)('0' + v % 10); v /= 10; } while (v > 0 && n < digits.length);
    char[24] key = 0;
    foreach (i; 0 .. n) key[i] = digits[n - 1 - i];
    return buildGroundPath(dest, "drive-", key[0 .. n], ".died");
}

private extern (C) void writeDeathNote(int sig) nothrow @nogc {
    import core.sys.posix.fcntl : open, O_WRONLY, O_CREAT, O_TRUNC;
    import core.sys.posix.unistd : write, close, _exit;
    char[16] b = 0;
    auto n = deathNoteInto(sig, b[]);
    auto fd = open(&notePath[0], O_WRONLY | O_CREAT | O_TRUNC, 420); // 0644
    if (fd >= 0) {
        cast(void) write(fd, &b[0], n);
        close(fd);
    }
    _exit(128 + sig);
}

// From the driver, once, as it starts.
void armDeathNote(long pid) {
    import core.sys.posix.signal : sigaction, sigaction_t, sigemptyset, signal,
                                   SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGPIPE, SIG_IGN;
    if (notePathInto(pid, notePath) == 0) return;
    sigaction_t act;
    act.sa_handler = &writeDeathNote;
    sigemptyset(&act.sa_mask);
    foreach (sig; [SIGHUP, SIGINT, SIGQUIT, SIGTERM]) sigaction(sig, &act, null);
    // A reader that is gone is an error on the write, not the end of the driver.
    signal(SIGPIPE, SIG_IGN);
}

// The signal a gone driver noted, or 0. Read once: the note is removed.
int readDeathNote(long pid) {
    import core.stdc.stdio : fopen, fread, fclose, remove;
    __gshared char[512] path = 0;
    if (notePathInto(pid, path) == 0) return 0;
    auto f = fopen(&path[0], "r");
    if (f is null) return 0;
    char[16] b = 0;
    auto n = fread(&b[0], 1, b.length, f);
    fclose(f);
    remove(&path[0]);
    return signalIn(b[0 .. n]);
}
