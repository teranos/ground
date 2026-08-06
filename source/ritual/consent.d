module ritual.consent;

// What a performance authorises. The ritual is the consent record: written in
// a file, reviewable before it runs, which a permission prompt at 3am is not.
private immutable string[4] ALLOWED = [
    "git commit",
    "git push",
    "gh pr checks",
    "gh pr create",
];

// A shell operator after the allowed head means the rest is unreviewed, so
// the whole command stops being the one that was authorised.
private bool chained(const(char)[] rest) {
    foreach (c; rest) {
        if (c == '&' || c == ';' || c == '|' || c == '\n' || c == '`') return true;
    }
    return false;
}

bool consented(const(char)[] cmd) {
    size_t i = 0;
    while (i < cmd.length && (cmd[i] == ' ' || cmd[i] == '\t')) i++;
    auto head = cmd[i .. $];

    foreach (a; ALLOWED) {
        if (head.length < a.length) continue;
        bool same = true;
        foreach (j; 0 .. a.length) {
            if (head[j] != a[j]) { same = false; break; }
        }
        if (!same) continue;

        // The allowed word has to end where the command's word ends, or
        // `git commitment` rides in on `git commit`.
        auto rest = head[a.length .. $];
        if (rest.length > 0 && rest[0] != ' ' && rest[0] != '\t') continue;
        if (chained(rest)) return false;
        return true;
    }
    return false;
}
