module clock;

// The first segment collet draws, byte for byte: a green clock in brackets.
// From captures/grove/out.bytes, offset 0.

enum GREEN = "\033[32m";
enum RESET = "\033[0m";

// Two digits, always, because a row that changes width every ten minutes
// moves everything to the right of it.
size_t clockInto(int hour, int minute, char[] dest) {
    size_t o = 0;

    void put(const(char)[] s) {
        foreach (c; s) if (o < dest.length) dest[o++] = c;
    }

    void two(int v) {
        if (o + 1 >= dest.length) return;
        dest[o++] = cast(char)('0' + (v / 10) % 10);
        dest[o++] = cast(char)('0' + v % 10);
    }

    put(GREEN);
    put("[");
    two(hour);
    put(":");
    two(minute);
    put("]");
    put(RESET);
    return o;
}
