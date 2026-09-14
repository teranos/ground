module fmtcmd;

// ground fmt: a .pbt is rewritten whole; a .d has every backtick fixture that
// is pbt rewritten in place and nothing else touched; no path reads stdin and
// writes stdout. The file is written only when fmt would change it.

import fmt : formatInto;
import core.stdc.stdio : FILE, fopen, fclose, fread, fwrite, fputs, stdin, stdout, stderr;

private enum CAP = 262144;

private size_t argLen(const(char)* p) {
    size_t n = 0;
    while (p[n] != 0) n++;
    return n;
}

private const(char)[] readWhole(FILE* f, char[] buf) {
    size_t total = 0;
    while (total < buf.length) {
        auto n = fread(&buf[total], 1, buf.length - total, f);
        if (n == 0) break;
        total += n;
    }
    return buf[0 .. total];
}

private bool startsWith(const(char)[] s, const(char)[] p) {
    return s.length >= p.length && s[0 .. p.length] == p;
}

private bool isWs(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

// A backtick literal is pbt when it opens on a block word and carries a
// brace, or is an include. A word in a comment's backticks is not.
private bool looksPbt(const(char)[] body_) {
    size_t i = 0;
    while (i < body_.length && isWs(body_[i])) i++;
    auto s = body_[i .. $];
    static immutable string[7] heads = ["scope", "permission", "control", "project",
                                        "attestation", "rites", "include"];
    bool headed = false;
    foreach (h; heads) {
        if (!startsWith(s, h)) continue;
        if (s.length == h.length) return false;
        auto c = s[h.length];
        if (c == ' ' || c == '\t' || c == '\n' || c == '{' || c == '.') { headed = true; break; }
    }
    if (!headed) return false;
    if (startsWith(s, "include")) return true;
    foreach (c; s) if (c == '{') return true;
    return false;
}

// The .d file with each pbt literal set canonically. -1 when nothing fits.
ptrdiff_t formatLiterals(const(char)[] src, char[] out_, char[] scratch) {
    size_t o = 0;
    bool put(const(char)[] s) {
        if (o + s.length > out_.length) return false;
        foreach (c; s) out_[o++] = c;
        return true;
    }

    // A backtick on a line that opened a comment is prose, whatever stands
    // between it and the next. Reading one as a fixture rewrote a comment.
    bool inComment = false;
    size_t i = 0;
    while (i < src.length) {
        if (src[i] == '\n') inComment = false;
        else if (!inComment && src[i] == '/' && i + 1 < src.length && src[i + 1] == '/') inComment = true;
        if (src[i] != '`' || inComment) {
            if (!put(src[i .. i + 1])) return -1;
            i++;
            continue;
        }
        size_t j = i + 1;
        while (j < src.length && src[j] != '`') j++;
        if (j >= src.length) {
            if (!put(src[i .. $])) return -1;
            break;
        }
        auto body_ = src[i + 1 .. j];
        if (!looksPbt(body_)) {
            if (!put(src[i .. j + 1])) return -1;
            i = j + 1;
            continue;
        }

        // A fixture opens on the line after the backtick and closes before
        // the one carrying it. Both are kept; what is between is set.
        size_t a = 0;
        while (a < body_.length && isWs(body_[a])) a++;
        size_t b = body_.length;
        while (b > a && isWs(body_[b - 1])) b--;
        auto n = formatInto(body_[a .. b], scratch);
        if (n < 0) {
            if (!put(src[i .. j + 1])) return -1;
            i = j + 1;
            continue;
        }
        bool lead = a > 0;
        if (!put("`")) return -1;
        if (lead && !put("\n")) return -1;
        auto set = scratch[0 .. cast(size_t) n];
        // A one-line literal stays one line when fmt made one line of it.
        if (!lead && set.length > 0 && set[$ - 1] == '\n') set = set[0 .. $ - 1];
        if (!put(set)) return -1;
        if (!put("`")) return -1;
        i = j + 1;
    }
    return cast(ptrdiff_t) o;
}

private bool endsWith(const(char)[] s, const(char)[] p) {
    return s.length >= p.length && s[$ - p.length .. $] == p;
}

private int formatPath(const(char)[] path) {
    __gshared char[CAP] in_ = 0;
    __gshared char[CAP] out_ = 0;
    __gshared char[65536] scratch = 0;
    __gshared char[4096] name = 0;

    if (path.length >= name.length) { fputs("fmt: path too long\n", stderr); return 2; }
    foreach (i, c; path) name[i] = c;
    name[path.length] = 0;

    auto f = fopen(name.ptr, "rb");
    if (f is null) { fputs("fmt: cannot read ", stderr); fputs(name.ptr, stderr); fputs("\n", stderr); return 2; }
    auto src = readWhole(f, in_[]);
    fclose(f);
    if (src.length == in_.length) { fputs("fmt: file too large: ", stderr); fputs(name.ptr, stderr); fputs("\n", stderr); return 2; }

    auto n = endsWith(path, ".d") ? formatLiterals(src, out_[], scratch[])
                                  : formatInto(src, out_[]);
    if (n < 0) { fputs("fmt: cannot read as pbt: ", stderr); fputs(name.ptr, stderr); fputs("\n", stderr); return 2; }

    auto set = out_[0 .. cast(size_t) n];
    if (set == src) { fputs("fmt: unchanged ", stderr); fputs(name.ptr, stderr); fputs("\n", stderr); return 0; }

    auto w = fopen(name.ptr, "wb");
    if (w is null) { fputs("fmt: cannot write ", stderr); fputs(name.ptr, stderr); fputs("\n", stderr); return 2; }
    fwrite(set.ptr, 1, set.length, w);
    fclose(w);
    fputs("fmt: rewrote ", stderr); fputs(name.ptr, stderr); fputs("\n", stderr);
    return 0;
}

// BOOK_COMMAND **ground fmt**: Sets a .pbt, or the pbt fixtures in a .d, in the one layout, and writes only what would change.
int handleFmt(int argc, const(char)** argv) {
    if (argc <= 2) {
        __gshared char[CAP] in_ = 0;
        __gshared char[CAP] out_ = 0;
        auto src = readWhole(stdin, in_[]);
        auto n = formatInto(src, out_[]);
        if (n < 0) { fputs("fmt: cannot read stdin as pbt\n", stderr); return 2; }
        fwrite(out_.ptr, 1, cast(size_t) n, stdout);
        return 0;
    }
    int rc = 0;
    foreach (i; 2 .. argc) {
        auto r = formatPath(argv[i][0 .. argLen(argv[i])]);
        if (r != 0) rc = r;
    }
    return rc;
}
