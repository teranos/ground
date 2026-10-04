module quote_claims_test;

// "Quote needs to pass always, and sky needs to be told later by QNTX that the Quote is nonexistent, if that is true"
// The hook only says which spans a write claims; whether anybody said them is
// asked on the node.

import control_handlers : quoteClaims, claimsInto, QuoteClaims;
import db : ZBuf;

private bool nothingStands(const(char)[] span) { return false; }

unittest {
    // Prose in a document is every line; a single word is a name, not a claim;
    // an empty pair claims nothing anybody could check.
    enum doc = "intro\n\"nobody ever typed these words\"\nthe \"open\" case\n\"\"\n";
    auto c = quoteClaims(doc, "notes.md", &nothingStands);
    assert(c.count == 1, "one claim");
    assert(c.span(doc, 0) == "nobody ever typed these words");

    // In code only a comment line is prose; a string literal is code.
    enum code = "enum x = \"not a claim at all\";\n// \"a claim in a comment\"\n";
    auto k = quoteClaims(code, "a.d", &nothingStands);
    assert(k.count == 1 && k.span(code, 0) == "a claim in a comment");
}

unittest {
    // A span already standing in the file is not this write's to claim.
    static bool alreadyThere(const(char)[] span) { return span == "said long ago"; }
    enum doc = "\"said long ago\"\n\"said just now\"\n";
    auto c = quoteClaims(doc, "notes.md", &alreadyThere);
    assert(c.count == 1 && c.span(doc, 0) == "said just now");
}

unittest {
    // What the node is sent: the file and the spans, as one JSON object.
    __gshared ZBuf o;
    o.reset();
    auto c = quoteClaims(`"he said: no"`, "notes.md", &nothingStands);
    claimsInto(o, "/x/notes.md", `"he said: no"`, c);
    assert(o.slice() == `{"file_path":"/x/notes.md","spans":["he said: no"]}`, o.slice());
}
