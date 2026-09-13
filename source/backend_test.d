module backend_test;

// BOOK_GLOSSARY **Backend**: The QNTX a project attests to, named by its url on the project block.

import proto : parsePbt;
import backend : postings, unbacked;

// The dike watch attests its level to the polder's pond. The Ffestiniog
// signal runs against a pond on the laptop. Coinflip's heads names no pond.
// The creek's routes are carried to every pond there is.
enum fanInput = `
project {
  origin: "veenpolder/dijkwacht"
  path: "/Users/me/grove/dijkwacht"
  qntx: "https://pond.veenpolder.invalid"
  attestation {
    subject: "dijk:peil"
    predicate: "peil:gemeten"
    context: "project:veenpolder/dijkwacht"
  }
}
project {
  origin: "ffestiniog/signal"
  path: "/Users/me/grove/signal"
  qntx: "http://localhost:8771"
}
project {
  origin: "coinflip/heads"
  path: "/Users/me/grove/heads"
}
attestation {
  subject: "creek:routes"
  predicate: "creek:carries"
  context: "project:grove"
}
`;
enum fanParsed = parsePbt(fanInput);
enum fan = postings(fanParsed);

// An attestation knows the project it was written in; a top-level one none.
static assert(fanParsed.attestations[0].project == "/Users/me/grove/dijkwacht");
static assert(fanParsed.attestations[1].project == "");

static assert(fan.len == 3);
static assert(fan.items[0].url == "https://pond.veenpolder.invalid" && fan.items[0].subject == "dijk:peil");
static assert(fan.items[1].url == "https://pond.veenpolder.invalid" && fan.items[1].subject == "creek:routes");
static assert(fan.items[2].url == "http://localhost:8771" && fan.items[2].subject == "creek:routes");
static assert(unbacked(fanParsed) == "");

// A coin thrown in a project with no pond lands nowhere. The build says which
// coin, rather than posting it nowhere in silence.
enum strandedInput = `
project {
  origin: "coinflip/heads"
  path: "/Users/me/grove/heads"
  attestation {
    subject: "munt:geworpen"
    predicate: "munt:kop"
    context: "project:coinflip/heads"
  }
}
`;
enum strandedParsed = parsePbt(strandedInput);
static assert(unbacked(strandedParsed) == "munt:geworpen");
static assert(postings(strandedParsed).len == 0);
