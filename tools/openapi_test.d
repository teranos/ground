module openapi_test;

// CTFE tests for the OpenAPI digest wind writes into a project block.
// Failure shows as a compile error from static assert.

import openapi : routeWord, renderRoutes;

// The word a reply is matched on. The second segment names the route; the
// first alone is a namespace shared by dozens of paths. A one-segment path
// has only its first.
static assert(routeWord("/api/attestations") == "attestations");
static assert(routeWord("/api/embeddings/cluster") == "embeddings");
static assert(routeWord("/health") == "health");
static assert(routeWord("/i/") == "i");
static assert(routeWord("/i/enable") == "enable");
static assert(routeWord("/api/plugins/{name}/config") == "plugins");
static assert(routeWord("/") == "");
static assert(routeWord("/.well-known/did.json") == "did.json");

enum spec = `{
  "paths": {
    "/api/attestations": {
      "get": {
        "summary": "HandleAttestations routes GET and POST.",
        "description": "GET returns attestations.\n  - ?subject=x\n  - ?limit=N",
        "x-qntx-reach": ["ROOT", "TOKEN"],
        "x-qntx-handler": "HandleAttestations"
      },
      "post": {
        "summary": "HandleAttestations routes GET and POST.",
        "description": "GET returns attestations.\n  - ?subject=x\n  - ?limit=N",
        "x-qntx-reach": ["ROOT", "TOKEN"],
        "x-qntx-handler": "HandleAttestations"
      }
    },
    "/health": {
      "get": {
        "summary": "Liveness.",
        "x-qntx-reach": ["ANYONE"]
      }
    },
    "/": {
      "get": { "summary": "Root." }
    }
  }
}`;

enum rendered = renderRoutes(spec);

// One route block per path that has a word. The root has none and is left
// out. Then one block per namespace: the first segment, said alone, shows
// what sits under it and not yet what any of it does.
// "but api should show the things under api/"
// "but not _what_ they do per se immediately,"
static assert(rendered ==
`  route {
    path: "/api/attestations"
    word: "attestations"
    text: ` ~ "`" ~ `GET POST /api/attestations  reach: ROOT, TOKEN  handler: HandleAttestations
GET returns attestations.
  - ?subject=x
  - ?limit=N` ~ "`" ~ `
  }
  route {
    path: "/health"
    word: "health"
    text: ` ~ "`" ~ `GET /health  reach: ANYONE
Liveness.` ~ "`" ~ `
  }
  route {
    path: "/api"
    word: "api"
    text: ` ~ "`" ~ `/api
GET POST /api/attestations` ~ "`" ~ `
  }
`);

// A namespace whose bare path is also a route lists itself among its own.
enum setupSpec = `{"paths":{
  "/setup/claim":{"post":{"summary":"Claim."}},
  "/setup":{"get":{"summary":"Setup."}}
}}`;
static assert(renderRoutes(setupSpec) ==
`  route {
    path: "/setup"
    word: "setup"
    text: ` ~ "`" ~ `GET /setup
Setup.` ~ "`" ~ `
  }
  route {
    path: "/setup/claim"
    word: "claim"
    text: ` ~ "`" ~ `POST /setup/claim
Claim.` ~ "`" ~ `
  }
  route {
    path: "/setup"
    word: "setup"
    text: ` ~ "`" ~ `/setup
GET /setup
POST /setup/claim` ~ "`" ~ `
  }
`);

// A description that would close the backtick string is kept readable, not
// truncated: the backtick becomes a straight quote.
enum tickSpec = `{"paths":{"/x/tick":{"get":{"summary":"Use ` ~ "`" ~ `id` ~ "`" ~ ` here."}}}}`;
static assert(renderRoutes(tickSpec) ==
`  route {
    path: "/x/tick"
    word: "tick"
    text: ` ~ "`" ~ `GET /x/tick
Use 'id' here.` ~ "`" ~ `
  }
  route {
    path: "/x"
    word: "x"
    text: ` ~ "`" ~ `/x
GET /x/tick` ~ "`" ~ `
  }
`);

// No paths, nothing written.
static assert(renderRoutes(`{"paths":{}}`) == "");
