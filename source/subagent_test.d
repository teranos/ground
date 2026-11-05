module subagent_test;

// BOOK_GLOSSARY **Subagent**: An agent a session starts with the Agent tool; it runs on the model and the effort the models block picks, as a ritual does.

import subagent : agentInput, Set, subagentsDir, namedNoModel, isAgent;
import proto : parsePbt;
import ritual : modelsAt, resolveModel, resolveEffort, ModelInputs, DEFAULT_MODEL;

// "the same rules for ritual agents should apply to subagents, they should cohere"
//
// A subagent has no ritual, so its layers are the project its session stands
// in and the top level, and the same pick is made from them.
enum named = `
models {
  model: "opus"
  effort: "medium"
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
// Outside every project, the top level's model.
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
// The nearest effort is the one used, and a layer that names none takes the next one out.
static assert(parsed.models.effort == "medium");
static assert(resolveEffort(outside) == "medium");
static assert(resolveEffort(inGrove) == "medium");
static assert(resolveEffort(modelsAt(parsePbt(`models { model: "opus" }`), "/p")) == "");
static assert(!__traits(compiles, { enum bad = parsePbt(`models { effort: "loud" }`); }));

private string set(string region, string model, string effort) {
    char[512] b = 0;
    auto r = agentInput(region, model, effort, b[]);
    assert(r.fit);
    return b[0 .. r.len].idup;
}

private Set told(string region, string model, string effort, size_t room = 512) {
    char[512] b = 0;
    return agentInput(region, model, effort, b[0 .. room]);
}

// A call that names neither is given both.
static assert(set(`{"description":"d","prompt":"p"}`, "opus", "medium")
    == `{"description":"d","prompt":"p","model":"opus","effort":"medium"}`);
static assert(told(`{"description":"d","prompt":"p"}`, "opus", "medium").changed);

// What the call asked for is not what it gets.
static assert(set(`{"description":"d","model":"fable","prompt":"p","effort":"xhigh"}`, "opus", "medium")
    == `{"description":"d","prompt":"p","model":"opus","effort":"medium"}`);

// The call's own keys are read, and no text inside its prompt.
static assert(set(`{"prompt":"say \"model\":\"fable\" and {","description":"d"}`, "opus", "")
    == `{"prompt":"say \"model\":\"fable\" and {","description":"d","model":"opus"}`);

// What else the call carries is carried as it was.
static assert(set(`{ "prompt" : "p", "isolation":"worktree", "extra":{"model":"fable","a":[1,"}"]}, "n":3 }`, "opus", "medium")
    == `{"prompt" : "p","isolation":"worktree","extra":{"model":"fable","a":[1,"}"]},"n":3,"model":"opus","effort":"medium"}`);

// An effort alone leaves the model the call named.
static assert(set(`{"prompt":"p","model":"sonnet"}`, "", "medium")
    == `{"prompt":"p","model":"sonnet","effort":"medium"}`);

// A call that already is what the block names is not changed.
static assert(!told(`{"prompt":"p","model":"opus","effort":"medium"}`, "opus", "medium").changed);
static assert(told(`{"prompt":"p","model":"opus","effort":"medium"}`, "opus", "medium").fit);

// A fork runs on its session's model whatever it is told.
static assert(told(`{"prompt":"p","subagent_type":"fork"}`, "opus", "medium").fork);
static assert(!told(`{"prompt":"fork","subagent_type":"general-purpose"}`, "opus", "medium").fork);

// What does not fit, and what is no object, is not a rewrite.
static assert(!told(`{"description":"d","prompt":"p"}`, "opus", "medium", 40).fit);
static assert(!told(`{"prompt":"p"`, "opus", "medium").fit);
static assert(!told(`["prompt"]`, "opus", "medium").fit);
static assert(!told(``, "opus", "medium").fit);

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
