module binary;

// Binary file detection using git's heuristic: NUL byte in first 8000 bytes.

bool isBinaryFile(const(char)[] path, const(char)[] cwd) {
    import core.stdc.stdio : fopen, fread, fclose;

    __gshared char[4096] fullPath = 0;
    size_t len = 0;

    if (path.length > 0 && path[0] == '/') {
        // Absolute path — use directly
        foreach (c; path) if (len < fullPath.length - 1) fullPath[len++] = c;
    } else {
        foreach (c; cwd) if (len < fullPath.length - 2) fullPath[len++] = c;
        if (len > 0 && fullPath[len - 1] != '/') fullPath[len++] = '/';
        foreach (c; path) if (len < fullPath.length - 1) fullPath[len++] = c;
    }
    fullPath[len] = '\0';

    auto f = fopen(&fullPath[0], "rb");
    if (f is null) return false;

    __gshared ubyte[8000] buf;
    auto n = fread(&buf[0], 1, buf.length, f);
    fclose(f);

    foreach (j; 0 .. n)
        if (buf[j] == 0) return true;

    return false;
}

// Scan git add arguments for binary files. Returns first binary path found, or null.
const(char)[] checkGitAddForBinary(const(char)[] command, const(char)[] cwd) {
    import matcher : strip;

    size_t start = 0;
    size_t i = 0;
    while (i <= command.length) {
        bool atEnd = (i == command.length);
        bool isSep = atEnd;
        size_t skip = 0;
        if (!atEnd) {
            if (command[i] == '|' || command[i] == ';') { isSep = true; skip = 1; }
            else if (i + 1 < command.length && command[i] == '&' && command[i + 1] == '&') { isSep = true; skip = 2; }
        }

        if (isSep) {
            auto seg = strip(command[start .. i]);
            if (seg.length > 8 && seg[0 .. 8] == "git add ") {
                auto args = seg[8 .. $];
                size_t pos = 0;
                while (pos < args.length) {
                    while (pos < args.length && args[pos] == ' ') pos++;
                    if (pos >= args.length) break;

                    size_t argStart = pos;
                    if (args[pos] == '"' || args[pos] == '\'') {
                        char q = args[pos];
                        pos++;
                        while (pos < args.length && args[pos] != q) pos++;
                        if (pos < args.length) pos++;
                    } else {
                        while (pos < args.length && args[pos] != ' ') pos++;
                    }
                    auto arg = args[argStart .. pos];

                    // Strip quotes
                    if (arg.length >= 2 && (arg[0] == '"' || arg[0] == '\'') && arg[$ - 1] == arg[0])
                        arg = arg[1 .. $ - 1];

                    if (arg.length == 0) continue;
                    if (arg[0] == '-') continue;

                    if (isBinaryFile(arg, cwd)) return arg;
                }
            }
            start = i + (atEnd ? 1 : skip);
            i = start;
        } else i++;
    }
    return null;
}
