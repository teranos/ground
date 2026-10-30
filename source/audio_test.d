module audio_test;

// "Agent supports ContentBlock::Audio": the audio a client puts in a prompt is
// read, given to the model as the gateway takes audio, an input_audio part
// holding its base64 data and its format, and told back with the rest of the
// conversation.

import code;
import code.prompt : promptText, Blocks, userMessage, replayHistory, audioFormat;
import code.reply : Reply;
import matcher : indexOf;

enum WAV = "UklGRiQAAABXQVZF";

// The prompt's audio, each a mimeType and its data, ended by a NUL, in order.
unittest {
    Reply text, other, links, embedded, images, audio, said;
    scope(exit) { text.dispose(); other.dispose(); links.dispose(); embedded.dispose(); images.dispose(); audio.dispose(); said.dispose(); }
    auto blocks = promptText(`{"prompt":[{"type":"text","text":"what is said"},`
        ~ `{"type":"audio","mimeType":"audio/wav","data":"` ~ WAV ~ `"}]}`, text, other, links, embedded, images, audio, said);
    assert(blocks == Blocks.read);
    assert(text.slice() == "what is said");
    assert(images.len == 0);
    assert(audio.slice() == "audio/wav\0" ~ WAV ~ "\0");
}

// The gateway names audio by format, "wav, mp3, flac, m4a, ogg, aiff, aac",
// where ACP names it by mimeType: each type the formats are known by, and
// none for a type ground code knows no format of.
unittest {
    assert(audioFormat("audio/wav") == "wav");
    assert(audioFormat("audio/x-wav") == "wav");
    assert(audioFormat("audio/mpeg") == "mp3");
    assert(audioFormat("audio/flac") == "flac");
    assert(audioFormat("audio/mp4") == "m4a");
    assert(audioFormat("audio/ogg") == "ogg");
    assert(audioFormat("audio/aiff") == "aiff");
    assert(audioFormat("audio/aac") == "aac");
    assert(audioFormat("AUDIO/WAV") == "wav");
    assert(audioFormat("audio/basic") is null);
    assert(audioFormat("image/png") is null);
}

// The user's words, then their images, then their audio, as the gateway takes
// them: "type":"input_audio", its data "Base64 encoded audio data" and its format.
unittest {
    Reply h;
    scope(exit) h.dispose();
    userMessage(h, "what is said", null, "audio/x-wav\0" ~ WAV ~ "\0");
    assert(h.slice() == `{"role":"user","content":[{"type":"text","text":"what is said"},`
        ~ `{"type":"input_audio","input_audio":{"data":"` ~ WAV ~ `","format":"wav"}}]}`);
    h.len = 0;
    userMessage(h, "", "image/png\0iVBO\0", "audio/mpeg\0SUQz\0");
    assert(h.slice() == `{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,iVBO"}},`
        ~ `{"type":"input_audio","input_audio":{"data":"SUQz","format":"mp3"}}]}`);
}

// Told back on session/load as audio, by the type its format is named for.
unittest {
    Reply told;
    scope(exit) told.dispose();
    bool send(const(char)[] u) { told.add(u); told.add("\n"); return true; }
    assert(replayHistory(`{"role":"user","content":[{"type":"text","text":"what is said"},`
        ~ `{"type":"input_audio","input_audio":{"data":"` ~ WAV ~ `","format":"wav"}}]}`, &send));
    assert(told.slice() ==
          `{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"what is said"}}` ~ "\n"
        ~ `{"sessionUpdate":"user_message_chunk","content":{"type":"audio","mimeType":"audio/wav","data":"` ~ WAV ~ `"}}` ~ "\n");
}

// "Other variants must be explicitly opted in to": ground code opts in to audio.
unittest {
    Sessions s = Sessions(100, 7);
    Reply r;
    scope(exit) r.dispose();
    assert(answer(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}`, r, s));
    assert(indexOf(r.slice(), `"promptCapabilities":{"embeddedContext":true,"image":true,"audio":true}`) >= 0);
}

// Audio whose mimeType names no format the gateway takes, or whose data is not
// base64, is refused by what is wrong with it, before the model is asked.
unittest {
    Sessions s = Sessions(100, 7); s.clock = 1_700_000_000;
    s.node.url = "http://127.0.0.1:9"; s.node.model = "m"; s.contextSize = 200_000;
    Reply r;
    scope(exit) r.dispose();
    answer(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}`, r, s);
    r.len = 0;
    answer(`{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[`
        ~ `{"type":"audio","mimeType":"audio/basic","data":"` ~ WAV ~ `"}]}}`, r, s);
    assert(r.slice() == `{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"ground code knows no gateway audio format for the mimeType audio/basic"}}`);
    r.len = 0;
    answer(`{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"code-100-7-1","prompt":[`
        ~ `{"type":"audio","mimeType":"audio/wav","data":"a,b"}]}}`, r, s);
    assert(r.slice() == `{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"ground code cannot give the model audio whose data is not base64: audio/wav"}}`);
    if (s.open[0].history !is null) s.open[0].history.dispose();
}

// A turn with audio: the gateway is asked with the audio in the user's
// message, and the history keeps it.
version (Posix) unittest {
    import core.sys.posix.unistd : pipe, write, close, fork, _exit, read, dup, dup2;
    import core.sys.posix.sys.socket : socket, bind, listen, accept, getsockname, sockaddr, socklen_t, AF_INET, SOCK_STREAM;
    import core.sys.posix.netinet.in_ : sockaddr_in, htons, htonl, INADDR_LOOPBACK;
    import core.sys.posix.sys.wait : waitpid;
    import core.stdc.stdio : fflush, stdout;

    enum reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n"
        ~ `{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"hello"}}]}`;
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
        ~ `{"type":"text","text":"what is said"},{"type":"audio","mimeType":"audio/wav","data":"` ~ WAV ~ `"}]}}`, r, s);
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
    assert(indexOf(asked[0 .. askedLen], `{"role":"user","content":[{"type":"text","text":"what is said"},`
        ~ `{"type":"input_audio","input_audio":{"data":"` ~ WAV ~ `","format":"wav"}}]}`) >= 0);
    assert(indexOf(s.open[0].history.slice(), `"input_audio":{"data":"` ~ WAV ~ `","format":"wav"}`) >= 0);
    s.open[0].history.dispose();
}
