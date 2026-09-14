module fmt_test;

// "it almost feels like we should want a ground fmt"
// One canonical layout for pbt: a block header on its own line, one field
// per line, two spaces per level, the closing brace on its own line.

import fmt : formatPbt;

// A one-line group is the same group, set the way every well-set fixture
// in the book already is. These inputs are strings, not fixtures: what fmt
// reads badly on purpose is not an example of anything.
enum oneLine = q"EOS
rites a { shared { eval: "true" }  shared { eval: "true" } }
EOS";
enum oneLineSet = q"EOS
rites a {
  shared {
    eval: "true"
  }
  shared {
    eval: "true"
  }
}
EOS";
static assert(formatPbt(oneLine).text() == oneLineSet);

// What is already canonical comes back unchanged, so fmt is a fixed point.
enum canon =
    "project {\n"
    ~ "  path: \"/src/proj\"\n"
    ~ "\n"
    ~ "  env {\n"
    ~ "    api: \"https://api.coin.flip.example\"\n"
    ~ "  }\n"
    ~ "\n"
    ~ "  ritual probe {\n"
    ~ "    parity { row: \"watchers\" }\n"
    ~ "    live\n"
    ~ "  }\n"
    ~ "}\n";
static assert(formatPbt(canon).text() == canon);

// A comment stays where it was written: on its own line at the depth it
// sits in, or after the field it follows.
enum commented =
    "# The whole file.\n"
    ~ "scope {\n"
    ~ "    # Where it stands.\n"
    ~ "    path: \"/\"   # the root\n"
    ~ "}\n";
static assert(formatPbt(commented).text() ==
    "# The whole file.\n"
    ~ "scope {\n"
    ~ "  # Where it stands.\n"
    ~ "  path: \"/\"  # the root\n"
    ~ "}\n");

// A blank line is a break the author meant, kept as one. Several are one.
enum spaced = "scope {\n  path: \"/\"\n\n\n\n  event: \"Stop\"\n}\n";
static assert(formatPbt(spaced).text() == "scope {\n  path: \"/\"\n\n  event: \"Stop\"\n}\n");

// A list that fits on its line stays on it; one that does not is one item
// per line, the way project files are written.
enum shortList = "permission {\n  allow: [\"go build*\",   \"go test*\"]\n}\n";
static assert(formatPbt(shortList).text() == "permission {\n  allow: [\"go build*\", \"go test*\"]\n}\n");
enum longList = "project {\n  files: [\"source/main.d\", \"source/proto.d\", \"controls/controls.pbt\", \"source/routes.d\"]\n}\n";
static assert(formatPbt(longList).text() ==
    "project {\n"
    ~ "  files: [\n"
    ~ "    \"source/main.d\",\n"
    ~ "    \"source/proto.d\",\n"
    ~ "    \"controls/controls.pbt\",\n"
    ~ "    \"source/routes.d\"\n"
    ~ "  ]\n"
    ~ "}\n");

// A value is never touched: a backtick command with braces and a hash in it
// is copied as it is.
enum tricky = q"EOS
rites r {
  x { eval: `awk '{print $1}' # not a comment` }
}
EOS";
enum trickySet = q"EOS
rites r {
  x {
    eval: `awk '{print $1}' # not a comment`
  }
}
EOS";
static assert(formatPbt(tricky).text() == trickySet);

// An attestation's attributes are JSON, carried whole and reindented.
enum attrs = "attestation {\n  subject: \"x\"\n  attributes: {\n        \"a\": 1,\n        \"b\": \"c\"\n      }\n}\n";
static assert(formatPbt(attrs).text() ==
    "attestation {\n  subject: \"x\"\n  attributes: {\n    \"a\": 1,\n    \"b\": \"c\"\n  }\n}\n");

// A reference with values is one line, since it is one reference.
enum reference = "project {\n  ritual r {\n    parity {\n      row: \"watchers\"\n    }\n  }\n}\n";
static assert(formatPbt(reference).text() ==
    "project {\n  ritual r {\n    parity { row: \"watchers\" }\n  }\n}\n");

// include names a file and carries no colon.
static assert(formatPbt("include   \"other.pbt\"\n").text() == "include \"other.pbt\"\n");
