module org;

// The name GitHub knows an org by is the end of the url its block gives. A bare
// name is already one.
const(char)[] githubName(const(char)[] github) {
    auto s = github;
    while (s.length > 0 && s[$ - 1] == '/') s = s[0 .. $ - 1];
    size_t start = s.length;
    while (start > 0 && s[start - 1] != '/') start--;
    return s[start .. $];
}
