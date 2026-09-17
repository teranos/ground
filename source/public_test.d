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
