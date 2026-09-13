module routes_test;

// BOOK_GLOSSARY **Route**: One path of a project's OpenAPI spec, with the word a reply is matched on and the text ground injects when it is said.

import proto : parsePbt, extractProjectRoutes;
import routes : saysWord, routeApplies, fitRoutes, buildRoutesMessage;

// "on a match ground should inject the specific bit"
// A project names its spec, relative to its path. Wind reads it at build and
// writes one route block per path back: the word said, and the text injected.
enum routedInput = `
project {
  path: "/Users/me/code/qntx"
  openapi: "server/openapi/openapi.json"
  route {
    path: "/api/attestations"
    word: "attestations"
    text: "GET POST /api/attestations  reach: ROOT
GET returns attestations."
  }
  route {
    path: "/health"
    word: "health"
    text: "GET /health"
  }
}
project {
  path: "/Users/me/code/other"
}
`;
enum routedParsed = parsePbt(routedInput);
static assert(routedParsed.projectCount == 2);
static assert(routedParsed.projects[0].openapi == "server/openapi/openapi.json");
static assert(routedParsed.routeCount == 2);
static assert(routedParsed.routes[0].project == "/Users/me/code/qntx");
static assert(routedParsed.routes[0].path == "/api/attestations");
static assert(routedParsed.routes[0].word == "attestations");
static assert(routedParsed.routes[0].text == "GET POST /api/attestations  reach: ROOT\nGET returns attestations.");
static assert(routedParsed.routes[1].word == "health");

enum flat = extractProjectRoutes(routedParsed);
static assert(flat.len == 2);
static assert(flat.routes[1].path == "/health");

// A word is said when it stands alone. Case-sensitive: the reply's "I" is
// never the path segment "i", which is what made this rule worth stating.
static assert(saysWord("the attestations endpoint", "attestations"));
static assert(saysWord("see /api/attestations for it", "attestations"));
static assert(saysWord("attestations", "attestations"));
static assert(!saysWord("the attestation endpoint", "attestations"));
static assert(!saysWord("reattestations", "attestations"));
static assert(!saysWord("attestations-v2", "attestations"));
static assert(!saysWord("I did it", "i"));
static assert(saysWord("path i is short", "i"));
static assert(!saysWord("it's short", "s"));
static assert(!saysWord("anything", ""));

// A route speaks for the tree of the project that declared it.
static assert(routeApplies("/Users/me/code/qntx", "/Users/me/code/qntx"));
static assert(routeApplies("/Users/me/code/qntx", "/Users/me/code/qntx/server"));
static assert(!routeApplies("/Users/me/code/qntx", "/Users/me/code/qntx-app"));
static assert(!routeApplies("/Users/me/code/qntx", "/Users/me/code"));

// What lands in front of the model: the texts, one after another.
static assert(buildRoutesMessage([flat.routes[0].text, flat.routes[1].text]).slice() ==
    "GET POST /api/attestations  reach: ROOT\nGET returns attestations.\n\nGET /health");

// The reason buffer is finite and truncation is not delivery. Texts go in
// whole, as many as fit; the rest are still unsaid and go next turn.
static assert(fitRoutes(["abc", "de"], 7) == 2);
static assert(fitRoutes(["abc", "de"], 6) == 1);
static assert(fitRoutes(["abcdefgh"], 4) == 0);
static assert(fitRoutes([], 4) == 0);
