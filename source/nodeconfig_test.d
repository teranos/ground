module nodeconfig_test;

// "so give it a config per ground per node"

import nodeconfig : NodeConfig, readNodes, nodesPath;

// One qntx block per node, as a pbt names one: url, and the file its token is in.
unittest {
    NodeConfig c;
    readNodes(c, "qntx {\n  url: \"https://api.q.sbvh.nl\"\n  token: \"~/.qntx/token\"\n}\n" ~
                 "# k's own\nqntx {\n  url: \"http://kapteyn:8770\"\n}\n");
    assert(c.why().length == 0, c.why());
    assert(c.count == 2);
    assert(c.nodes[0].url == "https://api.q.sbvh.nl");
    assert(c.nodes[0].token == "~/.qntx/token");
    assert(c.nodes[1].url == "http://kapteyn:8770");
    assert(c.nodes[1].token.length == 0, "no token: is QNTX_TOKEN, then ~/.qntx/token");
}

// What is not a node is said with its line, and names no node.
unittest {
    NodeConfig c;
    readNodes(c, "qntx {\n  url: \"https://a\"\n  colour: \"red\"\n}\n");
    assert(c.count == 0);
    assert(c.why() == "nodes.pbt line 3: a qntx block holds url:, token:, model: and gateway:, and colour is none of them", c.why());

    // The qntx block as pbt names it: ground code prompts with model:, through gateway: when it is set.
    NodeConfig code;
    readNodes(code, "qntx {\n  url: \"https://a\"\n  model: \"m\"\n  gateway: \"https://g\"\n}\n");
    assert(code.why().length == 0, code.why());
    assert(code.nodes[0].model == "m" && code.nodes[0].gateway == "https://g");

    NodeConfig open;
    readNodes(open, "qntx {\n  url: \"https://a\"\n");
    assert(open.count == 0);
    assert(open.why() == "nodes.pbt line 3: the qntx block opened on line 1 is not closed", open.why());

    NodeConfig nourl;
    readNodes(nourl, "qntx {\n  token: \"~/t\"\n}\n");
    assert(nourl.count == 0);
    assert(nourl.why() == "nodes.pbt line 3: the qntx block opened on line 1 names no url", nourl.why());

    NodeConfig stray;
    readNodes(stray, "project {\n}\n");
    assert(stray.count == 0);
    assert(stray.why() == "nodes.pbt line 1: only qntx blocks name nodes here", stray.why());
}

// Nothing written is no node and nothing to say.
unittest {
    NodeConfig c;
    readNodes(c, "");
    assert(c.count == 0);
    assert(c.why().length == 0);
}

// The node sky streams to and lands from: the one the held sand names, else the one nodes.pbt names.
unittest {
    import nodeconfig : nodeHere;
    import controls : holdSand;
    import sand.view : Sand;
    import sand.builtin : builtinSand;
    import core.stdc.stdio : fopen, fputs, fclose;
    import zbuf : ZBuf;
    scope (exit) holdSand(null);

    static void write(const(char)[] text) {
        ZBuf p;
        p.put(nodesPath());
        auto f = fopen(p.ptr(), "wb");
        assert(f !is null);
        ZBuf t;
        t.put(text);
        fputs(t.ptr(), f);
        fclose(f);
    }
    static void remove() {
        import errors : unlink;
        ZBuf p;
        p.put(nodesPath());
        cast(void) unlink(p.ptr());
    }
    scope (exit) remove();

    // A sand that names no node: the floor's, or a sand built without a qntx block.
    __gshared Sand bare;
    bare = builtinSand;
    bare.parsed.qntx = typeof(bare.parsed.qntx).init;
    holdSand(&bare);

    remove();
    auto none = nodeHere();
    assert(none.url.length == 0 && none.why().length == 0, "no node named anywhere is no node, and nothing to say");

    write("qntx {\n  url: \"https://api.q.sbvh.nl\"\n  token: \"~/.qntx/q\"\n}\n");
    auto one = nodeHere();
    assert(one.url == "https://api.q.sbvh.nl", one.url);
    assert(one.token == "~/.qntx/q");

    write("qntx {\n  url: \"https://a\"\n  colour: \"red\"\n}\n");
    auto bad = nodeHere();
    assert(bad.url.length == 0);
    assert(bad.why() == "nodes.pbt line 3: a qntx block holds url:, token:, model: and gateway:, and colour is none of them", bad.why());

    write("qntx {\n  url: \"https://a\"\n}\nqntx {\n  url: \"https://b\"\n}\n");
    auto two = nodeHere();
    assert(two.url.length == 0);
    assert(two.why().length > 0, "two nodes and no word on which one sky pulls from is said, never guessed");

    // "there is q, you auth to it, there is k ground writes into its ground namespace"
    // "and q gies the sand"
    // The stream writes to url with the block's token; the sand comes from the gateway, the node
    // signed in to with ~/.qntx/token. A block that names one node gets both from it.
    write("qntx {\n  url: \"http://kapteyn:8770\"\n  token: \"~/.qntx/ground-token\"\n  gateway: \"https://api.q.sbvh.nl\"\n}\n");
    auto split = nodeHere();
    assert(split.url == "http://kapteyn:8770" && split.token == "~/.qntx/ground-token");
    assert(split.sandUrl == "https://api.q.sbvh.nl", split.sandUrl);
    assert(split.sandToken.length == 0, "the gateway is spoken to with the signed-in token");
    write("qntx {\n  url: \"http://10.88.0.2:8770\"\n  token: \"~/t\"\n}\n");
    auto alone = nodeHere();
    assert(alone.sandUrl == "http://10.88.0.2:8770" && alone.sandToken == "~/t");

    // A sand that names its node keeps it, whatever nodes.pbt says.
    __gshared Sand named;
    named = builtinSand;
    named.parsed.qntx.present = true;
    named.parsed.qntx.url = "http://kapteyn:8770";
    named.parsed.qntx.gateway = "https://api.q.sbvh.nl";
    holdSand(&named);
    write("qntx {\n  url: \"https://elsewhere\"\n}\n");
    auto held = nodeHere();
    assert(held.url == "http://kapteyn:8770");
    assert(held.sandUrl == "https://api.q.sbvh.nl" && held.sandToken.length == 0);
}

// It lives with ground's store: what the ground installed here reads, and nothing of a repository's.
unittest {
    import db : storeDir;
    auto p = nodesPath();
    auto dir = storeDir();
    assert(p.length == dir.length + "/nodes.pbt".length);
    assert(p[0 .. dir.length] == dir);
    assert(p[dir.length .. $] == "/nodes.pbt");
}
