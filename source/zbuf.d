module zbuf;

struct ZBuf {
    char[4096] data = 0;
    size_t len;

    void put(const(char)[] s) {
        foreach (c; s)
            if (len + 1 < data.length) // reserve space for \0
                data[len++] = c;
        data[len] = '\0';
    }

    void putChar(char c) {
        if (len + 1 < data.length)
            data[len++] = c;
        data[len] = '\0';
    }

    void putUint(ulong v) {
        if (v == 0) { putChar('0'); return; }
        char[20] digits = 0;
        int n = 0;
        while (v > 0 && n < digits.length) { digits[n++] = cast(char)('0' + v % 10); v /= 10; }
        foreach_reverse (i; 0 .. n) putChar(digits[i]);
    }

    void reset() {
        len = 0;
        data[0] = '\0';
    }

    const(char)* ptr() {
        return &data[0];
    }

    const(char)[] slice() {
        return data[0 .. len];
    }
}
