module ritual.resolve;

import receiver : Receiver;

// Which ritual a word or two words name. "ground should refuse if it cant
// resolve to a single one cleanly".
struct Chosen {
    bool ok;
    size_t ritualIdx;
    size_t projectIdx;
    // What ground says when it will not pick for you.
    string why;
}

private size_t projectOf(PR)(const PR r, size_t ritualIdx) {
    auto rit = r.rituals[ritualIdx];
    foreach (pi; 0 .. r.projectCount) {
        if (r.projects[pi].path != rit.projectPath) continue;
        if (r.projects[pi].name != rit.projectName) continue;
        return pi;
    }
    return r.projectCount;
}

// Two words are a project and one of its rituals. One word is looked up as
// both, and the unnamed block wins when it is one of the candidates.
Chosen chooseRitual(PR)(const PR r, const(char)[] first, const(char)[] second) {
    if (second.length > 0) {
        foreach (i; 0 .. r.ritualCount) {
            if (r.rituals[i].projectName != first) continue;
            if (r.rituals[i].name != second) continue;
            return Chosen(true, i, projectOf(r, i), "");
        }
        return Chosen(false, 0, 0, "no ritual by that name in that project");
    }

    // The two readings are counted apart. A word that is a ritual in one and a
    // different ritual in the other is two candidates, and ground refuses.
    size_t byName, byNameHits, byNameUnnamed, byNameUnnamedHits;
    size_t byProject, byProjectHits;
    foreach (i; 0 .. r.ritualCount) {
        if (r.rituals[i].name == first) {
            byName = i;
            byNameHits++;
            if (r.rituals[i].projectName.length == 0) {
                byNameUnnamed = i;
                byNameUnnamedHits++;
            }
        }
        if (r.rituals[i].projectName.length > 0 && r.rituals[i].projectName == first) {
            byProject = i;
            byProjectHits++;
        }
    }

    if (byNameHits == 0 && byProjectHits == 0)
        return Chosen(false, 0, 0, "no ritual and no project by that name");
    if (byNameHits > 0 && byProjectHits > 0)
        return Chosen(false, 0, 0, "that word is a ritual and a project");

    if (byProjectHits > 0) {
        if (byProjectHits == 1) return Chosen(true, byProject, projectOf(r, byProject), "");
        return Chosen(false, 0, 0, "that project holds more than one ritual");
    }

    if (byNameHits == 1) return Chosen(true, byName, projectOf(r, byName), "");

    // "the unnamed one actually wins, and the named one is the explicit edge
    // case" — when the unnamed block offers exactly one of the candidates.
    if (byNameUnnamedHits == 1)
        return Chosen(true, byNameUnnamed, projectOf(r, byNameUnnamed), "");

    return Chosen(false, 0, 0, "that word names more than one ritual");
}

private bool isSep(char c) {
    return c == '&' || c == ';' || c == '|' || c == '\n';
}

