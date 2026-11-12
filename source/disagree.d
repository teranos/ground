module disagree;

// "ground should own it entirely"
// "User A keeps both, but ground win's always and the json can't disagree with ground"
// "show the disagreement"
// "make it easy to spot and remove"
// "remove as in json side"
//
// Claude Code keeps rules of its own, in the permissions of its settings JSON:
// allow, ask and deny. Ground's rules are the ones that stand. A JSON rule that
// says other than ground says for the same thing is a disagreement: it is
// shown, with the file it is in, and taken out of the JSON on one word.

import zbuf : ZBuf;
import permission : Decision;
import effort : rootAt, memberOf, skipSpace, skipString;

enum BOOK_COMMAND = q"EOS
# where a rule in Claude Code's settings JSON says other than ground says:
ground disagreements

# take those rules out of the JSON, so only ground's stand:
ground agree
EOS";

// What the JSON says of a rule, by the list it is in.
enum Json { allows, asks, denies }

immutable string[3] LISTS = ["allow", "ask", "deny"];
immutable string[3] JSON_SAYS = ["allows", "asks", "denies"];

const(char)[] groundSays(Decision d) {
    final switch (d) {
        case Decision.allow: return "allows";
        case Decision.ask: return "asks";
        case Decision.deny: return "denies";
        case Decision.none: return "says nothing of";
    }
}

// One rule of the JSON that says other than ground: where its string stands in
// the text, quotes and all.
struct Found {
    Json json;
    Decision ground;
    size_t at, end;
}

struct FoundIn {
    Found[256] all;
    size_t count;
    size_t more; // found past what all holds
}

// What a rule is about: the tool before its parenthesis, and inside it the
// words the rule stands for, less the wildcard it ends in. `Bash(make
// install*)` is Bash and `make install`; `WebSearch` is WebSearch and nothing.
void ruleParts(const(char)[] rule, out const(char)[] tool, out const(char)[] command) {
    size_t open = rule.length;
    foreach (i, c; rule) if (c == '(') { open = i; break; }
    tool = rule[0 .. open];
    command = "";
    if (open == rule.length || rule[$ - 1] != ')') return;
    auto inner = rule[open + 1 .. $ - 1];
    if (inner.length >= 2 && inner[$ - 2 .. $] == ":*") inner = inner[0 .. $ - 2];
    while (inner.length > 0 && (inner[$ - 1] == '*' || inner[$ - 1] == ' ')) inner = inner[0 .. $ - 1];
    command = inner;
}

// Whether the JSON's word and ground's are two words. Where ground says
// nothing, there is nothing to disagree with.
bool disagrees(Json json, Decision ground) {
    final switch (ground) {
        case Decision.none: return false;
        case Decision.allow: return json != Json.allows;
        case Decision.ask: return json != Json.asks;
        case Decision.deny: return json != Json.denies;
    }
}

// Every rule in the settings text that says other than ground says, for a
// session in cwd, in mode.
void disagreementsIn(const(char)[] text, const(char)[] cwd, const(char)[] mode, ref FoundIn found) {
    import controls : permissionScopes;
    import permissionrequest : permissionFor;
    found.count = 0;
    found.more = 0;
    auto root = rootAt(text);
    if (root >= text.length) return;
    auto perms = memberOf(text, root, "permissions");
    if (!perms.ok) return;
    foreach (k, key; LISTS) {
        auto list = memberOf(text, perms.valAt, key);
        if (!list.ok || list.valAt >= text.length || text[list.valAt] != '[') continue;
        size_t i = skipSpace(text, list.valAt + 1);
        while (i < text.length && text[i] == '"') {
            auto end = skipString(text, i);
            if (end < i + 2 || end > text.length) break;
            const(char)[] tool, command;
            ruleParts(text[i + 1 .. end - 1], tool, command);
            auto ground = permissionFor(permissionScopes, cwd, tool, command, mode).decision;
            if (disagrees(cast(Json) k, ground)) {
                if (found.count < found.all.length) found.all[found.count++] = Found(cast(Json) k, ground, i, end);
                else found.more++;
            }
            i = skipSpace(text, end);
            if (i < text.length && text[i] == ',') i = skipSpace(text, i + 1);
        }
    }
}

