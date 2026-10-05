module place;

// Where a session ran, as ground's pbt names it. A block naming the repo's
// origin is that repo's wherever its checkout is; otherwise the deepest block
// whose path holds the place or the repo's root. Any block, not only a ritual's.
const(char)[] placeOf(PR)(auto ref const PR r, const(char)[] cwd,
                          const(char)[] root, const(char)[] origin) {
    import hooks : pathMatch;

    if (origin.length > 0)
        foreach (i; 0 .. r.projectCount)
            if (r.projects[i].origin == origin) return r.projects[i].path;

    const(char)[] best = "";
    foreach (i; 0 .. r.projectCount) {
        auto p = r.projects[i].path;
        if (p.length <= best.length) continue;
        if (pathMatch(cwd, p) || (root.length > 0 && pathMatch(root, p))) best = p;
    }
    return best;
}
