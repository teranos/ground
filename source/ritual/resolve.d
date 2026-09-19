module ritual.resolve;

// BOOK_GLOSSARY **Ritual**: A ritual is one or more sequences of rites{ .. } blocks.
// BOOK_GLOSSARY **Rites block**: A named group of rites, with the params it takes, that does not finish while a dispatch it made is outstanding.

import receiver : Receiver;
import proto : ParsedModels, ParsedSentry;

// Which ritual a word or two words name. "ground should refuse if it cant
// resolve to a single one cleanly".
struct Chosen {
    bool ok;
    size_t ritualIdx;
    size_t projectIdx;
    // What ground says when it will not pick for you.
    string why;
}

private size_t projectOf(PR)(auto ref const PR r, size_t ritualIdx) {
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
Chosen chooseRitual(PR)(auto ref const PR r, const(char)[] first, const(char)[] second) {
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
const(char)[] repoRoot(PR)(auto ref const PR r, const(char)[] projectPath) {
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
    // "<owner>/<repo> <workflow>", and the fragment whose lines become -f.
    string dispatch;
    string inputs;
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
    // spawnScript is built from the walk, not from the pbt.
    string system;
    // Ritual, project, top level: the nearest first.
    ParsedModels[3] models;
    // The same three layers, for where a performance reports.
    ParsedSentry[3] sentry;
    // Per performance, a full run of a ritual. The project says how long its
    // loops may go; MAX_GOTOS is what a project that says nothing gets.
    size_t maxGoto;
}

// The nearest dsn is the one used. A layer that sets none does not blank the
// layer outside it, and nothing set anywhere is nowhere to report.
const(char)[] resolveSentry(const ParsedSentry[3] layers) {
    foreach (l; layers) if (l.dsn.length > 0) return l.dsn;
    return "";
}

// Where something that is no ritual's reports from a place: the project that
// place stands in, the deepest one when several do, and the top level where
// none does. A sibling directory is not the project, so the match ends where a
// directory name ends.
const(char)[] dsnAt(PR)(auto ref const PR r, const(char)[] cwd) {
    import hooks : pathMatch;
    size_t best = 0;
    const(char)[] dsn = "";
    foreach (i; 0 .. r.projectCount) {
        auto p = r.projects[i].path;
        auto here = r.projects[i].sentry.dsn.length > 0
            ? r.projects[i].sentry.dsn
            : orgSentry(r, r.projects[i].org).dsn;
        if (here.length == 0) continue;
        if (p.length <= best || !pathMatch(cwd, p)) continue;
        best = p.length;
        dsn = here;
    }
    return dsn.length > 0 ? dsn : r.sentry.dsn;
}

// The loom port of the project a cwd is in — the deepest one that names one —
// or 0: a hook outside every project with a loom sends nothing.
int loomPortAt(PR)(auto ref const PR r, const(char)[] cwd) {
    import hooks : pathMatch;
    size_t best = 0;
    int port = 0;
    foreach (i; 0 .. r.projectCount) {
        auto p = r.projects[i].path;
        auto here = r.projects[i].qntxBlock.loomPortUDP;
        if (here == 0) continue;
        if (p.length <= best || !pathMatch(cwd, p)) continue;
        best = p.length;
        port = here;
    }
    return port;
}

// What a project's org says about where to report. Nothing, for a project that
// names no org or an org that says nothing.
ParsedSentry orgSentry(PR)(auto ref const PR r, const(char)[] orgName) {
    if (orgName.length == 0) return ParsedSentry.init;
    foreach (i; 0 .. r.orgCount)
        if (r.orgs[i].name == orgName) return r.orgs[i].sentry;
    return ParsedSentry.init;
}

Flattened flatten(PR)(auto ref const PR r, size_t ritualIdx) {
    Flattened f;
    if (ritualIdx >= r.ritualCount) return f;
    auto rit = r.rituals[ritualIdx];
    f.system = rit.system;
    f.models[0] = rit.models;
    f.models[2] = r.models;
    f.sentry[0] = rit.sentry;
    f.sentry[2] = r.sentry;

    // Matched on name as well as path: four blocks share `/sbvh-nl/grove`, and
    // by path alone the first one's number would govern all of them.
    import ritual.position : MAX_GOTOS;
    f.maxGoto = MAX_GOTOS;
    foreach (pi; 0 .. r.projectCount) {
        if (r.projects[pi].path != rit.projectPath) continue;
        if (r.projects[pi].name != rit.projectName) continue;
        if (r.projects[pi].maxGoto > 0) f.maxGoto = r.projects[pi].maxGoto;
        f.models[1] = r.projects[pi].models;
        f.sentry[1] = r.projects[pi].sentry;
        // The project's org is the outer layer, and the top level stands in
        // only where the org says nothing.
        auto fromOrg = orgSentry(r, r.projects[pi].org);
        if (fromOrg.dsn.length > 0) f.sentry[2] = fromOrg;
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
                fr.dispatch = src.dispatch;
                fr.inputs = src.inputs;
                fr.msg = src.msg;
                fr.mic = src.mic;
                fr.pass = src.pass;
                fr.catches = src.catches;
                fr.catchCount = src.catchCount;
                // A run still going answers 75, and Hold is what "not yet"
                // already means to the walk.
                if (src.dispatch.length > 0 && fr.catchCount < fr.catches.length) {
                    import dispatch : DISPATCH_HOLD;
                    fr.catches[fr.catchCount++] = DISPATCH_HOLD;
                }
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

// "RITE_B does not start until RITE_A has completely finished" — a ritual is a
// list of rites-block references, and this is where one ends. flatten keeps
// `group` on every rite, so the boundary survives the flattening.
bool lastOfBlock(const Flattened f, size_t i) {
    if (i >= f.count) return false;
    if (i + 1 == f.count) return true;
    return f.rites[i].group != f.rites[i + 1].group;
}

long indexOfRite(const Flattened f, const(char)[] name) {
    foreach (i; 0 .. f.count)
        if (f.rites[i].name == name) return cast(long) i;
    return -1;
}

// "if END is already in the same rites block, prefer that END over the END outside of its goto originating rites block"

// A block gets copied whole and only the block renamed, so a name that came
// with the copy belongs to the copy. Falling through to the whole walk is
// what lets one block name a rite in another on purpose.
long indexOfRiteFrom(const Flattened f, const(char)[] group, const(char)[] name) {
    foreach (i; 0 .. f.count)
        if (f.rites[i].group == group && f.rites[i].name == name) return cast(long) i;
    return indexOfRite(f, name);
}

// What the spawn knows when it picks: the plan the last ask found and the
// latest reading of each window in tenths.
struct ModelInputs {
    bool planKnown;
    const(char)[] plan;
    bool fiveKnown;
    long fiveTenths;
    bool sevenKnown;
    long sevenTenths;
}

struct ModelChoice {
    const(char)[] model;
    // The rule that picked it, empty when no rule held.
    const(char)[] ruleInput;
    const(char)[] ruleValue;
    // The first rule that could not be asked, for want of its input.
    const(char)[] missing;
}

// Every rule, nearest layer first, then the nearest plain model, then the
// default.
ModelChoice resolveModel(const ParsedModels[3] layers, const ModelInputs i) {
    ModelChoice c;
    foreach (ref layer; layers) {
        foreach (k; 0 .. layer.ruleCount) {
            auto rule = layer.rules[k];
            bool known;
            bool holds;
            if (rule.input == "plan") {
                known = i.planKnown;
                holds = known && i.plan == rule.value;
            } else {
                bool five = rule.input == "five_hour";
                known = five ? i.fiveKnown : i.sevenKnown;
                holds = known && compares(five ? i.fiveTenths : i.sevenTenths, rule.value);
            }
            if (!known) {
                if (c.missing.length == 0) c.missing = rule.input;
                continue;
            }
            if (holds) {
                c.model = rule.model;
                c.ruleInput = rule.input;
                c.ruleValue = rule.value;
                return c;
            }
        }
    }
    foreach (ref layer; layers) {
        if (layer.model.length == 0) continue;
        c.model = layer.model;
        return c;
    }
    c.model = DEFAULT_MODEL;
    return c;
}

// "make the default for ritual runs Sonnet, not Opus"
// What a walk runs on when no models block says. It was the model of the
// session that performed it, which is whatever the operator was talking to.
enum DEFAULT_MODEL = "sonnet";

// ">90" and the like, against a reading in tenths of a percent.
bool compares(long tenths, const(char)[] want) {
    size_t n = 0;
    bool gt = false;
    bool lt = false;
    bool orEqual = false;
    if (n < want.length && want[n] == '>') { gt = true; n++; }
    else if (n < want.length && want[n] == '<') { lt = true; n++; }
    if (!gt && !lt) return false;
    if (n < want.length && want[n] == '=') { orEqual = true; n++; }

    long whole = 0;
    long tenth = 0;
    bool dot = false;
    bool gotTenth = false;
    bool digits = false;
    foreach (ch; want[n .. $]) {
        if (ch == '.') {
            if (dot) return false;
            dot = true;
            continue;
        }
        if (ch < '0' || ch > '9') return false;
        digits = true;
        if (!dot) whole = whole * 10 + (ch - '0');
        else if (!gotTenth) { tenth = ch - '0'; gotTenth = true; }
    }
    if (!digits) return false;

    auto limit = whole * 10 + tenth;
    if (gt) return orEqual ? tenths >= limit : tenths > limit;
    return orEqual ? tenths <= limit : tenths < limit;
}
