module prompt_test;

// "we use the qntx openrouter plugin"
// "as the endpoint"
// A prompt is one turn through the node's gateway, and its tools are libmcp's.

import code.prompt : putToolName, serverOf, toolOf, promptText, Blocks, userMessage, requestBody, fileUriPath;
import code.reply : Reply;

// A tool is named to the model as its server and itself, so two servers'
// "search" stay two tools, and the name comes apart the same way.
private string toolName()(string server, string tool) {
    Reply r;
    putToolName(r, server, tool);
    return r.slice().idup;
}
static assert(toolName("test", "echo") == "test__echo");
static assert(serverOf("test__echo") == "test");
static assert(toolOf("test__echo") == "echo");
static assert(serverOf("echo") == "");
static assert(toolOf("echo") == "echo");

// The prompt's text blocks, in order, one line each; a resource_link is handed
// back to be read, a name and a uri each; a block of another kind has no text
// to give, and its type is said instead of dropped. libacp reads the blocks.
private struct Read {
    Reply text, other, links, embedded, images, said;
    Blocks blocks;
    this(string params) { blocks = promptText(params, text, other, links, embedded, images, said); }
    void dispose() { text.dispose(); other.dispose(); links.dispose(); embedded.dispose(); images.dispose(); said.dispose(); }
}
private bool textIs()(string params, string want) {
    auto p = Read(params); scope(exit) p.dispose();
    return p.text.slice() == want;
}
private bool otherIs()(string params, string want) {
    auto p = Read(params); scope(exit) p.dispose();
    return p.blocks == Blocks.read ? want == "all text" : p.blocks == Blocks.other && p.other.slice() == want;
}
private bool linksAre()(string params, string want) {
    auto p = Read(params); scope(exit) p.dispose();
    return p.links.slice() == want;
}
private bool embeddedIs()(string params, string want) {
    auto p = Read(params); scope(exit) p.dispose();
    return p.embedded.slice() == want;
}
unittest {
    assert(textIs(`{"prompt":[{"type":"text","text":"a"},{"type":"image","data":"x"},{"type":"text","text":"b"}]}`, "a\nb"));
    assert(otherIs(`{"prompt":[{"type":"text","text":"a"},{"type":"image","data":"x"},{"type":"resource_link","uri":"file:///a"}]}`, "image"));
    assert(otherIs(`{"prompt":[{"type":"resource_link","uri":"file:///a","name":"a"}]}`, "all text"));
    assert(linksAre(`{"prompt":[{"type":"text","text":"see"},{"type":"resource_link","uri":"file:///a","name":"a"},{"type":"resource_link","name":"b","uri":"file:///b"}]}`,
        "a\0file:///a\0b\0file:///b\0"));
    // "required": name and uri. A link missing one is no link to read.
    assert(otherIs(`{"prompt":[{"type":"resource_link","uri":"file:///a"}]}`, "resource_link"));
    assert(otherIs(`{"prompt":[{"text":"a"}]}`, ""));
    assert(otherIs(`{"prompt":[{"type":"text","text":"a"}]}`, "all text"));
    assert(otherIs(`{"prompt":[]}`, "all text"));
    // embeddedContext: "the Client is allowed to include ContentBlock::Resource in
    // prompt requests for pieces of context that are referenced in the message".
    // A text resource is handed back by its uri and its text; one holding a blob
    // has no text to give the model, and is said, not dropped.
    assert(embeddedIs(`{"prompt":[{"type":"text","text":"see"},{"type":"resource","resource":{"uri":"file:///a.d","mimeType":"text/x-d","text":"int x;"}}]}`,
        "file:///a.d\0int x;\0"));
    assert(otherIs(`{"prompt":[{"type":"resource","resource":{"uri":"file:///a.d","text":"int x;"}}]}`, "all text"));
    assert(textIs(`{"prompt":[{"type":"text","text":"see"},{"type":"resource","resource":{"uri":"file:///a.d","text":"int x;"}}]}`, "see"));
    assert(otherIs(`{"prompt":[{"type":"resource","resource":{"uri":"file:///a.png","blob":"AAAA","mimeType":"image/png"}}]}`, "resource holding a blob"));
    assert(otherIs(`{"prompt":[{"type":"resource","resource":{"text":"no uri"}}]}`, "resource"));
    assert(textIs(`{"prompt":[{"type":"text","text":"say \"hi\""}]}`, `say "hi"`));
    assert(textIs(`{"prompt":[]}`, ""));
    // prompt is required: a request with none, or one only in _meta, has no prompt to read.
    static immutable string[2] promptless = [`{}`, `{"_meta":{"prompt":[]}}`];
    foreach (params; promptless) {
        auto p = Read(params); scope(exit) p.dispose();
        assert(p.blocks == Blocks.refused);
        assert(p.said.slice() == `{"code":-32602,"message":"session/prompt needs prompt, a list of content blocks"}`);
    }
}