// The settings text with every rule in found taken out of its list, and
// nothing else touched: a list is written again with the rules that stay, in
// the spacing it had. The length written, 0 when it did not fit.
size_t agreed(const(char)[] text, ref const FoundIn found, char[] dest) {
    size_t o = 0;
    bool over = false;
    void put(const(char)[] s) {
        foreach (c; s) { if (o < dest.length) dest[o++] = c; else over = true; }
    }
    bool out_(size_t at) {
        foreach (i; 0 .. found.count) if (found.all[i].at == at) return true;
        return false;
    }

    auto root = rootAt(text);
    auto perms = root < text.length ? memberOf(text, root, "permissions") : typeof(memberOf(text, 0, "")).init;
    if (!perms.ok) { put(text); return over ? 0 : o; }

    // The three lists, in the order they stand in the file.
    size_t[3] starts, ends;
    size_t lists = 0;
    foreach (key; LISTS) {
        auto list = memberOf(text, perms.valAt, key);
        if (!list.ok || list.valAt >= text.length || text[list.valAt] != '[') continue;
        size_t at = lists;
        while (at > 0 && starts[at - 1] > list.valAt) { starts[at] = starts[at - 1]; ends[at] = ends[at - 1]; at--; }
        starts[at] = list.valAt;
        ends[at] = list.valEnd;
        lists++;
    }

    size_t done = 0;
    foreach (l; 0 .. lists) {
        put(text[done .. starts[l] + 1]);
        // The spacing before the first rule is the spacing before each.
        auto first = skipSpace(text, starts[l] + 1);
        auto gap = text[starts[l] + 1 .. first];
        size_t kept = 0;
        size_t i = first;
        size_t last = first;
        while (i < text.length && text[i] == '"') {
            auto end = skipString(text, i);
            if (!out_(i)) {
                if (kept > 0) put(",");
                put(gap);
                put(text[i .. end]);
                kept++;
            }
            last = end;
            i = skipSpace(text, end);
            if (i < text.length && text[i] == ',') i = skipSpace(text, i + 1);
        }
        // What stood between the last rule and the bracket closes the list
        // again, when a rule is left in it.
        if (kept > 0) put(text[last .. ends[l] - 1]);
        put("]");
        done = ends[l];
    }
    put(text[done .. $]);
    return over ? 0 : o;
}

// ---- the files, and the two commands ----

private __gshared char[262144] fileText;
private __gshared char[262144 + 64] fileFresh;

// The settings files Claude Code reads for a session in cwd: the person's two,
// and the two of every directory from cwd up to the home. Each path with a NUL
// after it.
void settingsFiles(const(char)[] cwd, ref ZBuf paths) {
    import core.stdc.stdlib : getenv;
    paths.reset();
    auto h = getenv("HOME\0".ptr);
    if (h is null) return;
    size_t hn = 0;
    while (h[hn] != 0) hn++;
    auto home = h[0 .. hn];
    void two(const(char)[] dir) {
        foreach (name; ["/.claude/settings.json", "/.claude/settings.local.json"]) {
            paths.put(dir);
            paths.put(name);
            paths.putChar('\0');
        }
    }
    two(home);
    auto dir = cwd;
    while (dir.length > 1 && dir != home) {
        // Under the home only: a directory elsewhere is climbed to the root.
        two(dir);
        size_t cut = dir.length;
        while (cut > 0 && dir[cut - 1] != '/') cut--;
        dir = cut > 1 ? dir[0 .. cut - 1] : dir[0 .. 0];
    }
}

// The file at path, read whole. -1 when there is none; -2 when it is larger
// than is read here, which is said.
private ptrdiff_t readWhole(const(char)* path) {
    import core.stdc.stdio : fopen, fread, fclose, fgetc, EOF, stderr, fputs;
    auto f = fopen(path, "r");
    if (f is null) return -1;
    auto got = fread(fileText.ptr, 1, fileText.length, f);
    bool more = got == fileText.length && fgetc(f) != EOF;
    fclose(f);
    if (more) {
        fputs("ground: ", stderr);
        fputs(path, stderr);
        fputs(" is larger than ground reads, so its rules were not compared with ground's\n", stderr);
        return -2;
    }
    return cast(ptrdiff_t) got;
}

// The mode a session starts in, as the person's settings say: the mode ground's
// rules are asked in when no session says its own.
const(char)[] startingMode(char[] buf) {
    import core.stdc.stdlib : getenv;
    auto h = getenv("HOME\0".ptr);
    if (h is null) return "default";
    __gshared ZBuf path;
    path.reset();
    size_t hn = 0;
    while (h[hn] != 0) hn++;
    path.put(h[0 .. hn]);
    path.put("/.claude/settings.json");
    auto got = readWhole(path.ptr());
    if (got <= 0) return "default";
    auto text = fileText[0 .. got];
    auto root = rootAt(text);
    if (root >= text.length) return "default";
    auto perms = memberOf(text, root, "permissions");
    if (!perms.ok) return "default";
    auto mode = memberOf(text, perms.valAt, "defaultMode");
    if (!mode.ok || mode.valAt >= text.length || text[mode.valAt] != '"') return "default";
    auto said = text[mode.valAt + 1 .. mode.valEnd - 1];
    if (said.length > buf.length) return "default";
    buf[0 .. said.length] = said[];
    return buf[0 .. said.length];
}

