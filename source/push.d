module push;

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
