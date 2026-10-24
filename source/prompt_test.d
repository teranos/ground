module prompt_test;

// "we use the qntx openrouter plugin"
// "as the endpoint"
// A prompt is one turn through the node's gateway, and its tools are libmcp's.

import code.prompt : putToolName, serverOf, toolOf, promptText, userMessage, requestBody;
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

// The prompt's text blocks, in order, one line each; a block of another kind
// has no text to give, and its type is said instead of dropped.
private string textOf()(string line) {
    Reply r, other;
    promptText(line, r, other);
    return r.slice().idup;
}
private string otherOf()(string line) {
    Reply r, other;
    return promptText(line, r, other) ? "all text" : other.slice().idup;
}
static assert(textOf(`{"prompt":[{"type":"text","text":"a"},{"type":"image","data":"x"},{"type":"text","text":"b"}]}`) == "a\nb");
static assert(otherOf(`{"prompt":[{"type":"text","text":"a"},{"type":"image","data":"x"},{"type":"resource_link","uri":"file:///a"}]}`) == "image");
static assert(otherOf(`{"prompt":[{"type":"resource_link","uri":"file:///a","name":"a"}]}`) == "resource_link");
static assert(otherOf(`{"prompt":[{"text":"a"}]}`) == "");
static assert(otherOf(`{"prompt":[{"type":"text","text":"a"}]}`) == "all text");
static assert(otherOf(`{"prompt":[]}`) == "all text");
static assert(textOf(`{"prompt":[{"type":"text","text":"say \"hi\""}]}`) == `say "hi"`);
static assert(textOf(`{"prompt":[]}`) == "");

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