// fs/read_text_file takes an "Absolute path to the file to read": a file://
// uri on this machine is one, percent-decoded; any other is not.
private string pathOf()(string uri) {
    Reply r;
    return fileUriPath(uri, r) ? r.slice().idup : "none";
}
static assert(pathOf("file:///tmp/a") == "/tmp/a");
static assert(pathOf("file:///tmp/a%20b%2Fc") == "/tmp/a b/c");
static assert(pathOf("file://localhost/etc/x") == "/etc/x");
static assert(pathOf("file://elsewhere/etc/x") == "none");
static assert(pathOf("https://example.com/a") == "none");
static assert(pathOf("file://") == "none");
static assert(pathOf("file:///a%00b") == "none");
static assert(pathOf("file:///a%zz") == "none");

// The history is the messages array's inside, grown a message at a time.
private string twoTurns()() {
    Reply h;
    userMessage(h, "hi");
    userMessage(h, `again "now"`);
    return h.slice().idup;
}
static assert(twoTurns() == `{"role":"user","content":"hi"},{"role":"user","content":"again \"now\""}`);

// The body the gateway gets: the model, the messages, the tools when there are
// any, and the session's effort as OpenRouter's reasoning effort. The plugin
// passes the body on whole, and every effort ground code offers is one of
// OpenRouter's: "max", "xhigh", "high", "medium", "low", "minimal" or "none".
private string bodyOf()(string model, string history, string tools, string effort) {
    Reply b;
    requestBody(b, model, history, tools, effort);
    return b.slice().idup;
}
static assert(bodyOf("openai/gpt-4o-mini", `{"role":"user","content":"hi"}`, "", "medium")
    == `{"model":"openai/gpt-4o-mini","messages":[{"role":"user","content":"hi"}],"reasoning":{"effort":"medium"}}`);
static assert(bodyOf("m", `{"role":"user","content":"hi"}`, `{"type":"function","function":{"name":"test__echo"}}`, "max")
    == `{"model":"m","messages":[{"role":"user","content":"hi"}],"tools":[{"type":"function","function":{"name":"test__echo"}}],"reasoning":{"effort":"max"}}`);

// What the model answered: its text, or the calls it wants made, read from
// the gateway's JSON at runtime.
unittest {
    import code.prompt : Completion, completionOf;
    Completion c;
    assert(completionOf(`{"choices":[{"message":{"role":"assistant","content":"earth"}}]}`, c));
    assert(c.content == "earth");
    assert(c.callCount == 0);
    c.dispose();
    // "Reasoning tokens will appear in the reasoning field of each message"
    assert(completionOf(`{"choices":[{"message":{"role":"assistant","content":"earth","reasoning":"it is round"}}]}`, c));
    assert(c.reasoning == "it is round" && c.content == "earth");
    c.dispose();
    assert(completionOf(`{"choices":[{"message":{"role":"assistant","content":"earth"}}]}`, c));
    assert(c.reasoning is null);
    c.dispose();

    assert(completionOf(`{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[`
        ~ `{"id":"c1","type":"function","function":{"name":"test__echo","arguments":"{\"text\":\"hi\"}"}}]}}]}`, c));
    assert(c.content.length == 0);
    assert(c.callCount == 1);
    assert(c.calls[0].id == "c1");
    assert(c.calls[0].name == "test__echo");
    assert(c.calls[0].arguments == `{"text":"hi"}`);
    c.dispose();

    // No choices is no completion; the gateway's body is kept for the error.
    assert(!completionOf(`{"error":{"message":"No models provided","code":400}}`, c));
    c.dispose();
}

// "readOnlyHint": what plan mode runs. Only a tool whose annotations say it is
// true counts; one that says false, or says nothing, does not.
unittest {
    import code.mcp : McpGroup, McpServer, McpPage;
    import code.prompt : readOnlyTool;
    enum page = `{"result":{"tools":[{"name":"look","annotations":{"readOnlyHint":true}},`
        ~ `{"name":"write","annotations":{"readOnlyHint":false}},{"name":"plain"}]}}`;
    McpPage p;
    p.response.json = cast(char*) page.ptr;
    p.response.length = page.length;
    McpServer server;
    server.name = cast(char*) "fs\0".ptr;
    server.tools = &p;
    McpGroup group = McpGroup(&server, 1);
    assert(readOnlyTool(group, "fs__look"));
    assert(!readOnlyTool(group, "fs__write"));
    assert(!readOnlyTool(group, "fs__plain"));
    assert(!readOnlyTool(group, "fs__missing"));
    assert(!readOnlyTool(group, "other__look"));
}

