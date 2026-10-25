module shellwrite;

// What a shell command writes into a file, read off the command as the shell
// would run it: a heredoc into a redirect or tee, or echo and printf
// redirected. Ground asks its file controls about it as the Write it amounts to.

struct ShellWrite {
    bool ok;
    const(char)[] path; // as the command names it, which may be relative
    const(char)[] text; // what lands in the file
}

private bool space(char c) { return c == ' ' || c == '\t'; }

// The word at `at`, quotes taken off, and where it ends.
private const(char)[] wordAt(const(char)[] s, ref size_t at) {
    while (at < s.length && space(s[at])) at++;
    if (at < s.length && (s[at] == '\'' || s[at] == '"')) {
        auto q = s[at];
        auto start = ++at;
        while (at < s.length && s[at] != q) at++;
        auto w = s[start .. at];
        if (at < s.length) at++;
        return w;
    }
    auto start = at;
    while (at < s.length && !space(s[at]) && s[at] != ';' && s[at] != '|' && s[at] != '&'
           && s[at] != '>' && s[at] != '<' && s[at] != '\n') at++;
    return s[start .. at];
}

// The file a line redirects into with > or >>, or tees into; null for none,
// for a descriptor (2>&1) and for /dev/null.
private const(char)[] targetIn(const(char)[] line) {
    size_t i;
    char quote = 0;
    while (i < line.length) {
        auto c = line[i];
        if (quote) { if (c == quote) quote = 0; i++; continue; }
        if (c == '\'' || c == '"') { quote = c; i++; continue; }
        if (c == '>') {
            bool fd = i > 0 && line[i - 1] >= '0' && line[i - 1] <= '9';
            size_t at = i + 1;
            if (at < line.length && line[at] == '>') at++;
            if (at < line.length && line[at] == '&') return null;
            auto w = wordAt(line, at);
            if (!fd && w.length > 0 && w != "/dev/null") return w;
            i = at;
            continue;
        }
        if (c == 't' && i + 3 <= line.length && line[i .. i + 3] == "tee" && (i == 0 || space(line[i - 1]) || line[i - 1] == '|')
            && (i + 3 == line.length || space(line[i + 3]))) {
            size_t at = i + 3;
            auto w = wordAt(line, at);
            if (w == "-a") w = wordAt(line, at);
            if (w.length > 0 && w != "/dev/null") return w;
            i = at;
            continue;
        }
        i++;
    }
    return null;
}

/// What cmd writes into a file, its text unescaped into buf.
ShellWrite shellWrite(const(char)[] cmd, char[] buf) {
    ShellWrite r;
    size_t n;
    void put(char c) { if (n < buf.length) buf[n++] = c; }

    // A heredoc: its first line names where it goes, its body is the text.
    foreach (i; 0 .. cmd.length) {
        if (i + 2 > cmd.length || cmd[i .. i + 2] != "<<" || (i + 2 < cmd.length && cmd[i + 2] == '<')) continue;
        size_t eol = i;
        while (eol < cmd.length && cmd[eol] != '\n') eol++;
        auto first = cmd[0 .. eol];
        if (eol >= cmd.length) return r;
        size_t at = i + 2;
        bool tabs = at < cmd.length && cmd[at] == '-';
        if (tabs) at++;
        auto delim = wordAt(cmd, at);
        if (delim.length == 0) return r;
        // A heredoc piped on writes into nothing of its own.
        foreach (c; first) if (c == '|' && targetIn(first) is null) return r;
        auto path = targetIn(first);
        if (path is null) return r;
        size_t line = eol + 1;
        bool firstLine = true;
        while (line <= cmd.length) {
            size_t end = line;
            while (end < cmd.length && cmd[end] != '\n') end++;
            auto l = cmd[line .. end];
            if (tabs) while (l.length > 0 && l[0] == '\t') l = l[1 .. $];
            if (l == delim) break;
            if (!firstLine) put('\n');
            foreach (c; l) put(c);
            firstLine = false;
            line = end + 1;
        }
        r.ok = true; r.path = path; r.text = buf[0 .. n];
        return r;
    }

    // echo or printf, redirected.
    auto path = targetIn(cmd);
    if (path is null) return r;
    size_t at;
    auto verb = wordAt(cmd, at);
    if (verb != "echo" && verb != "printf") return r;
    bool printf = verb == "printf";
    bool firstArg = true;
    while (at < cmd.length) {
        while (at < cmd.length && space(cmd[at])) at++;
        if (at >= cmd.length || cmd[at] == '>' || cmd[at] == ';' || cmd[at] == '|' || cmd[at] == '&') break;
        if (!firstArg && !printf) put(' ');
        if (cmd[at] == '\'' ) {
            auto start = ++at;
            while (at < cmd.length && cmd[at] != '\'') at++;
            foreach (c; cmd[start .. at]) put(c);
            if (at < cmd.length) at++;
        } else if (cmd[at] == '"') {
            at++;
            while (at < cmd.length && cmd[at] != '"') {
                if (cmd[at] == '\\' && at + 1 < cmd.length && (cmd[at + 1] == '"' || cmd[at + 1] == '\\' || cmd[at + 1] == '$')) at++;
                put(cmd[at++]);
            }
            if (at < cmd.length) at++;
        } else {
            foreach (c; wordAt(cmd, at)) put(c);
        }
        firstArg = false;
    }
    if (printf) {
        // Its format's escapes, the two a line of prose carries.
        size_t m;
        for (size_t i = 0; i < n; i++) {
            if (buf[i] == '\\' && i + 1 < n && (buf[i + 1] == 'n' || buf[i + 1] == 't')) {
                buf[m++] = buf[i + 1] == 'n' ? '\n' : '\t';
                i++;
            } else buf[m++] = buf[i];
        }
        n = m;
    }
    r.ok = true; r.path = path; r.text = buf[0 .. n];
    return r;
}
