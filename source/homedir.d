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

// Every occurrence of `from` replaced by `to`.
Rewrite replaceAll(const(char)[] text, const(char)[] from, const(char)[] to, char[] dest) {
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

    size_t i = 0;
    while (i < text.length) {
        if (i + from.length <= text.length && text[i .. i + from.length] == from) {
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
                     const(char)[] from, const(char)[] to, char[] dest) {
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

    auto inner = replaceAll(region[start .. end], from, to, dest[o .. $]);
    if (!inner.fit) return Rewrite(0, 0, false);
    o += inner.len;

    if (!put(region[end .. $])) return Rewrite(0, 0, false);
    return Rewrite(inner.found, o, true);
}
