module public_test;

import proto : parsePbt;
import hooks : Visibility, standsInPublic;
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
  control { name: "anywhere" msg: "hi" }
}
`;
enum quietParsed = parsePbt(quietInput);
static assert(!quietParsed.scopes[0].publicOnly);

// The rule. A public repository is where the rewrite stands; a private one is
// not. A repository ground cannot place is treated as public, because the
// unknown case is the one where a leak costs the most.
static assert(standsInPublic(true, Visibility.Public));
static assert(!standsInPublic(true, Visibility.Private));
static assert(standsInPublic(true, Visibility.Unknown));
static assert(standsInPublic(false, Visibility.Private));
static assert(standsInPublic(false, Visibility.Unknown));

// GitHub's answer for a repository is read the way the throttle reads the
// rate limit: one field out of the JSON, no jq. Anything else is unknown.
static assert(visibilityIn(`{"id":1,"name":"QNTX","private":false,"owner":{}}`) == Visibility.Public);
static assert(visibilityIn(`{"id":2,"name":"q","private":true}`) == Visibility.Private);
static assert(visibilityIn(`{"message":"Not Found"}`) == Visibility.Unknown);
static assert(visibilityIn(``) == Visibility.Unknown);
