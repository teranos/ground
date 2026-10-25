module parse_test;

import parse : toolResponseRegion;

// The tool's answer is read from inside tool_response and nowhere else. A
// command that quotes the word stdout would otherwise be read as the answer.
enum push = `{"tool_name":"Bash","tool_input":{"command":"git push origin v0.31.0"},`
          ~ `"tool_response":{"stdout":"To github.com:teranos/QNTX.git\n * [new tag]  v0.31.0 -> v0.31.0\n","stderr":""}}`;
static assert(toolResponseRegion(push)[0 .. 9] == `{"stdout"`);

enum quoted = `{"tool_input":{"command":"echo \"stdout\" > f"},"tool_response":{"stdout":"answer"}}`;
static assert(toolResponseRegion(quoted)[0 .. 18] == `{"stdout":"answer"`);

// PreToolUse has no answer yet.
enum before = `{"tool_name":"Bash","tool_input":{"command":"git push"}}`;
static assert(toolResponseRegion(before) is null);

// codex's Bash tool_response is a string: what the command printed, as its
// model reads it. A rite reads it the way it reads Claude Code's stdout.
unittest {
    import parse : extractToolOutput;
    enum codex = `{"turn_id":"t","tool_name":"Bash","tool_input":{"command":"git push"},`
               ~ `"tool_response":"To github.com:teranos/QNTX.git\n * [new tag]  v0.31.0 -> v0.31.0\n","tool_use_id":"exec-1"}`;
    assert(extractToolOutput(codex) == "To github.com:teranos/QNTX.git\n * [new tag]  v0.31.0 -> v0.31.0\n");
    assert(extractToolOutput(push) == "To github.com:teranos/QNTX.git\n * [new tag]  v0.31.0 -> v0.31.0\n");
}
