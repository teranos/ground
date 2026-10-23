module code_test;

import code;
import db : versionString;

private string answerOf()(string line) {
    Reply r;
    if (!answer(line, r)) return null;
    return r.slice().idup;
}

// initialize: the only required field either way is protocolVersion. ACP's is
// 1, bumped only for breaking changes; ground's own version is agentInfo's.
static assert(answerOf(`{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1}}`)
    == `{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentInfo":{"name":"ground","version":"`
       ~ versionString() ~ `"}}}`);

// "The protocol version the client specified if supported by the agent, or the
// latest protocol version supported by the agent."
static assert(answerOf(`{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":7}}`)
    == `{"jsonrpc":"2.0","id":"a","result":{"protocolVersion":1,"agentInfo":{"name":"ground","version":"`
       ~ versionString() ~ `"}}}`);

// A method ground code does not handle is said to the client, by name.
static assert(answerOf(`{"jsonrpc":"2.0","id":3,"method":"session/new","params":{}}`)
    == `{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"ground code does not handle session/new"}}`);

// A notification has no answer to give; the caller says it on stderr instead.
static assert(answerOf(`{"jsonrpc":"2.0","method":"session/cancel","params":{}}`) is null);

// A line naming no method is not a request.
static assert(answerOf(`{"jsonrpc":"2.0","id":4}`)
    == `{"jsonrpc":"2.0","id":4,"error":{"code":-32600,"message":"no method"}}`);
static assert(answerOf(`not json`)
    == `{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"no method"}}`);
