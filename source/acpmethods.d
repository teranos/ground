module acpmethods;

// Every ACP method by its name in schema-v1.26.0's meta.json, read at compile time from the file libacp
// generates acp_methods.h from, and named as the TypeScript SDK names its tables from the same file.

private enum META = import("libacp/schema/v1/meta.json");

// meta.json's groups, the name each table has, and the prefix acp_methods.h gives its names.
private static immutable string[3][3] GROUPS = [
    ["agentMethods", "AGENT_METHODS", "ACP_AGENT_"],
    ["clientMethods", "CLIENT_METHODS", "ACP_CLIENT_"],
    ["protocolMethods", "PROTOCOL_METHODS", "ACP_PROTOCOL_"],
];

private size_t skipSpace()(string s, size_t p) {
    while (p < s.length && (s[p] == ' ' || s[p] == '\n' || s[p] == '\r' || s[p] == '\t')) p++;
    return p;
}

// The string at p, which meta.json writes without escapes; the position after it.
private string stringAt()(string s, ref size_t p) {
    assert(p < s.length && s[p] == '"', "meta.json has no string where a method is");
    auto from = ++p;
    while (p < s.length && s[p] != '"') {
        assert(s[p] != '\\', "meta.json escapes a method's name, which this reader does not read");
        p++;
    }
    assert(p < s.length, "meta.json ends inside a string");
    return s[from .. p++];
}

// Each name in a group and its wire name, in meta.json's order.
private string[2][] methodsIn()(string group) {
    string key = `"` ~ group ~ `"`;
    size_t at = 0;
    while (at + key.length <= META.length && META[at .. at + key.length] != key) at++;
    assert(at + key.length <= META.length, "meta.json names no " ~ group);
    size_t p = skipSpace(META, at + key.length);
    assert(p < META.length && META[p] == ':', "meta.json's " ~ group ~ " has no value");
    p = skipSpace(META, p + 1);
    assert(p < META.length && META[p] == '{', "meta.json's " ~ group ~ " is no object");
    p = skipSpace(META, p + 1);
    string[2][] all;
    while (p < META.length && META[p] != '}') {
        auto name = stringAt(META, p);
        p = skipSpace(META, p);
        assert(p < META.length && META[p] == ':', "meta.json's " ~ name ~ " has no wire name");
        p = skipSpace(META, p + 1);
        all ~= [name, stringAt(META, p)];
        p = skipSpace(META, p);
        if (p < META.length && META[p] == ',') p = skipSpace(META, p + 1);
    }
    assert(p < META.length, "meta.json's " ~ group ~ " does not close");
    return all;
}

private string table()(string group, string name) {
    string s = "struct " ~ name ~ " {";
    foreach (m; methodsIn(group)) s ~= " enum " ~ m[0] ~ " = \"" ~ m[1] ~ "\";";
    return s ~ " }";
}

static foreach (g; GROUPS) mixin(table(g[0], g[1]));

// A method by every name it has: its table's, AGENT_METHODS.session_new; acp_methods.h's,
// ACP_AGENT_SESSION_NEW; and the wire's, session/new.
private struct Method { string named; string macroName; string wire; }

private Method[] methods()() {
    Method[] all;
    foreach (g; GROUPS)
        foreach (m; methodsIn(g[0])) {
            string upper;
            foreach (c; m[0]) upper ~= c >= 'a' && c <= 'z' ? cast(char)(c - 32) : c;
            all ~= Method(g[1] ~ "." ~ m[0], g[2] ~ upper, m[1]);
        }
    return all;
}

// Folded at compile time, so a lookup reads static data: betterC has no GC.
private enum Method[] METHODS = methods();
private static immutable Method[METHODS.length] TABLE = METHODS;

// The name a wire name has in its table, as code names it; null for one meta.json does not name.
string methodNamed(const(char)[] wire) {
    foreach (ref m; TABLE) if (m.wire == wire) return m.named;
    return null;
}

// The wire name of a method as code names it, AGENT_METHODS.session_new; null for one meta.json does not name.
string wireOf(const(char)[] named) {
    foreach (ref m; TABLE) if (m.named == named) return m.wire;
    return null;
}

// The wire name of a method as acp_methods.h names it, ACP_AGENT_SESSION_NEW; null for one it does not.
string wireOfMacro(const(char)[] macroName) {
    foreach (ref m; TABLE) if (m.macroName == macroName) return m.wire;
    return null;
}
