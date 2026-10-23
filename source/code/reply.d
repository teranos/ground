module code.reply;

import core.stdc.stdlib : realloc, free;
import core.stdc.string : memcpy;

struct Reply {
    char[4096] data = 0;
    size_t len;
    bool full; // an answer that did not fit; said, never sent cut short
    char* heap;
    size_t heapCapacity;

    void add(const(char)[] s) {
        if (full) return;
        if (s.length > size_t.max - len) { full = true; return; }
        if (heap !is null || len + s.length > data.length) {
            if (__ctfe) { full = true; return; }
            else {
                auto needed = len + s.length;
                if (needed > heapCapacity) {
                    auto capacity = needed > size_t.max / 2 ? needed : needed * 2;
                    auto next = cast(char*) realloc(heap, capacity);
                    if (next is null) { full = true; return; }
                    if (heap is null) memcpy(next, data.ptr, len);
                    heap = next; heapCapacity = capacity;
                }
                memcpy(heap + len, s.ptr, s.length); len += s.length;
            }
        } else foreach (c; s) data[len++] = c;
    }
    const(char)[] slice() const return { return heap is null ? data[0 .. len] : heap[0 .. len]; }
    void dispose() { if (!__ctfe) free(heap); heap = null; heapCapacity = 0; len = 0; }
}

// A string's JSON form, control characters included, without its quotes.
void putEscaped(ref Reply r, const(char)[] s) {
    enum hex = "0123456789abcdef";
    foreach (i, c; s) {
        if (c == '"' || c == '\\') { r.add("\\"); r.add(s[i .. i + 1]); }
        else if (c == '\n') r.add("\\n");
        else if (c == '\t') r.add("\\t");
        else if (c == '\r') r.add("\\r");
        else if (c < 0x20) { char[6] u = ['\\', 'u', '0', '0', hex[c >> 4], hex[c & 15]]; r.add(u[]); }
        else r.add(s[i .. i + 1]);
    }
}

void putNumber(ref Reply r, ulong u) {
    char[24] d;
    size_t k = d.length;
    do { d[--k] = cast(char)('0' + u % 10); u /= 10; } while (u > 0);
    r.add(d[k .. $]);
}
