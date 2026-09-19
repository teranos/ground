module backend_test;

// BOOK_GLOSSARY **Backend**: The QNTX every attestation goes to, named once at the top level by its url and its token file.

import proto : parsePbt;
import backend : postings, unbacked;

// "no double or split config, they all need to go to the same call from the same token"
// Alice's hygrometer server attests its readings; a routing table is written at
// the top level; coinflip's heads says nothing of a node. All of it goes to the
// one node, with the one token.
enum fanInput = `
qntx {
  url:   "https://qntx.alice.example"
  token: "~/.qntx/ground-token"
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
static assert(fan.items[0].token == "~/.qntx/ground-token");
static assert(fan.items[1].url == "https://qntx.alice.example" && fan.items[1].subject == "beacon:routing-table");
static assert(fan.items[1].token == "~/.qntx/ground-token");
static assert(unbacked(fanParsed) == "");

// A node named without a token file is spoken to with the one ground attest
// always read: QNTX_TOKEN, then ~/.qntx/token.
enum untokenedInput = `
qntx {
  url: "http://localhost:8771"
}
attestation {
  subject: "beacon:routing-table"
  predicate: "beacon:routes"
  context: "project:alice"
}
`;
enum untokened = postings(parsePbt(untokenedInput));
static assert(untokened.len == 1);
static assert(untokened.items[0].url == "http://localhost:8771" && untokened.items[0].token == "");

// A coin thrown with no node named anywhere lands nowhere. The build says
// which coin, rather than posting it nowhere in silence.
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
