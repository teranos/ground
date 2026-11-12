module named;

// "AGENTS CAN TALK TO EACH OTHER BY THEIR NAME"
// "AND GROUND DELIVERS IT VIA UG AND STATUSLINE"
//
// What is said to a name is the session's that keeps the name. Ground keeps a
// session's name beside its key, in ~/.qntx/sessions/<session id>/name, the
// name on its first line (source/naming.d). The session is found there.

// The id of the session on this machine that keeps name, into dest. Its
// length, 0 when no session here keeps it: the name is another machine's.
size_t sessionKeeping(const(char)[] home, const(char)[] name, char[] dest) {
    import core.sys.posix.dirent : opendir, readdir, closedir;
    import core.stdc.stdio : fopen, fread, fclose;

    if (name.length == 0) return 0;
    char[1024] dir = 0;
    size_t d = 0;
    void put(const(char)[] s) { foreach (c; s) if (d + 1 < dir.length) dir[d++] = c; }
    put(home);
    put("/.qntx/sessions");
    auto base = d;
    auto open = opendir(&dir[0]);
    if (open is null) return 0;
    scope (exit) closedir(open);

    while (true) {
        auto entry = readdir(open);
        if (entry is null) return 0;
        size_t n = 0;
        while (n < entry.d_name.length && entry.d_name[n] != 0) n++;
        auto id = entry.d_name[0 .. n];
        if (id.length == 0 || id[0] == '.') continue;

        d = base;
        put("/");
        put(id);
        put("/name");
        dir[d] = 0;
        auto f = fopen(&dir[0], "r");
        if (f is null) continue;
        char[256] kept = 0;
        auto got = fread(kept.ptr, 1, kept.length, f);
        fclose(f);
        size_t line = 0;
        while (line < got && kept[line] != '\n') line++;
        if (kept[0 .. line] != name) continue;
        if (id.length > dest.length) return 0;
        foreach (i, c; id) dest[i] = c;
        return id.length;
    }
}
