module breadcrumb_test;

// 「[Opus 5.5] A breadcrumb lands in the directory its path names, or nowhere: a home longer than the path」
// 「[Opus 5.5] holds was cut, and the breadcrumb was written into the directory the cut named, which is not」
// 「[Opus 5.5] the one anyone reads.」
import errors : errorsDirIn, crumbPathIn;

unittest {
    char[512] dir = 0;
    auto n = errorsDirIn("/h", dir);
    assert(dir[0 .. n] == "/h/.local/share/ground/errors");
    assert(dir[n] == 0);

    char[600] longHome = 'a';
    longHome[0] = '/';
    assert(errorsDirIn(longHome[], dir) == 0, "what does not fit is no directory");

    char[768] path = 0;
    auto m = crumbPathIn(dir[0 .. n], "sess-1", path);
    assert(path[0 .. m] == "/h/.local/share/ground/errors/sess-1.log");
    char[800] longSession = 's';
    assert(crumbPathIn(dir[0 .. n], longSession[], path) == 0, "what does not fit is no path");
}

