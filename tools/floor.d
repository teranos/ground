/// floor — which of ground's controls every engine is built from.
module floor;

// "but the floor is always the same, everyonne get;s the same nice things by default. but you get way more with the real sand"

/// The *.pbt in controls/ that ground tracks, in name order. present is what controls/ holds;
/// tracked is `git ls-files` from the repository's root. A tree that is no repository (a flake's
/// source, a node's tarball) holds only what was tracked, so all of its *.pbt are the floor.
string[] floorNames(const string[] present, const string[] tracked, bool repo) {
    import std.algorithm : sort, endsWith, canFind;
    string[] names;
    foreach (p; present) {
        if (!p.endsWith(".pbt")) continue;
        if (repo && !tracked.canFind("controls/" ~ p)) continue;
        names ~= p;
    }
    names.sort();
    return names;
}
