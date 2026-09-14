module routes;

// A word from a project's OpenAPI spec, said in a reply, and the contract
// that answers it. The spec is digested by wind; this is the Stop-side half.

import zbuf : ZBuf;

private bool isWordChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '\'';
}

// Case-sensitive and whole: the reply's "I" is never the segment "i", and
// "attestation" is not "attestations". A path written out matches too, since
// its slashes are boundaries.
bool saysWord(const(char)[] text, const(char)[] word) {
    if (word.length == 0 || word.length > text.length) return false;
    foreach (i; 0 .. text.length - word.length + 1) {
        if (text[i .. i + word.length] != word) continue;
        if (i > 0 && isWordChar(text[i - 1])) continue;
        auto end = i + word.length;
        if (end < text.length && isWordChar(text[end])) continue;
        return true;
    }
    return false;
}

// A route speaks for the tree of the project that declared it, and for
// nothing that merely shares its prefix.
bool routeApplies(const(char)[] project, const(char)[] cwd) {
    if (project.length == 0 || cwd.length < project.length) return false;
    if (cwd[0 .. project.length] != project) return false;
    return cwd.length == project.length || cwd[project.length] == '/';
}

// How many leading texts fit whole in `cap` when joined by a blank line.
// A text that does not fit is not cut; it waits for the next turn.
size_t fitRoutes(const(char)[][] texts, size_t cap) {
    size_t total = 0;
    foreach (i, t; texts) {
        auto need = t.length + (i > 0 ? 2 : 0);
        if (total + need > cap) return i;
        total += need;
    }
    return texts.length;
}

ZBuf buildRoutesMessage(const(char)[][] texts) {
    ZBuf buf;
    foreach (i, t; texts) {
        if (i > 0) buf.put("\n\n");
        buf.put(t);
    }
    return buf;
}