// "Tokens currently in context": what the gateway's answer says the
// conversation holds now, its total_tokens. An answer without usage has none.
unittest {
    import code.prompt : Completion, completionOf, contextLengthOf;
    Completion c;
    assert(completionOf(`{"choices":[{"message":{"content":"x"}}],"usage":{"prompt_tokens":194,"completion_tokens":2,"total_tokens":196}}`, c));
    assert(c.hasUsage && c.used == 196);
    c.dispose();
    assert(completionOf(`{"choices":[{"message":{"content":"x"}}]}`, c));
    assert(!c.hasUsage);
    c.dispose();

    // "context_length": "Maximum context length in tokens", the model's own,
    // by its id in the list. Absent, null, or not the model's: none.
    ulong size;
    enum list = `{"data":[{"id":"a","context_length":8192},{"id":"m","context_length":200000,"top_provider":{"context_length":100000}},{"id":"n","context_length":null}]}`;
    assert(contextLengthOf(list, "m", size) && size == 200_000);
    assert(contextLengthOf(list, "a", size) && size == 8192);
    assert(!contextLengthOf(list, "n", size));
    assert(!contextLengthOf(list, "z", size));
    assert(!contextLengthOf(`{"error":{"message":"not found"}}`, "m", size));
    assert(!contextLengthOf(`not json`, "m", size));
}

// A session's title: "May be auto-generated from the first prompt." The first
// line the user typed, its spaces run together, cut after the last word that
// ends within TITLE_BYTES, with an ellipsis; nothing typed is no title yet.
unittest {
    import code.prompt : titleOf, TITLE_BYTES;
    import code.reply : Reply;
    bool gives(const(char)[] typed, const(char)[] want) {
        Reply t;
        scope(exit) t.dispose();
        titleOf(typed, t);
        return t.slice() == want;
    }
    assert(gives("hi", "hi"));
    assert(gives("  fix   the\tbuild \r\n then the rest", "fix the build"));
    assert(gives("\n \n  the second line leads", "the second line leads"));
    assert(gives("", ""));
    assert(gives(" \n\t\n", ""));
    enum words = "the quick brown fox jumps over the lazy dog and keeps running past the fence into the field";
    static assert(words.length > TITLE_BYTES);
    assert(gives(words, "the quick brown fox jumps over the lazy dog and keeps running past the fence…"));
    // One word longer than the title is cut where a character ends, not inside one.
    enum long_ = "ééééééééééééééééééééééééééééééééééééééééééééééééé";
    static assert(long_.length > TITLE_BYTES);
    assert(gives(long_, "éééééééééééééééééééééééééééééééééééééééé…"));
}

// usage.cost, "The total amount charged to your account", in billionths of a
// dollar, so a session's sum is exact; and said back as a decimal amount.
unittest {
    import code.prompt : Completion, completionOf, putAmount;
    import code.reply : Reply;
    Completion c;
    assert(completionOf(`{"choices":[{"message":{"content":"x"}}],"usage":{"total_tokens":196,"cost":0.95}}`, c));
    assert(c.hasCost && c.costNano == 950_000_000);
    c.dispose();
    assert(completionOf(`{"choices":[{"message":{"content":"x"}}],"usage":{"total_tokens":196,"cost":0}}`, c));
    assert(c.hasCost && c.costNano == 0);
    c.dispose();
    assert(completionOf(`{"choices":[{"message":{"content":"x"}}],"usage":{"total_tokens":196}}`, c));
    assert(!c.hasCost);
    c.dispose();
    // A node that brings its own provider key ("is_byok": true) is charged
    // twice over: OpenRouter's cost, 0 on q's real gateway, and the
    // provider's, cost_details.upstream_inference_cost, "The actual cost
    // charged by the upstream AI provider", to that key. Without its own key,
    // the provider is paid out of OpenRouter's cost, so it is not added again.
    assert(completionOf(`{"choices":[{"message":{"content":"x"}}],"usage":{"total_tokens":96,"cost":0,"is_byok":true,`
        ~ `"cost_details":{"upstream_inference_cost":9.6e-05,"upstream_inference_prompt_cost":3.6e-05,"upstream_inference_completions_cost":6e-05}}}`, c));
    assert(c.hasCost && c.costNano == 96_000);
    c.dispose();
    assert(completionOf(`{"choices":[{"message":{"content":"x"}}],"usage":{"total_tokens":96,"cost":0.0048,"is_byok":true,`
        ~ `"cost_details":{"upstream_inference_cost":0.096}}}`, c));
    assert(c.hasCost && c.costNano == 100_800_000);
    c.dispose();
    assert(completionOf(`{"choices":[{"message":{"content":"x"}}],"usage":{"total_tokens":96,"cost":0.95,"is_byok":false,`
        ~ `"cost_details":{"upstream_inference_cost":0.9}}}`, c));
    assert(c.hasCost && c.costNano == 950_000_000);
    c.dispose();
    bool says(long nano, string want) { Reply r; scope(exit) r.dispose(); putAmount(r, nano); return r.slice() == want; }
    assert(says(950_000_000, "0.95"));
    assert(says(123_000, "0.000123"));
    assert(says(0, "0"));
    assert(says(12_500_000_000, "12.5"));
    assert(says(1, "0.000000001"));
}

