module concept;

// Where a case belongs. A word is how an example is recognised; a chapter is
// what it is an example of, and the grammar has more words than concepts.

struct Word {
    string word;
    // Empty when the word opens a block that shows nothing on its own.
    string chapter;
}

// Most specific first. A scope wrapping a control is an example of the
// control: the scope is where it sits, not what it shows.
immutable Word[] words = [
    Word("attestation", "attestation"),
    Word("include",     ""),
    Word("ritual",      "ritual"),
    Word("rites",       "ritual"),
    Word("permission",  "permission"),
    Word("control",     "control"),
    Word("project",     "project"),
    Word("scope",       "scope"),
];

// The order a reader meets them in, outermost to innermost. A scope carries
// the path and the event, and both govern whatever sits inside it, so it is
// met before the controls it governs rather than under them.
immutable string[] chapters = [
    "scope", "control", "project", "permission", "ritual", "attestation",
];

// The order a chapter's own cases are met in. A module and its test are one
// subject, so the name here carries neither the suffix nor the extension.
struct Reading {
    string chapter;
    immutable(string)[] mods;
}

// Without this a chapter opened on whichever filename sorted first, which is
// neither meaning nor chronology. What a control is comes before any one
// thing done with one, and the exemption comes last.
immutable Reading[] readings = [
    Reading("scope", ["matcher", "proto", "permission"]),
    Reading("control", ["hooks", "proto", "project", "control_ritual",
                        "proto_exec", "proto_ritual", "strop", "playbill",
                        "binary"]),
    // What a project is, then what one can name: its spec, and the routes
    // wind writes back from it.
    Reading("project", ["project", "routes"]),
];

// "so its deliberate which terms deserve a glossary entry"
// Which chapter owns a module, and so which section its terms are set in. A
// reading names proto twice; this names each module once, or not at all.
struct Owner {
    string chapter;
    immutable(string)[] mods;
}

immutable Owner[] owners = [
    Owner("scope",       ["matcher", "scratchdir"]),
    Owner("control",     ["hooks", "strop", "exec"]),
    Owner("project",     ["project", "routes"]),
    Owner("permission",  ["permission", "sessionmode"]),
    Owner("ritual",      ["ritual/resolve", "rite", "ritual/position", "ritual/run",
                          "ritual/drive", "mic", "receiver", "ritual/delivery",
                          "dispatch"]),
    Owner("attestation", ["db", "attest", "backend", "provenance", "queued"]),
];

// Who owns the repos the examples are about. Four owners, each with a world
// to draw names from, so the book does not read as one company's.
struct Org {
    string slug;    // what origin: carries
    string name;
    string world;   // the names its repos, subjects and predicates draw on
    string chapter; // where it carries the examples
}

// "we want for orgs a variety"
// Checkouts live in the grove whoever owns them: /Users/me/grove/<repo>. A
// backend is a pond, https://pond.<slug>.invalid, or localhost when local.
immutable Org[] orgs = [
    Org("veenpolder", "Veenpolder",                     "dijkwacht, peil, sluis, gemaal",  "project"),
    Org("lille",      "Châtellenie de Lille",           "cens, terrier, ban, seigneur",    "permission"),
    Org("ffestiniog", "Rheilffordd Ffestiniog",         "amserlen, signal, tocyn, gorsaf", "control"),
    Org("coinflip",   "Coinflip Ltd.",                  "heads, tails, munt, kop",         "ritual"),
];

string chapterOf(string mod) {
    foreach (o; owners)
        foreach (m; o.mods) if (m == mod) return o.chapter;
    return "";
}

// The subject a file is about. A module and its test are one subject, and a
// module under a directory of source/ carries that directory with it.
string moduleName(string path) {
    auto s = path;
    if (s.length > 7 && s[0 .. 7] == "source/") s = s[7 .. $];
    if (s.length > 2 && s[$ - 2 .. $] == ".d") s = s[0 .. $ - 2];
    if (s.length > 5 && s[$ - 5 .. $] == "_test") s = s[0 .. $ - 5];
    return s;
}

// The module a chapter opens on: the first one its order names. Its heading is
// the only prose in the book that is about a concept rather than about a case,
// and a chapter with no order of its own opens on nothing.
string opener(string chapter) {
    foreach (r; readings)
        if (r.chapter == chapter && r.mods.length > 0) return r.mods[0];
    return "";
}

// How early a module's cases stand in a chapter. A module no order names
// answers size_t.max, so it lands behind every one that is named rather than
// in front of the definition.
size_t rank(string chapter, string mod) {
    foreach (r; readings) {
        if (r.chapter != chapter) continue;
        foreach (i, m; r.mods) if (m == mod) return i;
        break;
    }
    return size_t.max;
}

bool isConcept(string name) {
    foreach (c; chapters) if (c == name) return true;
    return false;
}

// The concept a pbt literal is an example of.
string conceptOf(string pbt) {
    // A scope inside a scope is what the example is about. One scope is only
    // where its control sits; two is the lesson, and what the inner one takes
    // from the outer is the thing being shown.
    if (opensCount(pbt, "scope") >= 2) return "scope";

    foreach (w; words) if (opensBlock(pbt, w.word)) return w.chapter;
    return "";
}

private bool opensBlock(string pbt, string word) {
    return opensCount(pbt, word) > 0;
}

// How many lines of the literal open this block. The word starts a line, and
// what follows is a brace, a name, a dot or a quoted path.
private size_t opensCount(string pbt, string word) {
    size_t found = 0;
    size_t i = 0;
    while (i <= pbt.length) {
        size_t start = i;
        while (i < pbt.length && pbt[i] != '\n') i++;
        auto line = pbt[start .. i];
        i++;

        size_t p = 0;
        while (p < line.length && (line[p] == ' ' || line[p] == '\t')) p++;
        auto rest = line[p .. $];
        if (rest.length < word.length) continue;
        if (rest[0 .. word.length] != word) continue;

        if (rest.length == word.length) { found++; continue; }
        auto c = rest[word.length];
        if (c == ' ' || c == '{' || c == '.' || c == '"') found++;
    }
    return found;
}