// How many rules in the JSON a session in cwd reads say other than ground.
size_t countDisagreements(const(char)[] cwd, const(char)[] mode) {
    __gshared ZBuf paths;
    __gshared FoundIn found;
    settingsFiles(cwd, paths);
    size_t total = 0;
    size_t at = 0;
    auto all = paths.slice();
    while (at < all.length) {
        auto end = at;
        while (all[end] != 0) end++;
        auto got = readWhole(&all[at]);
        if (got > 0) {
            disagreementsIn(fileText[0 .. got], cwd, mode, found);
            total += found.count + found.more;
        }
        at = end + 1;
    }
    return total;
}

private int walk(bool takeOut) {
    import core.stdc.stdio : stdout, stderr, fputs, fopen, fwrite, fclose, rename, remove;
    import core.sys.posix.unistd : getcwd;
    char[4096] cwdBuf = 0;
    if (getcwd(cwdBuf.ptr, cwdBuf.length) is null) {
        fputs("ground: where this is run from could not be read, so no settings were found\n", stderr);
        return 1;
    }
    size_t cn = 0;
    while (cwdBuf[cn] != 0) cn++;
    auto cwd = cwdBuf[0 .. cn];
    char[32] modeBuf = 0;
    __gshared char[32] modeKept;
    auto m = startingMode(modeBuf[]);
    modeKept[0 .. m.length] = m[];
    auto mode = modeKept[0 .. m.length];

    __gshared ZBuf paths;
    __gshared FoundIn found;
    __gshared ZBuf line;
    settingsFiles(cwd, paths);
    size_t total = 0, files = 0;
    int failed = 0;
    size_t at = 0;
    auto all = paths.slice();
    while (at < all.length) {
        auto end = at;
        while (all[end] != 0) end++;
        auto path = all[at .. end];
        auto got = readWhole(&all[at]);
        at = end + 1;
        if (got == -2) { failed = 1; continue; }
        if (got <= 0) continue;
        files++;
        auto text = fileText[0 .. got];
        disagreementsIn(text, cwd, mode, found);
        foreach (i; 0 .. found.count) {
            auto f = found.all[i];
            const(char)[] tool, command;
            auto rule = text[f.at + 1 .. f.end - 1];
            ruleParts(rule, tool, command);
            // Two lines under each other, what each says in one column and
            // what it says it of in the next.
            void said(const(char)[] who, const(char)[] says, const(char)[] of) {
                line.put(who);
                line.put(says);
                foreach (_; says.length .. 8) line.put(" ");
                line.put(of);
                line.put("\n");
            }
            line.reset();
            __gshared ZBuf about;
            about.reset();
            about.put(tool);
            if (command.length > 0) { about.put(" "); about.put(command); }
            said("ground  ", groundSays(f.ground), about.slice());
            said("JSON    ", JSON_SAYS[f.json], rule);
            line.put("                ");
            line.put(path);
            line.put(takeOut ? "\n" : "\n\n");
            fputs(line.ptr(), stdout);
        }
        total += found.count;
        if (found.more > 0) {
            fputs("ground: more rules disagree in this file than are shown at once; run it again after these\n", stderr);
            failed = 1;
        }
        if (!takeOut || found.count == 0) continue;

        auto n = agreed(text, found, fileFresh[]);
        bool written = false;
        __gshared ZBuf fresh;
        fresh.reset();
        fresh.put(path);
        fresh.put(".ground-new");
        if (n > 0) {
            auto out_ = fopen(fresh.ptr(), "w");
            if (out_ !is null) {
                written = fwrite(fileFresh.ptr, 1, n, out_) == n;
                if (fclose(out_) != 0) written = false;
                if (written) written = rename(fresh.ptr(), &all[at - path.length - 1]) == 0;
                if (!written) remove(fresh.ptr());
            }
        }
        line.reset();
        if (written) {
            line.put("taken out of the JSON\n\n");
            fputs(line.ptr(), stdout);
        } else {
            line.put("ground agree: ");
            line.put(path);
            line.put(" was not written, so its rules still stand there\n");
            fputs(line.ptr(), stderr);
            failed = 1;
        }
    }
    if (total == 0 && failed == 0) {
        line.reset();
        line.put("Claude Code's JSON says nothing other than ground says, in the ");
        line.putUint(files);
        line.put(" settings files read from here.\n");
        fputs(line.ptr(), stdout);
    }
    return failed;
}

// ground disagreements: each rule in the JSON that says other than ground.
int handleDisagreements() { return walk(false); }

// ground agree: the same, and each is taken out of the JSON.
int handleAgree() { return walk(true); }
