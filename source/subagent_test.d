module subagent_test;

// BOOK_GLOSSARY **Subagent**: An agent a session starts with the Agent tool; it runs on the model the models block picks, at that model's own effort setting, as a ritual's agent does.

import subagent : agentInput, Set, subagentsDir, namedNoModel, isAgent, sentTo;
import parse : extractToolInputRegion;
import proto : parsePbt;
import ritual : modelsAt, resolveModel, ModelInputs, DEFAULT_MODEL;

// "the same rules for ritual agents should apply to subagents, they should cohere"
//
// A subagent has no ritual, so its layers are the project its session stands
// in and the top level, and the same pick is made from them.
enum named = `
models {
  model: "opus"
  five_hour: ">90"  model: "haiku"
}

project {
  path: "/src/grove"

  models {
    model: "sonnet"
  }
}
`;
enum parsed = parsePbt(named);

ModelInputs quiet() {
    ModelInputs i;
    i.planKnown = true;
    i.plan = "max";
    i.fiveKnown = true;
    i.fiveTenths = 100;
    i.sevenKnown = true;
    i.sevenTenths = 500;
    return i;
}

// "Subagents Alwys Opus, never Fable, Fable is for what is worth human attention span"
// book: subagent-modelsAt
enum outside = modelsAt(parsed, "/home/u/elsewhere");
static assert(!outside[0].present);
static assert(!outside[1].present);
static assert(resolveModel(outside, quiet()).model == "opus");

// In a project that names one, the project's.
enum inGrove = modelsAt(parsed, "/home/u/src/grove/deep");
static assert(inGrove[1].model == "sonnet");
static assert(resolveModel(inGrove, quiet()).model == "sonnet");

// A rule is asked before any plain model, for a subagent as for a ritual.
static assert(() { auto i = quiet(); i.fiveTenths = 950; return resolveModel(inGrove, i).model == "haiku"; }());

// No models anywhere is the default a ritual gets.
static assert(resolveModel(modelsAt(parsePbt(`project { path: "/p" }`), "/p"), quiet()).model == DEFAULT_MODEL);

// "and agents always on medium effort please"
// book: subagent-__traits
static assert(!__traits(compiles, { enum bad = parsePbt(`models { effort: "medium" }`); }));

private string set(string region, string model) {
    char[512] b = 0;
    auto r = agentInput(region, model, b[]);
    assert(r.fit);
    return b[0 .. r.len].idup;
}

private Set told(string region, string model, size_t room = 512) {
    char[512] b = 0;
    return agentInput(region, model, b[0 .. room]);
}

// A call that names no model is given the one picked.
static assert(set(`{"description":"d","prompt":"p"}`, "opus")
    == `{"description":"d","prompt":"p","model":"opus"}`);
static assert(told(`{"description":"d","prompt":"p"}`, "opus").changed);

// "i want a main session to be at very high effort, maybe even xhigh,"
// "but i cat ave each of its agents be xhigh as well"
// book: subagent-set
static assert(set(`{"description":"d","model":"fable","prompt":"p","effort":"xhigh"}`, "opus")
    == `{"description":"d","prompt":"p","model":"opus"}`);
static assert(told(`{"prompt":"p","model":"opus","effort":"medium"}`, "opus").changed);

// The call's own keys are read, and no text inside its prompt.
static assert(set(`{"prompt":"say \"model\":\"fable\" and {","description":"d"}`, "opus")
    == `{"prompt":"say \"model\":\"fable\" and {","description":"d","model":"opus"}`);

// What else the call carries is carried as it was.
static assert(set(`{ "prompt" : "p", "isolation":"worktree", "extra":{"effort":"max","a":[1,"}"]}, "n":3 }`, "opus")
    == `{"prompt" : "p","isolation":"worktree","extra":{"effort":"max","a":[1,"}"]},"n":3,"model":"opus"}`);

// A call that already is what was picked is not changed.
static assert(!told(`{"prompt":"p","model":"opus"}`, "opus").changed);
static assert(told(`{"prompt":"p","model":"opus"}`, "opus").fit);

