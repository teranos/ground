module homedir;

// Strings that name their author do not belong in code that outlives the
// machine. They are replaced on the way in, not blocked, because the string is
// almost never the point of the line it sits on.

// The table lives in a control, so adding one is an edit to a pbt rather than
// to this file. The literal $HOME stands for the running user's home.
enum HOME_TOKEN = "$HOME";

// What a rewrite did. `fit` is false when the result would not have fitted the
// destination, and then `found` is zero — a caller must never be handed a
// truncated Write, so not fitting means nothing happened at all.
struct Rewrite {
    size_t found;
    size_t len;
    bool fit = true;
}

// The length of the longest kept string that starts at `at`, 0 when none does.
private size_t keptAt(const(char)[] text, size_t at, const(char[])[] keeps) {
    size_t longest = 0;
    foreach (k; keeps) {
        if (k.length == 0 || k.length <= longest || at + k.length > text.length) continue;
        if (text[at .. at + k.length] == k) longest = k.length;
    }
    return longest;
}

// Every occurrence of `from` replaced by `to`. A kept string is written as it
// is, and a match that would reach into one is no match.
Rewrite replaceAll(const(char)[] text, const(char)[] from, const(char)[] to, char[] dest,
                   const(char[])[] keeps = null) {
    size_t o = 0;
    size_t found = 0;

    bool put(const(char)[] s) {
        if (o + s.length > dest.length) return false;
        foreach (c; s) dest[o++] = c;
        return true;
    }

    if (from.length == 0) {
        if (!put(text)) return Rewrite(0, 0, false);
        return Rewrite(0, o, true);
    }

    bool reachesKept(size_t start) {
        foreach (j; start + 1 .. start + from.length)
            if (keptAt(text, j, keeps) > 0) return true;
        return false;
    }

    size_t i = 0;
    while (i < text.length) {
        auto k = keptAt(text, i, keeps);
        if (k > 0) {
            if (!put(text[i .. i + k])) return Rewrite(0, 0, false);
            i += k;
            continue;
        }
        if (i + from.length <= text.length && text[i .. i + from.length] == from
            && !reachesKept(i)) {
            if (!put(to)) return Rewrite(0, 0, false);
            i += from.length;
            found++;
            continue;
        }
        if (o >= dest.length) return Rewrite(0, 0, false);
        dest[o++] = text[i];
        i++;
    }
    return Rewrite(found, o, true);
}

// One field of a tool_input object rewritten, the rest of the object passed
// through untouched. file_path carries these strings too, and rewriting that
// would send the write somewhere that does not exist.
Rewrite rewriteField(const(char)[] region, const(char)[] key,
                     const(char)[] from, const(char)[] to, char[] dest,
                     const(char[])[] keeps = null) {
    import matcher : indexOf;

    size_t o = 0;

    bool put(const(char)[] s) {
        if (o + s.length > dest.length) return false;
        foreach (c; s) dest[o++] = c;
        return true;
    }

    if (key.length == 0 || from.length == 0) {
        if (!put(region)) return Rewrite(0, 0, false);
        return Rewrite(0, o, true);
    }

    char[64] needle = 0;
    if (key.length + 4 > needle.length) return Rewrite(0, 0, false);
    size_t n = 0;
    needle[n++] = '"';
    foreach (c; key) needle[n++] = c;
    needle[n++] = '"';
    needle[n++] = ':';
    needle[n++] = '"';

    auto at = indexOf(region, needle[0 .. n]);
    if (at < 0) {
        if (!put(region)) return Rewrite(0, 0, false);
        return Rewrite(0, o, true);
    }

    size_t start = cast(size_t) at + n;

    // The closing quote is the first one not preceded by a backslash, so a
    // value carrying an escaped quote does not end at it.
    size_t end = start;
    while (end < region.length) {
        if (region[end] == '\\' && end + 1 < region.length) { end += 2; continue; }
        if (region[end] == '"') break;
        end++;
    }

    if (!put(region[0 .. start])) return Rewrite(0, 0, false);

    auto inner = replaceAll(region[start .. end], from, to, dest[o .. $], keeps);
    if (!inner.fit) return Rewrite(0, 0, false);
    o += inner.len;

    if (!put(region[end .. $])) return Rewrite(0, 0, false);
    return Rewrite(inner.found, o, true);
}