private bool isBlank(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

// The ritual a shell command starts, if it starts one. `ground ritual` has to
// be a command rather than a word inside one, or a grep for the phrase binds
// the parent session to whoever read the documentation.
const(char)[] ritualStarted(const(char)[] cmd) {
    enum verb = "ground ritual";
    if (cmd.length < verb.length) return "";

    foreach (i; 0 .. cmd.length - verb.length + 1) {
        if (cmd[i .. i + verb.length] != verb) continue;

        size_t back = i;
        while (back > 0 && isBlank(cmd[back - 1])) back--;
        if (back > 0 && !isSep(cmd[back - 1])) continue;

        size_t s = i + verb.length;
        while (s < cmd.length && isBlank(cmd[s])) s++;
        if (s == i + verb.length) continue;  // "ground rituals", not "ground ritual x"

        size_t e = s;
        while (e < cmd.length && !isBlank(cmd[e])) e++;
        return cmd[s .. e];
    }
    return "";
}

import ritual.position : MAX_RITES;

// A ritual's project path is a locator, not a test against cwd — it is named
// from anywhere. The declared projects say where that path is on disk.
const(char)[] repoRoot(PR)(const PR r, const(char)[] projectPath) {
    if (projectPath.length == 0) return "";
    const(char)[] best = "";
    foreach (i; 0 .. r.projectCount) {
        auto p = r.projects[i].path;
        if (p.length < projectPath.length) continue;
        bool tail = true;
        foreach (j; 0 .. projectPath.length) {
            if (p[p.length - projectPath.length + j] != projectPath[j]) { tail = false; break; }
        }
        if (tail && p.length > best.length) best = p;
    }
    return best;
}

// A ritual names groups; the position walks rites. The flat list is the order
// they run in and the index `goto` needs.
struct FlatRite {
    string group;
    string name;
    string eval;
    // Run before the agent has the mic, once per entry into the rite.
    string run;
    string msg;
    string mic;
    int pass;
    int[8] catches;
    size_t catchCount;
    string goto_;
    // Where this rite's verdict goes. Carried through the flatten because the
    // delivery sites hold a FlatRite and nothing else knows what the author
    // wrote — dropping it here would silently make every rite report to all.
    Receiver to;
    // "it keeps holding the mic until ci has an outcome" — so this is not a
    // deadline. It is what holding that long is measured against.
    int wait;
    string[8] keys;
    string[8] values;
    size_t valueCount;
}

struct Flattened {
    FlatRite[MAX_RITES] rites;
    size_t count;
    // "you set a branch on the block on the project level" — carried here
    // because prScript is built where the walk is, not where the pbt is.
    string branch;
    // Same reason: spawnScript is built from the walk, not from the pbt.
    string system;
    // Per performance, a full run of a ritual. The project says how long its
    // loops may go; MAX_GOTOS is what a project that says nothing gets.
    size_t maxGoto;
}

Flattened flatten(PR)(const PR r, size_t ritualIdx) {
    Flattened f;
    if (ritualIdx >= r.ritualCount) return f;
    auto rit = r.rituals[ritualIdx];
    f.branch = rit.projectBranch;
    f.system = rit.system;

    // Matched on name as well as path: four blocks share `/sbvh-nl/grove`, and
    // by path alone the first one's number would govern all of them.
    import ritual.position : MAX_GOTOS;
    f.maxGoto = MAX_GOTOS;
    foreach (pi; 0 .. r.projectCount) {
        if (r.projects[pi].path != rit.projectPath) continue;
        if (r.projects[pi].name != rit.projectName) continue;
        if (r.projects[pi].maxGoto > 0) f.maxGoto = r.projects[pi].maxGoto;
        break;
    }

    foreach (ri; 0 .. rit.refCount) {
        auto refr = rit.refs[ri];
        foreach (gi; 0 .. r.ritesCount) {
            if (r.rites[gi].name != refr.name) continue;
            auto grp = r.rites[gi];
            foreach (i; 0 .. grp.riteCount) {
                if (f.count >= MAX_RITES) return f;
                auto src = grp.rites[i];
                FlatRite fr;
                fr.group = grp.name;
                fr.name = src.name;
                fr.eval = src.eval;
                fr.run = src.run;
                fr.msg = src.msg;
                fr.mic = src.mic;
                fr.pass = src.pass;
                fr.catches = src.catches;
                fr.catchCount = src.catchCount;
                fr.goto_ = src.goto_;
                fr.to = src.to;
                fr.wait = src.wait;
                fr.keys = refr.keys;
                fr.values = refr.values;
                fr.valueCount = refr.valueCount;
                f.rites[f.count++] = fr;
            }
        }
    }
    return f;
}

// The names, joined, so a reader with only the row can draw the line.
struct RiteNames {
    char[1024] buf = 0;
    size_t len;
    const(char)[] text() const return { return buf[0 .. len]; }
}

RiteNames riteNames(const Flattened f) {
    RiteNames n;
    foreach (i; 0 .. f.count) {
        if (i > 0 && n.len < n.buf.length) n.buf[n.len++] = ',';
        foreach (c; f.rites[i].name) {
            if (n.len < n.buf.length) n.buf[n.len++] = c;
        }
    }
    return n;
}

long indexOfRite(const Flattened f, const(char)[] name) {
    foreach (i; 0 .. f.count)
        if (f.rites[i].name == name) return cast(long) i;
    return -1;
}