// A fork runs on its session's model whatever it is told.
static assert(told(`{"prompt":"p","subagent_type":"fork"}`, "opus").fork);
static assert(!told(`{"prompt":"fork","subagent_type":"general-purpose"}`, "opus").fork);

// What does not fit, and what is no object, is not a rewrite.
static assert(!told(`{"description":"d","prompt":"p"}`, "opus", 40).fit);
static assert(!told(`{"prompt":"p"`, "opus").fit);
static assert(!told(`["prompt"]`, "opus").fit);
static assert(!told(``, "opus").fit);

// A session that asks first is asked about the call as it will run: the
// question carries what the input became.
import pretooluse : askResponse;
static assert(() {
    char[512] b = 0;
    return askResponse(b[], "Agent asks", `{"prompt":"p","model":"opus"}`)
        == `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask",`
         ~ `"permissionDecisionReason":"Agent asks","updatedInput":{"prompt":"p","model":"opus"}}}`;
}());

// A question about a call nothing changed is the question alone.
static assert(() {
    char[512] b = 0;
    return askResponse(b[], "Agent asks", null)
        == `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask",`
         ~ `"permissionDecisionReason":"Agent asks"}}`;
}());

// A message to a subagent resumes it on the model it was started on. What a
// session notes of the subagents it started is beside its transcript.
static assert(() {
    char[256] b = 0;
    return subagentsDir("/h/.claude/projects/p/abc.jsonl", b[]) == "/h/.claude/projects/p/abc/subagents";
}());
static assert(() { char[256] b = 0; return subagentsDir("/h/abc.txt", b[]).length == 0; }());
static assert(() { char[8] b = 0; return subagentsDir("/h/.claude/projects/p/abc.jsonl", b[]).length == 0; }());

// One whose call named no model was started on its session's own.
enum defaults = `{"agentType":"general-purpose","description":"OTEL agent: items one by one","launchedWithDefaults":true,"pickedEffortModel":"claude-fable-5-1"}`;
enum picked = `{"agentType":"general-purpose","description":"Probe","model":"opus","effort":"medium","pickedEffortModel":"claude-fable-5-1"}`;
static assert(namedNoModel(defaults));
static assert(!namedNoModel(picked));

// The note is the agent's by its id, which the file is named after, or by its name.
static assert(isAgent("agent-a1b2c3.meta.json", defaults, "a1b2c3"));
static assert(isAgent("agent-a1b2c3.meta.json", defaults, "OTEL agent: items one by one"));
static assert(!isAgent("agent-a1b2c3.meta.json", defaults, "a1b2"));
static assert(!isAgent("agent-a1b2c3.jsonl", defaults, "a1b2c3"));
static assert(!isAgent("agent-a1b2c3.meta.json", defaults, "main"));

// A key and a value are what their JSON says, however it is spelled.
static assert(told(`{"prompt":"p","subagent_type":"\u0066ork"}`, "opus").fork);
static assert(set(`{"prompt":"p","\u0065ffort":"max","m\u006fdel":"fable"}`, "opus")
    == `{"prompt":"p","model":"opus"}`);

// A brace inside a string is text: the input of a call is the whole object.
static assert(extractToolInputRegion(`{"tool_name":"Agent","tool_input":{"prompt":"close with } here","description":"d"},"tool_use_id":"t"}`)
    == `{"prompt":"close with } here","description":"d"}`);
static assert(extractToolInputRegion(`{"tool_input":{"message":"a \" } \\","to":"x"},"tool_use_id":"t"}`)
    == `{"message":"a \" } \\","to":"x"}`);

// Who a message is sent to is the call's own key, and no text inside the message.
static assert(() { char[64] b = 0; return sentTo(`{"message":"say \"to\":\"main\" }","to":"OTEL agent"}`, b[]) == "OTEL agent"; }());
static assert(() { char[64] b = 0; return sentTo(`{"message":"m","t\u006f":"a1b2"}`, b[]) == "a1b2"; }());
static assert(() { char[64] b = 0; return sentTo(`{"message":"m"}`, b[]).length == 0; }());
