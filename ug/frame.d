module frame;

// One repaint is one frame. The row is repainted about once a second and never
// on a schedule we set, so animating off the clock skips and stutters; the
// count of times the binary has run is the only steady step there is.

// Where the count is kept. A fresh process each repaint has nowhere else to
// remember it.
enum FRAME_FILE = "/tmp/ug.frame";

// The count a file holds, or zero when it holds nothing readable.
size_t parseFrame(const(char)[] text) {
    size_t v = 0;
    foreach (c; text) {
        if (c < '0' || c > '9') break;
        v = v * 10 + (c - '0');
    }
    return v;
}

// How many digits were written, and the digits themselves.
size_t formatFrame(size_t n, char[] dest) {
    char[20] tmp = void;
    size_t len = 0;
    do {
        tmp[len++] = cast(char)('0' + n % 10);
        n /= 10;
    } while (n > 0);

    if (len > dest.length) return 0;
    foreach (i; 0 .. len) dest[i] = tmp[len - 1 - i];
    return len;
}
