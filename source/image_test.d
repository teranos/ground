module image_test;

// "Agent supports ContentBlock::Image": the image a client puts in a prompt is
// read, given to the model as the gateway takes an image, and told back with
// the rest of the conversation.

import code;
import code.prompt : promptText, Blocks, userMessage, replayHistory, unusableImage;
import code.reply : Reply;
import matcher : indexOf;

enum PNG = "iVBORw0KGgo=";

// The prompt's images, each a mimeType and its data, ended by a NUL, in order,
// beside its text: an image is something given, not a block refused.
unittest {
    Reply text, other, links, embedded, images, said;
    scope(exit) { text.dispose(); other.dispose(); links.dispose(); embedded.dispose(); images.dispose(); said.dispose(); }
    auto blocks = promptText(`{"prompt":[{"type":"text","text":"what is this"},`
        ~ `{"type":"image","mimeType":"image/png","data":"` ~ PNG ~ `"},{"type":"text","text":"and this"},`
        ~ `{"type":"image","mimeType":"image/jpeg","data":"/9j/"}]}`, text, other, links, embedded, images, said);
    assert(blocks == Blocks.read);
    assert(text.slice() == "what is this\nand this");
    assert(images.slice() == "image/png\0" ~ PNG ~ "\0image/jpeg\0/9j/\0");
    // An image missing its data is still another kind, said by its type.
    Reply t2, o2, l2, e2, i2, s2;
    scope(exit) { t2.dispose(); o2.dispose(); l2.dispose(); e2.dispose(); i2.dispose(); s2.dispose(); }
    assert(promptText(`{"prompt":[{"type":"image","mimeType":"image/png"}]}`, t2, o2, l2, e2, i2, s2) == Blocks.other);
    assert(o2.slice() == "image");
}

// The model is given the user's words and images as one message, as the
// gateway takes them: a text part, then each image as an image_url holding a
// data URL. Words alone stay a string, as they were.
unittest {
    Reply h;
    scope(exit) h.dispose();
    userMessage(h, "what is this", "image/png\0" ~ PNG ~ "\0");
    assert(h.slice() == `{"role":"user","content":[{"type":"text","text":"what is this"},`
        ~ `{"type":"image_url","image_url":{"url":"data:image/png;base64,` ~ PNG ~ `"}}]}`);
    h.len = 0;
    userMessage(h, "", "image/png\0" ~ PNG ~ "\0");
    assert(h.slice() == `{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,` ~ PNG ~ `"}}]}`);
    h.len = 0;
    userMessage(h, "hi");
    assert(h.slice() == `{"role":"user","content":"hi"}`);
}

// A data URL is "data:" mimeType ";base64," data: a mimeType that is no type
// and subtype, or data that is not base64, would make it another URL, so the
// image is refused by what is wrong with it.
unittest {
    assert(unusableImage("image/png", PNG) is null);
    assert(unusableImage("image/svg+xml", "PHN2Zz4=") is null);
    assert(unusableImage("image/png,evil", PNG) == "its mimeType is not a type/subtype");
    assert(unusableImage("png", PNG) == "its mimeType is not a type/subtype");
    assert(unusableImage("image/png", "abc,def") == "its data is not base64");
    assert(unusableImage("image/png", "") == "its data is empty");
}

// Told back on session/load: the user's words, then each image, as the user
// gave them.
unittest {
    Reply told;
    scope(exit) told.dispose();
    bool send(const(char)[] u) { told.add(u); told.add("\n"); return true; }
    assert(replayHistory(`{"role":"user","content":[{"type":"text","text":"what is this"},`
        ~ `{"type":"image_url","image_url":{"url":"data:image/png;base64,` ~ PNG ~ `"}}]},`
        ~ `{"role":"assistant","content":"a pixel"}`, &send));
    assert(told.slice() ==
          `{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"what is this"}}` ~ "\n"
        ~ `{"sessionUpdate":"user_message_chunk","content":{"type":"image","mimeType":"image/png","data":"` ~ PNG ~ `"}}` ~ "\n"
        ~ `{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"a pixel"}}` ~ "\n");
}

