module push;

// Source of truth for what a `git push` actually targeted: the push's own
// stdout. Carries repo identity, branch, and the new HEAD SHA. Captured at
// PostToolUse time so ground never needs to look at cwd to know which CI
// run to ask about later.
struct PushInfo {
    const(char)[] repo;   // owner/name (gh -R format), e.g. "acme/widget"
    const(char)[] branch; // pushed local-side ref, e.g. "main"
    const(char)[] sha;    // new HEAD short SHA (empty for new-branch pushes)
}

PushInfo parsePushOutput(const(char)[] output) {
    PushInfo info;

    // Find first "To <url>" line.
    size_t pos = 0;
    const(char)[] url;
    while (pos < output.length) {
        size_t lineEnd = pos;
        while (lineEnd < output.length && output[lineEnd] != '\n') lineEnd++;
        auto line = output[pos .. lineEnd];
        if (line.length >= 3 && line[0 .. 3] == "To ") {
            url = line[3 .. $];
            // Strip optional "git@" prefix on SSH URLs.
            if (url.length >= 4 && url[0 .. 4] == "git@") url = url[4 .. $];
            pos = lineEnd + 1;
            break;
        }
        pos = lineEnd + 1;
    }

    if (url.length == 0) return info;

    // Extract owner/name from URL.
    //   github.com:owner/name[.git]            (SSH)
    //   https://github.com/owner/name[.git]    (HTTPS)
    size_t pathStart = 0;
    bool isHttp = false;
    foreach (i; 0 .. url.length) {
        if (i + 2 >= url.length) break;
        if (url[i] == ':' && url[i + 1] == '/' && url[i + 2] == '/') {
            isHttp = true;
            pathStart = i + 3;
            break;
        }
    }
    if (isHttp) {
        while (pathStart < url.length && url[pathStart] != '/') pathStart++;
        if (pathStart < url.length) pathStart++;
    } else {
        bool foundColon = false;
        foreach (i; 0 .. url.length) {
            if (url[i] == ':') { pathStart = i + 1; foundColon = true; break; }
        }
        if (!foundColon) return info;
    }

    if (pathStart >= url.length) return info;
    auto path = url[pathStart .. $];
    // Strip trailing .git
    if (path.length >= 4 && path[$ - 4 .. $] == ".git") path = path[0 .. $ - 4];
    // Strip trailing whitespace/CR
    while (path.length > 0 && (path[$ - 1] == ' ' || path[$ - 1] == '\r')) path = path[0 .. $ - 1];
    info.repo = path;

    // Find ref update line: contains " -> ".
    while (pos < output.length) {
        size_t lineEnd = pos;
        while (lineEnd < output.length && output[lineEnd] != '\n') lineEnd++;
        auto line = output[pos .. lineEnd];

        ptrdiff_t arrowIdx = -1;
        if (line.length >= 4) {
            foreach (i; 0 .. line.length - 3) {
                if (line[i] == ' ' && line[i + 1] == '-' && line[i + 2] == '>' && line[i + 3] == ' ') {
                    arrowIdx = cast(ptrdiff_t) i;
                    break;
                }
            }
        }
        if (arrowIdx > 0) {
            // Branch = word immediately before " -> "
            size_t branchEnd = cast(size_t) arrowIdx;
            size_t branchStart = branchEnd;
            while (branchStart > 0 && line[branchStart - 1] != ' ') branchStart--;
            info.branch = line[branchStart .. branchEnd];

            // SHA = bytes between ".." and the next space, anywhere before branchStart
            foreach (i; 0 .. branchStart) {
                if (i + 1 >= branchStart) break;
                if (line[i] == '.' && line[i + 1] == '.') {
                    size_t shaStart = i + 2;
                    size_t shaEnd = shaStart;
                    while (shaEnd < branchStart && line[shaEnd] != ' ') shaEnd++;
                    info.sha = line[shaStart .. shaEnd];
                    break;
                }
            }
            break;
        }
        pos = lineEnd + 1;
    }

    return info;
}

// Does the newline-separated path list contain a line that starts with `prefix`?
// Anchored at line start — substring matches inside a path do not count.
bool hasPathStartingWith(const(char)[] paths, const(char)[] prefix) {
    if (prefix.length == 0) return false;
    size_t lineStart = 0;
    for (size_t i = 0; i <= paths.length; i++) {
        if (i == paths.length || paths[i] == '\n') {
            auto line = paths[lineStart .. i];
            if (line.length >= prefix.length && line[0 .. prefix.length] == prefix)
                return true;
            lineStart = i + 1;
        }
    }
    return false;
}
