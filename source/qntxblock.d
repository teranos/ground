module qntxblock;

// The qntx block and its reader, apart from the rest of the pbt parser: ground
// code reads its node with them and compiles none of what the hooks parse.

import lexer : skipWS, skipLine, expect, readWord, readValue;

// The qntx { } block. At the top level it names the nodes: url, where ground writes its
// namespace, and token, the path of the file holding what url is spoken to with — empty
// means QNTX_TOKEN, then ~/.qntx/token. gateway is the node signed in to with ~/.qntx/token.
struct ParsedQntx {
    bool present;
    string url;
    string token;
    string model;   // what ground code prompts through the gateway
    string gateway; // the node signed in to: it answers prompts and gives the sand; url when empty
}

// url:, token:, model: and gateway:, and nothing else.
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

        if (key == "token") q.token = val;
        else if (key == "url") q.url = val;
        else if (key == "model") q.model = val;
        else if (key == "gateway") q.gateway = val;
        else assert(0, "Unknown qntx field");
    }
    assert(0, "Unterminated qntx block");
}