// "Other variants must be explicitly opted in to": ground code opts in to images.
unittest {
    Sessions s = Sessions(100, 7);
    Reply r;
    scope(exit) r.dispose();
    assert(answer(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}`, r, s));
    assert(indexOf(r.slice(), `"promptCapabilities":{"embeddedContext":true,"image":true}`) >= 0);
}

// An image the data URL cannot carry is refused before the model is asked, by
// what is wrong with it.
unittest {
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    s.node.url = "http://127.0.0.1:9"; s.node.model = "m"; s.contextSize = 200_000;
    Reply r;
    scope(exit) r.dispose();
    answer(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, r, s);
    r.len = 0;
    answer(`{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[`
        ~ `{"type":"image","mimeType":"image/png,x","data":"` ~ PNG ~ `"}]}}`, r, s);
    assert(r.slice() == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"ground code cannot give the model an image whose mimeType is not a type/subtype: image/png,x"}}`);
    if (s.open[0].history !is null) s.open[0].history.dispose();
}

// A turn with an image: the gateway is asked with the image in the user's
// message, and the history keeps it, so the next turn and a load have it.
version (Posix) unittest {
    import core.sys.posix.unistd : pipe, write, close, fork, _exit, read, dup, dup2;
    import core.sys.posix.sys.socket : socket, bind, listen, accept, getsockname, sockaddr, socklen_t, AF_INET, SOCK_STREAM;
    import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
    import core.sys.posix.sys.wait : waitpid;
    import core.stdc.stdio : fflush, stdout;

    enum reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n"
        ~ `{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"a pixel"}}]}`;
    auto fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(fd, cast(sockaddr*) &a, a.sizeof) == 0 && listen(fd, 1) == 0);
    socklen_t n = a.sizeof;
    assert(getsockname(fd, cast(sockaddr*) &a, &n) == 0);
    int[2] heard;
    assert(pipe(heard) == 0);
    auto child = fork();
    if (child == 0) {
        import core.sys.posix.unistd : alarm;
        alarm(30);
        close(heard[0]);
        auto c = accept(fd, null, null);
        char[65536] got;
        size_t have = 0;
        while (have < got.length) {
            auto k = read(c, got.ptr + have, got.length - have);
            if (k <= 0) break;
            have += cast(size_t) k;
            if (indexOf(got[0 .. have], `"messages"`) >= 0 && got[have - 1] == '}') break;
        }
        write(heard[1], got.ptr, have);
        write(c, reply.ptr, reply.length);
        close(c);
        _exit(0);
    }
    close(fd);
    close(heard[1]);
    __gshared char[32] urlBuf;
    ushort port = htons(a.sin_port);
    size_t len = 0;
    foreach (ch; "http://127.0.0.1:") urlBuf[len++] = ch;
    char[8] d; size_t k = 0;
    do { d[k++] = cast(char)('0' + port % 10); port /= 10; } while (port);
    while (k) urlBuf[len++] = d[--k];

    int[2] p;
    assert(pipe(p) == 0);
    Input input = Input(p[0]);
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    s.node.url = cast(string) urlBuf[0 .. len]; s.node.model = "m"; s.node.token = "/nonexistent"; s.contextSize = 200_000;
    s.input = &input;
    scope(exit) { input.dispose(); close(p[0]); close(p[1]); waitpid(child, null, 0); }
    int[2] o;
    assert(pipe(o) == 0);
    fflush(stdout);
    auto saved = dup(1);
    dup2(o[1], 1);
    Reply r;
    scope(exit) r.dispose();
    answer(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, r, s); r.len = 0;
    answer(`{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[`
        ~ `{"type":"text","text":"what is this"},{"type":"image","mimeType":"image/png","data":"` ~ PNG ~ `"}]}}`, r, s);
    fflush(stdout); dup2(saved, 1); close(saved); close(o[1]);
    __gshared char[65536] said;
    size_t saidLen = 0;
    while (true) {
        auto got = read(o[0], said.ptr + saidLen, said.length - saidLen);
        if (got <= 0) break;
        saidLen += cast(size_t) got;
    }
    close(o[0]);
    __gshared char[65536] asked;
    size_t askedLen = 0;
    while (true) {
        auto got = read(heard[0], asked.ptr + askedLen, asked.length - askedLen);
        if (got <= 0) break;
        askedLen += cast(size_t) got;
    }
    close(heard[0]);
    assert(r.slice() == `{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}`);
    assert(indexOf(asked[0 .. askedLen], `{"role":"user","content":[{"type":"text","text":"what is this"},`
        ~ `{"type":"image_url","image_url":{"url":"data:image/png;base64,` ~ PNG ~ `"}}]}`) >= 0);
    assert(indexOf(s.open[0].history.slice(), `"data:image/png;base64,` ~ PNG ~ `"`) >= 0);
    s.open[0].history.dispose();
}
