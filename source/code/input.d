module code.input;

// ACP's input, a line at a time, read by ground code itself rather than
// through stdio: a turn looks at what has arrived while it runs and takes the
// cancel meant for it out of line, and every other line is still answered
// after the turn, in the order it came.

import core.stdc.stdlib : realloc, free;
import core.stdc.string : memmove, memcpy;
import core.stdc.errno : errno, EINTR, EAGAIN;
import core.sys.posix.unistd : read;
import exec : pollfd, poll, POLLIN; // the one declaration of poll the binary has

struct Input {
    int fd;
    char* buf;      // what has arrived and is not yet taken
    size_t len, cap;
    char* cur;      // the line nextLine last gave, its own copy
    size_t curCap;
    bool eof, failed;
    void dispose() {
        free(buf); free(cur);
        buf = cur = null;
        len = cap = curCap = 0;
    }
}

// Reads what the fd has, waiting up to waitMs, or forever at -1. false when
// nothing came: the wait ran out, the input ended, or it failed. Forever is a
// blocking read, not a poll: Darwin's poll never reports a FIFO's end.
private bool fill(ref Input input, int waitMs) {
    if (input.eof || input.failed) return false;
    if (waitMs >= 0) {
        pollfd p = pollfd(input.fd, POLLIN, 0);
        auto ready = poll(&p, 1, waitMs);
        if (ready < 0) { if (errno != EINTR) input.failed = true; return false; }
        if (ready == 0) return false;
    }
    if (input.cap - input.len < 4096) {
        auto grown = input.cap == 0 ? 65536 : input.cap * 2;
        auto b = cast(char*) realloc(input.buf, grown);
        if (b is null) { input.failed = true; return false; }
        input.buf = b;
        input.cap = grown;
    }
    auto n = read(input.fd, input.buf + input.len, input.cap - input.len);
    if (n < 0) { if (errno != EINTR && errno != EAGAIN) input.failed = true; return false; }
    if (n == 0) { input.eof = true; return false; }
    input.len += cast(size_t) n;
    return true;
}

private ptrdiff_t newlineIn(ref const Input input, size_t from) {
    foreach (i; from .. input.len) if (input.buf[i] == '\n') return cast(ptrdiff_t) i;
    return -1;
}

// Drops the bytes from..to, keeping what follows in order.
private void cut(ref Input input, size_t from, size_t to) {
    memmove(input.buf + from, input.buf + to, input.len - to);
    input.len -= to - from;
}

// The next line, without its newline, waiting for it. A last line the input
// ends without a newline is still a line. false at the end of the input, and
// when it failed (input.failed). The line is good until the next call.
bool nextLine(ref Input input, ref const(char)[] line) {
    while (true) {
        auto nl = newlineIn(input, 0);
        size_t end = nl >= 0 ? cast(size_t) nl : input.len;
        if (nl >= 0 || ((input.eof || input.failed) && input.len > 0)) {
            if (end > input.curCap) {
                auto c = cast(char*) realloc(input.cur, end);
                if (c is null) { input.failed = true; return false; }
                input.cur = c;
                input.curCap = end;
            }
            if (end > 0) memcpy(input.cur, input.buf, end);
            cut(input, 0, nl >= 0 ? end + 1 : end);
            line = input.cur[0 .. end];
            return true;
        }
        if (input.eof || input.failed) return false;
        fill(input, -1);
    }
}

// Takes out of line the first whole line that has arrived and matches, without
// waiting for more. true when one did.
bool take(ref Input input, scope bool delegate(const(char)[]) matches) {
    while (fill(input, 0)) {}
    size_t start = 0;
    while (true) {
        auto nl = newlineIn(input, start);
        if (nl < 0) return false;
        if (matches(input.buf[start .. cast(size_t) nl])) {
            cut(input, start, cast(size_t) nl + 1);
            return true;
        }
        start = cast(size_t) nl + 1;
    }
}

// Waits for more to arrive. false at the end of the input, or when it failed:
// nothing more is coming.
bool more(ref Input input) {
    fill(input, -1);
    return !input.eof && !input.failed;
}
