module nodeconfig;

// "so give it a config per ground per node"

// The nodes this ground speaks to when its controls name none: qntx blocks in nodes.pbt beside its
// store, read when it runs. What is not a node is said with its line, never read past.

import zbuf : ZBuf;

enum MAX_NODES = 8;

// The qntx block's fields, as qntxblock.d names them.
struct Node {
    const(char)[] url;
    const(char)[] token;   // the file its token is in; empty is QNTX_TOKEN, then ~/.qntx/token (token.d)
    const(char)[] model;   // what ground code prompts through the gateway
    const(char)[] gateway; // the node a prompt goes through; url when empty
}

struct NodeConfig {
    Node[MAX_NODES] nodes;
    size_t count;
    ZBuf said;
    const(char)[] why() return { return said.slice(); }
}

// ~/.local/share/ground/nodes.pbt: what the ground installed here keeps, beside its store (db.d).
const(char)[] nodesPath() {
    import db : storeDir;
    __gshared ZBuf p;
    p.reset();
    p.put(storeDir());
    p.put("/nodes.pbt");
    return p.slice();
}

// The nodes text names, into c. The text is held by the caller for as long as c is read.
void readNodes(ref NodeConfig c, const(char)[] text) {
    c.count = 0;
    c.said.reset();
    size_t line = 0;
    size_t opened = 0;
    bool inBlock = false;
    Node n;
    size_t at = 0;
    while (at < text.length) {
        auto end = at;
        while (end < text.length && text[end] != '\n') end++;
        line++;
        auto l = strip(text[at .. end]);
        at = end + 1;
        if (l.length == 0 || l[0] == '#') continue;
        if (!inBlock) {
            if (l != "qntx {") return refuse(c, line, "only qntx blocks name nodes here");
            inBlock = true;
            opened = line;
            n = Node.init;
            continue;
        }
        if (l == "}") {
            if (n.url.length == 0) return refuseOpened(c, line, opened, "names no url");
            if (c.count == MAX_NODES) return refuse(c, line, "names more nodes than a ground speaks to");
            c.nodes[c.count++] = n;
            inBlock = false;
            continue;
        }
        size_t colon = 0;
        while (colon < l.length && l[colon] != ':') colon++;
        auto key = strip(l[0 .. colon]);
        auto val = colon < l.length ? strip(l[colon + 1 .. $]) : l[0 .. 0];
        if (val.length < 2 || val[0] != '"' || val[$ - 1] != '"') {
            c.count = 0;
            c.said.put("nodes.pbt line ");
            c.said.putUint(line);
            c.said.put(": ");
            c.said.put(key);
            c.said.put(" is not a quoted value");
            return;
        }
        val = val[1 .. $ - 1];
        if (key == "url") n.url = val;
        else if (key == "token") n.token = val;
        else if (key == "model") n.model = val;
        else if (key == "gateway") n.gateway = val;
        else {
            c.count = 0;
            c.said.put("nodes.pbt line ");
            c.said.putUint(line);
            c.said.put(": a qntx block holds url:, token:, model: and gateway:, and ");
            c.said.put(key);
            c.said.put(" is none of them");
            return;
        }
    }
    if (inBlock) refuseOpened(c, line + 1, opened, "is not closed");
}

// The nodes in nodesPath(), into c; no file is no node and nothing to say.
void loadNodes(ref NodeConfig c) {
    import core.stdc.stdio : fopen, fread, fclose;
    import core.stdc.errno : errno, ENOENT;
    import core.stdc.string : strerror;
    __gshared char[16384] text = 0;
    c.count = 0;
    c.said.reset();
    auto path = nodesPath();
    __gshared ZBuf z;
    z.reset();
    z.put(path);
    auto f = fopen(z.ptr(), "rb");
    if (f is null) {
        if (errno == ENOENT) return;
        auto e = strerror(errno);
        size_t n = 0;
        while (e[n] != 0) n++;
        c.said.put(path);
        c.said.put(" would not open: ");
        c.said.put(e[0 .. n]);
        return;
    }
    auto n = fread(text.ptr, 1, text.length, f);
    fclose(f);
    if (n == text.length) {
        c.said.put(path);
        c.said.put(" is larger than ground reads");
        return;
    }
    readNodes(c, text[0 .. n]);
}

struct NodeHere {
    const(char)[] url;   // empty is no node to speak to
    const(char)[] token; // the file its token is in, as token.d reads it
    ZBuf said;
    const(char)[] why() return { return said.slice(); }
}

// The node sky streams to and lands its sand from: the one the held sand's qntx block names, else the
// one nodes.pbt names. nodes.pbt naming several is said: which one a machine pulls from is not decided.
// A template, so what imports nodeconfig for the file alone (ground code) compiles none of controls.
NodeHere nodeHere()() {
    import controls : qntxNode;
    NodeHere h;
    if (qntxNode.url.length > 0) {
        h.url = qntxNode.url;
        h.token = qntxNode.token;
        return h;
    }
    __gshared NodeConfig c;
    loadNodes(c);
    if (c.why().length > 0) {
        h.said.put(c.why());
        return h;
    }
    if (c.count == 1) {
        h.url = c.nodes[0].url;
        h.token = c.nodes[0].token;
    } else if (c.count > 1) {
        h.said.put(nodesPath());
        h.said.put(" names ");
        h.said.putUint(c.count);
        h.said.put(" nodes, and which one this ground pulls its sand from is not decided");
    }
    return h;
}

private void refuse(ref NodeConfig c, size_t line, const(char)[] what) {
    c.count = 0;
    c.said.put("nodes.pbt line ");
    c.said.putUint(line);
    c.said.put(": ");
    c.said.put(what);
}

private void refuseOpened(ref NodeConfig c, size_t line, size_t opened, const(char)[] what) {
    c.count = 0;
    c.said.put("nodes.pbt line ");
    c.said.putUint(line);
    c.said.put(": the qntx block opened on line ");
    c.said.putUint(opened);
    c.said.put(" ");
    c.said.put(what);
}

private const(char)[] strip(const(char)[] s) {
    size_t b = 0, e = s.length;
    while (b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '\r')) b++;
    while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t' || s[e - 1] == '\r')) e--;
    return s[b .. e];
}
