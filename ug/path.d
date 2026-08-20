module path;

// What the row calls where you are.
// Rules read from collet's format_path.

// The project's own name when you are at its root, the project's name and the
// rest when you are inside it, a tilde when you are outside it but home, and
// the whole path when you are nowhere near either.
size_t pathInto(const(char)[] cwd, const(char)[] projectDir, const(char)[] home, char[] dest) {
    import json : baseName;

    size_t o = 0;

    void put(const(char)[] s) {
        foreach (c; s) if (o < dest.length) dest[o++] = c;
    }

    if (projectDir.length > 0 && startsWith(cwd, projectDir)) {
        put(baseName(projectDir));
        if (cwd.length > projectDir.length) {
            auto rest = cwd[projectDir.length .. $];
            if (rest.length > 0 && rest[0] == '/') rest = rest[1 .. $];
            put("/");
            put(rest);
        }
        return o;
    }

    if (home.length > 0 && startsWith(cwd, home)) {
        put("~");
        put(cwd[home.length .. $]);
        return o;
    }

    put(cwd);
    return o;
}

private bool startsWith(const(char)[] s, const(char)[] prefix) {
    if (prefix.length > s.length) return false;
    return s[0 .. prefix.length] == prefix;
}
