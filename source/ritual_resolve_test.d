module ritual_resolve_test;

// A ritual names groups; the position walks rites. The flat list is both the
// order they run in and the index `goto` needs.

import proto : parsePbt;
import ritual : flatten, indexOfRite;

enum src = `
rites parity {
  params: [row]
  parity { eval: "make parity" }
}

rites live {
  sealed { eval: "git diff --quiet" }
  ci     { eval: "gh pr checks 833"  catch: 1 }
}

project {
  path: "/src/proj"
  env { api: "https://api.example.invalid" }

  ritual probe {
    parity { row: "watchers" }
    live
  }
}
`;
enum parsed = parsePbt(src);

enum flat = flatten(parsed, 0);
static assert(flat.count == 3);
static assert(flat.rites[0].name == "parity");
static assert(flat.rites[1].name == "sealed");
static assert(flat.rites[2].name == "ci");

// Group order is ritual order, not declaration order in the file.
static assert(flat.rites[0].group == "parity");
static assert(flat.rites[2].group == "live");

// A rite carries the values its reference supplied.
static assert(flat.rites[0].valueCount == 1);
static assert(flat.rites[0].keys[0] == "row");
static assert(flat.rites[0].values[0] == "watchers");

// A bare reference carries nothing, and its rites carry nothing either.
static assert(flat.rites[1].valueCount == 0);

// What a rite declared survives the flattening; without it `classify` would
// read every rite as the default 0-pass, 1-catch.
static assert(flat.rites[2].catchCount == 1);
static assert(flat.rites[2].catches[0] == 1);
static assert(flat.rites[1].catches[0] == 1);
static assert(flat.rites[1].pass == 0);

// `goto` names a rite; `jump` takes an index. This is the only mapping.
static assert(indexOfRite(flat, "ci") == 2);
static assert(indexOfRite(flat, "parity") == 0);
static assert(indexOfRite(flat, "nowhere") == -1);

// "a RITUAL is not finished until each of its rites blocks finished" — the
// boundary the gate sits on. `parity` is one rite, `live` is two.
import ritual.resolve : lastOfBlock;

static assert(lastOfBlock(flat, 0));
static assert(!lastOfBlock(flat, 1));
static assert(lastOfBlock(flat, 2));

// Past the end is not a boundary, it is off the walk.
static assert(!lastOfBlock(flat, 3));
