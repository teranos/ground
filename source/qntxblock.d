module qntxblock;

// 「[Opus 5.5] The qntx block and its reader, apart from the rest of the pbt parser: ground」
// 「[Opus 5.5] code reads its node with them and compiles none of what the hooks parse.」

import lexer : skipWS, skipLine, expect, readWord, readValue;

// 「[Opus 5.5] The qntx { } block. At the top level it names the node: url, where ground」
// 「[Opus 5.5] writes its namespace, signed with ~/.qntx/key; gateway, the node signed in to.」
//
// "A signature proves the key, and nothing reusable leaves the node."
struct ParsedQntx {
    bool present;
    string url;
    string model;   // what ground code prompts through the gateway
    string gateway; // the node signed in to: it answers prompts and gives the sand; url when empty
}

// 「[Opus 5.5] url:, model: and gateway:, and nothing else.」
ParsedQntx parseQntxBlock(ref string input, ref size_t pos) {
    ParsedQntx q;
    q.present = true;

    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }
        if (input[pos] == '}') { pos++; return q; }

        auto key = readWord(input, pos);
        skipWS(input, pos);
        expect(input, pos, ':');
        skipWS(input, pos);
        auto val = readValue(input, pos);

        if (key == "token") assert(0, "a qntx block names no token: ground signs with ~/.qntx/key");
        else if (key == "url") q.url = val;
        else if (key == "model") q.model = val;
        else if (key == "gateway") q.gateway = val;
        else assert(0, "Unknown qntx field");
    }
    assert(0, "Unterminated qntx block");
}