// ToolCall content, "Content produced by the tool call": MCP's content blocks
// are ACP's, "enabling agents to seamlessly forward content from MCP tool
// outputs without transformation", each as {"type":"content"}. A call that
// failed shows what failed it as text; one not run, why.
unittest {
    import code.prompt : putToolCall;
    import code.reply : Reply;
    import matcher : indexOf;
    // The update libacp writes for a call that answered output: its content, or none.
    bool shows(const(char)[] output, const(char)[] want) {
        Reply u;
        scope(exit) u.dispose();
        if (!putToolCall(u, true, "c1", null, null, null, "failed", null, output)) return false;
        auto s = u.slice();
        if (want.length == 0) return indexOf(s, `,"content":[{"type":"content"`) < 0;
        return s.length > want.length && s[$ - 1] == '}' && s[$ - 1 - want.length .. $ - 1] == want;
    }
    // Completed: its blocks, as they came.
    assert(shows(`{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"hi"},{"type":"image","data":"AAAA","mimeType":"image/png"}]}}`,
        `,"content":[{"type":"content","content":{"type":"text","text":"hi"}},{"type":"content","content":{"type":"image","data":"AAAA","mimeType":"image/png"}}]`));
    // The server's error answer: its message.
    assert(shows(`{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"no such file"}}`,
        `,"content":[{"type":"content","content":{"type":"text","text":"no such file"}}]`));
    // A tool error, as ground code keeps it: the tool's own words, from the response it carries.
    assert(shows(`{"status":"tool error","message":"tool error","response":"{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"disk full\"}]}}","validation":null}`,
        `,"content":[{"type":"content","content":{"type":"text","text":"disk full"}}]`));
    // A failure with no response: ground code's message.
    assert(shows(`{"status":"timeout","message":"continuation deadline elapsed","response":"","validation":null}`,
        `,"content":[{"type":"content","content":{"type":"text","text":"continuation deadline elapsed"}}]`));
    // Not run: why.
    assert(shows(`{"status":"not run","why":"the user rejected it"}`,
        `,"content":[{"type":"content","content":{"type":"text","text":"the user rejected it"}}]`));
    // A result with nothing to show shows nothing.
    assert(shows(`{"jsonrpc":"2.0","id":3,"result":{"content":[]}}`, ``));
}

// A replayed call says kind read as it did live, when its tool only reads;
// its answer shows its content again.
unittest {
    import code.prompt : replayHistory;
    import code.reply : Reply;
    import matcher : indexOf;
    enum history = `{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"fs__look","arguments":"{}"}},`
        ~ `{"id":"c2","type":"function","function":{"name":"fs__write","arguments":"{}"}}]},`
        ~ `{"role":"tool","tool_call_id":"c1","content":"{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"seen\"}]}}"}`;
    __gshared char[4096] told;
    size_t toldLen;
    bool send(const(char)[] update) {
        foreach (c; update) told[toldLen++] = c;
        told[toldLen++] = '\n';
        return true;
    }
    bool readOnly(const(char)[] tool) { return tool == "fs__look"; }
    assert(replayHistory(history, &send, &readOnly));
    auto out_ = told[0 .. toldLen];
    assert(indexOf(out_, `{"sessionUpdate":"tool_call","toolCallId":"c1","title":"fs__look","name":"fs__look","kind":"read","rawInput":{}}`) >= 0);
    assert(indexOf(out_, `{"sessionUpdate":"tool_call","toolCallId":"c2","title":"fs__write","name":"fs__write","rawInput":{}}`) >= 0);
    assert(indexOf(out_, `"content":[{"type":"content","content":{"type":"text","text":"seen"}}]}`) >= 0);
}
