module code.node;

// The node ground code prompts through: the top-level qntx block of the controls wind gathered, read
// alone by the reader controls reads it with, so ground code compiles none of the hooks controls drive.

import qntxblock : ParsedQntx, parseQntxBlock;

// A top-level block starts its line, as `ground fmt` lays every pbt out; one nested in another does not.
private ParsedQntx qntxIn()(string sand) {
    ParsedQntx found;
    size_t line = 0;
    while (line < sand.length) {
        auto end = line;
        while (end < sand.length && sand[end] != '\n') end++;
        auto p = line;
        if (end - line >= 4 && sand[line .. line + 4] == "qntx") {
            p = line + 4;
            while (p < end && (sand[p] == ' ' || sand[p] == '\t')) p++;
            if (p < end && sand[p] == '{') {
                assert(!found.present, "a second top-level qntx block would name a second node");
                p++;
                found = parseQntxBlock(sand, p);
                assert(found.url.length > 0, "the top-level qntx block names the node: url");
            }
        }
        line = end + 1;
    }
    return found;
}

import sand.text : SAND_TEXT;
static immutable ParsedQntx qntxNode = qntxIn(SAND_TEXT);
