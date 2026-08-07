module ritual.resolve;

import ritual.position : MAX_RITES;

// Told as each other, these send you looking in the wrong place.
enum ResolveFail { None, NoSuchRitual, WrongProject }

struct Resolved { ResolveFail fail; size_t index; }

Resolved resolveRitual(PR)(const PR r, const(char)[] name, const(char)[] cwd) {
    import matcher : contains;
    bool sawName = false;
    foreach (i; 0 .. r.ritualCount) {
        if (r.rituals[i].name != name) continue;
        sawName = true;
        if (contains(cwd, r.rituals[i].projectPath)) return Resolved(ResolveFail.None, i);
    }
    return Resolved(sawName ? ResolveFail.WrongProject : ResolveFail.NoSuchRitual, 0);
}

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
    string cmd;
    string msg;
    int pass;
    int[8] catches;
    size_t catchCount;
    string goto_;
    string[8] keys;
    string[8] values;
    size_t valueCount;
}

struct Flattened {
    FlatRite[MAX_RITES] rites;
    size_t count;
}

Flattened flatten(PR)(const PR r, size_t ritualIdx) {
    Flattened f;
    if (ritualIdx >= r.ritualCount) return f;
    auto rit = r.rituals[ritualIdx];

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
                fr.cmd = src.cmd;
                fr.msg = src.msg;
                fr.pass = src.pass;
                fr.catches = src.catches;
                fr.catchCount = src.catchCount;
                fr.goto_ = src.goto_;
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
