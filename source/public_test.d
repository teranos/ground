module public_test;

import proto : parsePbt;
import hooks : Visibility;
import audience : audienceFrom, internetSees;
import git : visibilityIn;

// "the rewrite rule should apply to any repo i work in that is public but not in private repo's"
// "i want this to be a property of ground instead"

// A scope says it stands in public repositories. Not a path: a fact ground
// establishes about the repository the write goes into.
enum publicInput = `
scope {
  public: true
  event: "PreToolUse"

  control {
    name: "no-name-in-public"
    rewrite: ["me|golem"]
    msg: "taken out"
  }
}
`;
enum publicParsed = parsePbt(publicInput);
static assert(publicParsed.scopeCount == 1);
static assert(publicParsed.scopes[0].publicOnly);

// A scope that says nothing about it stands everywhere, as before.
enum quietInput = `
scope {
  event: "PreToolUse"
  control {
    name: "anywhere"
    msg: "hi"
  }
}
`;
enum quietParsed = parsePbt(quietInput);
static assert(!quietParsed.scopes[0].publicOnly);

// The rule. A public repository is where the rewrite stands; a private one is
// not. A repository ground cannot place is treated as public, because the
// unknown case is the one where a leak costs the most.
static assert(internetSees(audienceFrom(false, false, true, Visibility.Public)));
static assert(!internetSees(audienceFrom(false, false, true, Visibility.Private)));
static assert(internetSees(audienceFrom(false, false, true, Visibility.Unknown)));

// GitHub's answer for a repository is read the way the throttle reads the
// rate limit: one field out of the JSON, no jq. Anything else is unknown.
static assert(visibilityIn(`{"id":1,"name":"QNTX","private":false,"owner":{}}`) == Visibility.Public);
static assert(visibilityIn(`{"id":2,"name":"q","private":true}`) == Visibility.Private);
static assert(visibilityIn(`{"message":"Not Found"}`) == Visibility.Unknown);
static assert(visibilityIn(``) == Visibility.Unknown);

// The rewrite is the floor. A session in auto mode had every write allowed by
// a permission rule before the handler reached the rewrite, so the floor never
// applied to anything written all day. Whatever the handler answers, the
// answer carries the rewritten input when there is one.
import pretooluse : contextResponse;
import matcher : contains;

static assert(() {
    char[512] b;
    auto r = contextResponse(b[], "why", "allow", `{"file_path":"/p","content":"abcd"}`);
    return contains(r, `"updatedInput":{"file_path":"/p","content":"abcd"}`)
        && contains(r, `"permissionDecision":"allow"`)
        && contains(r, `"additionalContext":"why"`);
}());

static assert(() {
    char[512] b;
    auto r = contextResponse(b[], "", "allow", null);
    return !contains(r, "updatedInput");
}());

// A Bash answer whose decision is nobody's to make carries no permissionDecision.
// The empty string is not allow, deny or ask, and Claude Code discards the whole
// answer over it: the amendment and the message go with it.
import pretooluse : bashResponse;

static assert(() {
    char[512] b;
    auto r = bashResponse(b[], "git commit -m x", "Commit requires manual approval", "", false, 0);
    return !contains(r, "permissionDecision")
        && contains(r, `"updatedInput":{"command":"git commit -m x"}`)
        && contains(r, `"additionalContext":"Commit requires manual approval"`);
}());

// A decision ground did make is sent as it always was.
static assert(() {
    char[512] b;
    auto r = bashResponse(b[], "ls", "", "allow", false, 0);
    return contains(r, `"permissionDecision":"allow"`);
}());

// What a control asked for rides along with it.
static assert(() {
    char[512] b;
    auto r = bashResponse(b[], "make build", "", "allow", true, 120);
    return contains(r, `"run_in_background":true`) && contains(r, `"timeout":120`);
}());

// codex 0.163.0 fails the hook, and drops the rewrite and its context, over:
// "PreToolUse hook returned updatedInput without permissionDecision:allow"
// Its allow lifts no approval: only the updated input applies.
static assert(() {
    char[512] b;
    auto r = bashResponse(b[], "git commit -m x", "Git hooks must not be bypassed, ever.", "", false, 0, true);
    return contains(r, `"permissionDecision":"allow"`)
        && contains(r, `"updatedInput":{"command":"git commit -m x"}`)
        && contains(r, `"additionalContext":"Git hooks must not be bypassed, ever."`);
}());

// codex has no ask:
// "PreToolUse hook returned unsupported permissionDecision:ask"
static assert(() {
    char[512] b;
    auto r = bashResponse(b[], "git push", "", "ask", false, 0, true);
    return contains(r, `"permissionDecision":"allow"`) && !contains(r, "additionalContext");
}());

// Nor an allow with nothing to update:
// "PreToolUse hook returned unsupported permissionDecision:allow"
static assert(() {
    char[512] b;
    auto r = contextResponse(b[], "Use the Read tool instead of cat.", "allow", null, true);
    return !contains(r, "permissionDecision") && contains(r, `"additionalContext":"Use the Read tool instead of cat."`);
}());

// An empty additionalContext reaches codex's model as an empty developer message.
static assert(() {
    char[512] b;
    return contextResponse(b[], "", "allow", null, true).length == 0;
}());

static assert(() {
    char[512] b;
    auto r = contextResponse(b[], "", "", `{"file_path":"/p"}`, true);
    return contains(r, `"permissionDecision":"allow"`) && contains(r, `"updatedInput":{"file_path":"/p"}`);
}());

// A deny never carries a rewrite, and to codex one without a reason is invalid.
static assert(() {
    char[512] b;
    auto r = contextResponse(b[], "no binary files", "deny", `{"file_path":"/p"}`, true);
    return contains(r, `"permissionDecision":"deny"`)
        && contains(r, `"permissionDecisionReason":"no binary files"`)
        && !contains(r, "updatedInput");
}());

// codex says which harness it is by its turn_id: every PreToolUse of codex's
// carries one and none of Claude Code's does.
import parse : fromCodex, codexModel;

// ug records a Claude Code session's model from its statusline, and codex
// runs no statusline, so its items reached sentry with no model. Its events
// name the model themselves.
static assert(() {
    char[64] b;
    return codexModel(`{"session_id":"s","turn_id":"t","model":"gpt-6.1-sol"}`, b[]) == "gpt-6.1-sol";
}());
static assert(() {
    char[64] b;
    return codexModel(`{"session_id":"s","model":"claude-opus-5-5","source":"startup"}`, b[]) is null;
}());
static assert(fromCodex(`{"session_id":"s","turn_id":"t","tool_name":"Bash"}`));
static assert(!fromCodex(`{"session_id":"s","tool_name":"Bash","tool_input":{"command":"echo \"turn_id\""}}`));
