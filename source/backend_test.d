module backend_test;

// 「[Opus 5.5] BOOK_GLOSSARY **Backend**: The QNTX every attestation goes to, named once at the top level by its url.」

import proto : parsePbt;
import backend : postings, unbacked;

// book: backend-fanInput
enum fanInput = `
qntx {
  url: "https://qntx.alice.example"
  model: "openai/gpt-4o-mini"
  gateway: "https://gateway.alice.example"
}
project {
  origin: "alice/hygrometer-server"
  path: "/Users/Alice/projects/hygrometer-server"
  attestation {
    subject: "hygrometer:reading"
    predicate: "hygrometer:measured"
    context: "project:alice/hygrometer-server"
  }
}
project {
  origin: "coinflip/heads"
  path: "/Users/Alice/projects/heads"
}
attestation {
  subject: "beacon:routing-table"
  predicate: "beacon:routes"
  context: "project:alice"
}
`;
enum fanParsed = parsePbt(fanInput);
enum fan = postings(fanParsed);

// An attestation knows the project it was written in; a top-level one none.
static assert(fanParsed.attestations[0].project == "/Users/Alice/projects/hygrometer-server");
static assert(fanParsed.attestations[1].project == "");

static assert(fan.len == 2);
static assert(fan.items[0].url == "https://qntx.alice.example" && fan.items[0].subject == "hygrometer:reading");
static assert(fan.items[1].url == "https://qntx.alice.example" && fan.items[1].subject == "beacon:routing-table");
static assert(unbacked(fanParsed) == "");

// "we use the qntx openrouter plugin"
// book: backend-fanParsed
static assert(fanParsed.qntx.model == "openai/gpt-4o-mini");

// "prompt q for now"
// book: backend-fanParsed-2
static assert(fanParsed.qntx.gateway == "https://gateway.alice.example");

// book: backend-strandedInput
enum strandedInput = `
project {
  origin: "coinflip/heads"
  path: "/Users/Alice/projects/heads"
  attestation {
    subject: "coin:thrown"
    predicate: "coin:heads"
    context: "project:coinflip/heads"
  }
}
`;
enum strandedParsed = parsePbt(strandedInput);
static assert(unbacked(strandedParsed) == "coin:thrown");
static assert(postings(strandedParsed).len == 0);
