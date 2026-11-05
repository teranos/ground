/// keep — whether make install may put this tree's sand where the machine's is.
module keep;

/// Why an install is refused, or empty when it is not. installedProjects is what the sand installed
/// at path said it folded, -1 when it said nothing; newProjects is what wind folded in this tree.
/// Only a sand of no projects in place of one that had some is refused: that is a tree without
/// controls/local, and what it would install is the floor.
string refusal(bool installed, long installedProjects, long newProjects, string path) {
    import std.conv : to;
    if (!installed || installedProjects <= 0 || newProjects != 0) return "";
    return "make install refuses: this tree's sand folds 0 projects, and the sand installed at " ~ path
        ~ " folds " ~ installedProjects.to!string ~ "."
        ~ " wind found no project here: controls/local is untracked, so a worktree has none."
        ~ " Install from the checkout whose controls/local declares them, or remove " ~ path
        ~ " to install the floor.";
}

/// The count wind wrote: digits and a newline. -1 for anything else.
long projectsOf(string text) {
    if (text.length < 2 || text[$ - 1] != '\n') return -1;
    long n = 0;
    foreach (c; text[0 .. $ - 1]) {
        if (c < '0' || c > '9') return -1;
        n = n * 10 + (c - '0');
    }
    return n;
}

/// Why an install stops on the count beside the installed sand at path, or empty: a count that is
/// there and holds no count says nothing of what that sand folds, and is not read as none.
string countRefusal(bool counted, string countText, string path) {
    if (!counted || projectsOf(countText) >= 0) return "";
    return "make install refuses: " ~ path ~ ".projects holds no count of projects, so what the sand installed at "
        ~ path ~ " folds is not known. Remove " ~ path ~ ".projects to install over it.";
}
