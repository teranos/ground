module openapi;

// The digest wind writes into a project block from that project's OpenAPI
// spec: one route per path, the word a reply is matched on, and the text
// ground injects when the word is said. Ground never sees the JSON.

import std.json : JSONValue, JSONType, parseJSON;

// The second segment names the route; the first alone is a namespace shared
// by dozens of paths. A one-segment path has only its first. Parameters in
// braces are not words anyone says.
string routeWord(string path) {
    auto segs = segments(path);
    if (segs.length == 0) return "";
    return segs.length >= 2 ? segs[1] : segs[0];
}

// The segments a person could say: no empties, no parameters in braces.
string[] segments(string path) {
    string[] segs;
    size_t i = 0;
    while (i < path.length) {
        while (i < path.length && path[i] == '/') i++;
        auto start = i;
        while (i < path.length && path[i] != '/') i++;
        auto seg = path[start .. i];
        if (seg.length == 0 || seg[0] == '{') continue;
        segs ~= seg;
    }
    return segs;
}

// The block text, ready to sit inside the project before its closing brace.
// Paths come out sorted so sand is byte-stable across runs.
string renderRoutes(string specJson) {
    auto j = parseJSON(specJson);
    if (j.type != JSONType.object || "paths" !in j.object) return "";
    auto paths = j["paths"];
    if (paths.type != JSONType.object) return "";

    string[] keys;
    foreach (k, v; paths.object) keys ~= k;
    sortStrings(keys);

    string out_;
    foreach (path; keys) {
        auto word = routeWord(path);
        if (word.length == 0) continue;
        auto item = paths[path];
        if (item.type != JSONType.object) continue;
        auto text = renderRoute(path, item);
        // Ground delivers a text whole or not at all, in a buffer this size.
        // One that could never fit would be matched every turn and never said.
        if (text.length > MAX_ROUTE_TEXT)
            throw new Exception("openapi: route text for " ~ path ~ " exceeds "
                ~ "the delivery buffer; shorten its description");
        out_ ~= block(path, word, text);
    }
    out_ ~= renderNamespaces(keys, paths);
    return out_;
}

enum MAX_ROUTE_TEXT = 4000;

// A first segment said alone shows what sits under it, paths only. What any
// of them does waits for its own word.
string renderNamespaces(const(string)[] keys, JSONValue paths) {
    string[] names;
    foreach (path; keys) {
        auto segs = segments(path);
        if (segs.length >= 2) addUnique(names, segs[0]);
    }
    sortStrings(names);

    string out_;
    foreach (ns; names) {
        string text = "/" ~ ns;
        foreach (path; keys) {
            auto segs = segments(path);
            if (segs.length == 0 || segs[0] != ns) continue;
            auto item = paths[path];
            if (item.type != JSONType.object) continue;
            text ~= "\n" ~ methodsOf(item) ~ " " ~ path;
        }
        if (text.length > MAX_ROUTE_TEXT)
            throw new Exception("openapi: the index under /" ~ ns ~ " exceeds "
                ~ "the delivery buffer");
        out_ ~= block("/" ~ ns, ns, text);
    }
    return out_;
}

string block(string path, string word, string text) {
    return "  route {\n    path: \"" ~ path ~ "\"\n    word: \"" ~ word
        ~ "\"\n    text: `" ~ text ~ "`\n  }\n";
}

private:

static immutable methodOrder = ["get", "post", "put", "patch", "delete", "head", "options"];
static immutable methodUpper = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"];

// One header line for the path, then what its operations say. The description
// holds the summary as its first line, so it stands in for both; two methods
// that say the same thing say it once.
string methodsOf(JSONValue item) {
    string methods;
    foreach (mi, m; methodOrder) {
        if (m !in item.object) continue;
        if (item[m].type != JSONType.object) continue;
        if (methods.length > 0) methods ~= " ";
        methods ~= methodUpper[mi];
    }
    return methods;
}

string renderRoute(string path, JSONValue item) {
    auto methods = methodsOf(item);
    string[] reach;
    string[] handlers;
    string[] bodies;

    foreach (mi, m; methodOrder) {
        if (m !in item.object) continue;
        auto op = item[m];
        if (op.type != JSONType.object) continue;

        if ("x-qntx-reach" in op.object && op["x-qntx-reach"].type == JSONType.array)
            foreach (r; op["x-qntx-reach"].array)
                if (r.type == JSONType.string) addUnique(reach, r.str);

        if ("x-qntx-handler" in op.object && op["x-qntx-handler"].type == JSONType.string)
            addUnique(handlers, op["x-qntx-handler"].str);

        string said;
        if ("description" in op.object && op["description"].type == JSONType.string)
            said = op["description"].str;
        else if ("summary" in op.object && op["summary"].type == JSONType.string)
            said = op["summary"].str;
        if (said.length > 0) addUnique(bodies, said);
    }

    string text = methods ~ " " ~ path;
    if (reach.length > 0) text ~= "  reach: " ~ joined(reach, ", ");
    if (handlers.length > 0) text ~= "  handler: " ~ joined(handlers, ", ");
    foreach (b; bodies) text ~= "\n" ~ b;
    return safeForBacktick(text);
}

// The pbt lexer ends a backtick string at the next backtick, so one inside
// would hand the rest of the text to the parser as pbt.
string safeForBacktick(string s) {
    string r;
    foreach (c; s) {
        if (c == '`') r ~= '\'';
        else if (c == '\r') continue;
        else r ~= c;
    }
    return r;
}

void addUnique(ref string[] list, string s) {
    foreach (x; list) if (x == s) return;
    list ~= s;
}

string joined(const(string)[] parts, string sep) {
    string r;
    foreach (i, p; parts) {
        if (i > 0) r ~= sep;
        r ~= p;
    }
    return r;
}

// Insertion sort: CTFE-safe, and the list is a hundred paths.
void sortStrings(ref string[] a) {
    foreach (i; 1 .. a.length) {
        auto key = a[i];
        size_t j = i;
        while (j > 0 && a[j - 1] > key) { a[j] = a[j - 1]; j--; }
        a[j] = key;
    }
}
