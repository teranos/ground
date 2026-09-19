module backend_test;

// BOOK_GLOSSARY **Backend**: The QNTX a project attests to, named by its url on the project block.

import proto : parsePbt;
import backend : postings, unbacked;

// Alice's hygrometer server attests its readings to her QNTX. Her clone of
// QNTX itself runs against the one on her laptop. Coinflip's heads names no
// backend. A routing table written at the top level reaches every backend.
enum fanInput = `
project {
  origin: "alice/hygrometer-server"
  path: "/Users/Alice/projects/hygrometer-server"
  qntx: "https://qntx.alice.example"
  attestation {
    subject: "hygrometer:reading"
    predicate: "hygrometer:measured"
    context: "project:alice/hygrometer-server"
  }
}
project {
  origin: "alice/QNTX"
  path: "/Users/Alice/projects/QNTX"
  qntx: "http://localhost:8771"
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

static assert(fan.len == 3);
static assert(fan.items[0].url == "https://qntx.alice.example" && fan.items[0].subject == "hygrometer:reading");
static assert(fan.items[1].url == "https://qntx.alice.example" && fan.items[1].subject == "beacon:routing-table");
static assert(fan.items[2].url == "http://localhost:8771" && fan.items[2].subject == "beacon:routing-table");
static assert(unbacked(fanParsed) == "");

// "no double or split config, they all need to go to the same call from the same token"
// The token file a project names in its qntx block travels with every posting
// to that backend; a project naming none posts with the one ground attest
// always read.
enum tokenedInput = `
project {
  origin: "alice/QNTX"
  path: "/Users/Alice/projects/QNTX"
  qntx: "https://qntx.alice.example"
  qntx {
    token: "~/.qntx/ground"
  }
  attestation {
    subject: "qntx:routing-table"
    predicate: "qntx:routes"
    context: "project:alice/QNTX"
  }
}
project {
  origin: "coinflip/heads"
  path: "/Users/Alice/projects/heads"
  qntx: "http://localhost:8771"
  attestation {
    subject: "coin:thrown"
    predicate: "coin:heads"
    context: "project:coinflip/heads"
  }
}
`;
enum tokened = postings(parsePbt(tokenedInput));
static assert(tokened.len == 2);
static assert(tokened.items[0].url == "https://qntx.alice.example" && tokened.items[0].token == "~/.qntx/ground");
static assert(tokened.items[1].url == "http://localhost:8771" && tokened.items[1].token == "");

// A coin thrown in a project with no backend lands nowhere. The build says
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
