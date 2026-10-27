module code.mcp;

// Ground owns these connections. ACP configures them; the harness's tool
// dispatcher calls callMcpTool. No provider or LLM SDK owns their lifetime.
import libmcp;
import libjsonc;
import code.reply : Reply, putEscaped, putNumber;
import core.stdc.stdlib : calloc, malloc, free;
import core.stdc.string : strlen, strcmp, strncmp, memcpy;
import core.stdc.stdio : stderr, fputs, fwrite, snprintf;
import core.sys.posix.strings : strcasecmp;

extern(C) extern __gshared const(char*)* environ;

struct McpContract { mcp_tool* tool; McpContract* next; }
struct McpPage { mcp_response response; McpPage* next; }
struct McpServer {
    char* name;
    mcp_client* client;
    McpContract* contracts;
    McpPage* tools; // all tools/list pages, kept whole for the harness
    McpPage* prompts; // all prompts/list pages, kept whole: the session's commands
    int timeoutMs;  // the per-request deadline its client was opened with
}
struct McpGroup { McpServer* servers; size_t count; }

private const(char)* stringAt(json_object* value) {
    if (json_object_get_type(value) != json_type.string_) return null;
    auto s = json_object_get_string(value);
    if (s is null || strlen(s) != cast(size_t) json_object_get_string_len(value)) return null;
    return s; // embedded NUL is rejected rather than truncating an argument
}

private char* copy(const(char)* s) {
    auto n = strlen(s) + 1;
    auto out_ = cast(char*) malloc(n);
    if (out_ !is null) memcpy(out_, s, n);
    return out_;
}

private void quoted(ref Reply r, const(char)* s) {
    r.add(`"`);
    if (s !is null) putEscaped(r, s[0 .. strlen(s)]);
    r.add(`"`);
}

private void failure(ref Reply r, const(char)* server, ref const mcp_error e,
                     ref const mcp_response response, const(mcp_response)* validation = null) {
    r.add(`{"server":`); quoted(r, server);
    r.add(`,"status":`); quoted(r, mcp_status_string(e.code));
    r.add(`,"systemErrno":`); putNumber(r, cast(uint) e.system_errno);
    r.add(`,"childStatus":`); putNumber(r, cast(uint) e.child_status);
    r.add(`,"message":`); quoted(r, e.message);
    // A string preserves malformed frames as well as valid remote error data.
    r.add(`,"response":`);
    r.add(`"`);
    if (response.json !is null) putEscaped(r, response.json[0 .. response.length]);
    r.add(`","cleanupStatus":`); quoted(r, mcp_status_string(e.cleanup_code));
    r.add(`,"cleanupErrno":`); putNumber(r, cast(uint) e.cleanup_errno);
    r.add(`,"cleanupChildStatus":`); putNumber(r, cast(uint) e.cleanup_child_status);
    r.add(`,"cleanupMessage":`); quoted(r, e.cleanup_message);
    r.add(`,"validation":`);
    if (validation !is null && validation.json !is null) r.add(validation.json[0 .. validation.length]);
    else r.add("null");
    r.add(`}`);
}

// What a server asks of ground code while one of its calls runs, asked of
// whoever is running the call: 1 answered, the result object in answer; 0
// refused, the asker's error object in answer; 2 the turn was called off; -1
// it could not ask, why in answer as a JSON string. A notification is passed
// to it as well, method and params, and its answer is not read.
alias Ask = int delegate(const(char)[] method, const(char)[] params, ref Reply answer);
private __gshared Ask asking; // the call under way's, while one is

private extern(C) void ground_mcp_log(void* context, const(char)* json, size_t length) nothrow @nogc {
    fputs("ground MCP [", stderr);
    if (context !is null) fputs(cast(const(char)*) context, stderr);
    fputs("]: ", stderr); fwrite(json, 1, length, stderr); fputs("\n", stderr);
}

// What a session's server logs while one of its calls runs, at warning or
// above, heard by whoever runs the call: the server's name, the level, and
// what it logged, as text when it is a string and as JSON when it is not.
alias Hear = void delegate(const(char)[] server, const(char)[] level, const(char)[] data);
private __gshared Hear hearing; // the call under way's, while one is

// MCP's levels, from the least: what is heard starts at warning.
private static immutable string[5] HEARD = ["warning", "error", "critical", "alert", "emergency"];
private bool heard(const(char)* level) {
    foreach (l; HEARD)
        if (strcmp(level, l.ptr) == 0) return true;
    return false;
}

// A server's notifications/message, heard when a call runs and it is at
// warning or above.
private void heardLine(void* context, json_object* message) {
    if (hearing is null) return;
    auto params = jsonField(message, "params");
    auto level = stringAt(jsonField(params, "level"));
    if (level is null || !heard(level)) return;
    auto data = jsonField(params, "data");
    auto text = stringAt(data);
    if (text is null) text = json_object_to_json_string_ext(data, JSON_C_TO_STRING_PLAIN | JSON_C_TO_STRING_NOSLASHESCAPE);
    auto server = cast(const(char)*) context;
    hearing(server is null ? "" : server[0 .. strlen(server)], level[0 .. strlen(level)], text[0 .. strlen(text)]);
}

// A server's message, written down; a log line at warning or above heard, and
// a notification the asker is waiting on passed to it:
// "notifications/elicitation/complete" says a url elicitation it asked for is done.
private extern(C) void ground_mcp_message(void* context, const(char)* json, size_t length) {
    ground_mcp_log(context, json, length);
    if (asking is null && hearing is null) return;
    auto message = parseJson(json[0 .. length]);
    scope(exit) json_object_put(message);
    auto method = stringAt(jsonField(message, "method"));
    if (method is null || jsonField(message, "id") !is null) return;
    if (strcmp(method, "notifications/message") == 0) { heardLine(context, message); return; }
    if (asking is null || strcmp(method, "notifications/elicitation/complete") != 0) return;
    auto params = jsonField(message, "params");
    if (json_object_get_type(params) != json_type.object) return;
    auto text = json_object_to_json_string_ext(params, JSON_C_TO_STRING_PLAIN | JSON_C_TO_STRING_NOSLASHESCAPE);
    Reply ignored;
    scope(exit) ignored.dispose();
    asking(method[0 .. strlen(method)], text[0 .. strlen(text)], ignored);
}

// libmcp's handler for what ground code declared a session's servers may ask,
// its elicitation: the asker's answer is the server's. A turn called off is
// the user's cancel; one ground code could not ask is an error the server reads.
private extern(C) mcp_status ground_mcp_ask(void*, const(char)* method, const(char)* params,
                                            mcp_response* result, mcp_error* error) {
    Reply answer;
    scope(exit) answer.dispose();
    auto got = asking is null ? -1 : asking(method[0 .. strlen(method)], params[0 .. strlen(params)], answer);
    if (asking is null) answer.add(`"no call of ground code's is under way to ask for"`);
    if (got == 2) { answer.len = 0; answer.add(`{"action":"cancel"}`); got = 1; }
    if (got < 0) {
        Reply why;
        scope(exit) why.dispose();
        why.add(`{"code":-32603,"message":`); why.add(answer.slice()); why.add(`}`);
        answer.len = 0; answer.add(why.slice());
    }
    answer.add("\0");
    if (answer.full) return localError(*error, mcp_status.MCP_NO_MEMORY, "the answer to the server outgrew memory");
    auto set = mcp_response_set(result, answer.slice().ptr, error);
    if (set != mcp_status.MCP_OK) return set;
    return got == 1 ? mcp_status.MCP_OK : mcp_status.MCP_REMOTE_ERROR;
}

// What a session's servers are told they may ask and how, when there is
// anything to declare.
private bool featuresOf(const(char)* capabilities, ref mcp_features features) {
    if (capabilities is null) return false;
    mcp_features_init(&features);
    features.capabilities_json = capabilities;
    features.on_request = cast(mcp_handler_fn) &ground_mcp_ask;
    return true;
}

// Always attempts every close. Each failure reaches stderr and the ACP reply;
// EOF on ground code uses the same path for orderly host shutdown.
bool closeMcp(ref McpGroup group, ref Reply detail) {
    bool ok = true;
    detail.add("[");
    foreach (i; 0 .. group.count) {
        auto server = &group.servers[i];
        auto contract = server.contracts;
        while (contract !is null) {
            auto next = contract.next;
            mcp_tool_destroy(contract.tool); free(contract); contract = next;
        }
        McpPage*[2] kept = [server.tools, server.prompts];
        foreach (pages; kept) {
            auto page = pages;
            while (page !is null) {
                auto next = page.next;
                mcp_response_free(&page.response); free(page); page = next;
            }
        }
        mcp_error error;
        if (mcp_client_close(server.client, &error) != mcp_status.MCP_OK) {
            Reply row;
            mcp_response empty;
            failure(row, server.name, error, empty);
            ground_mcp_log(server.name, row.slice().ptr, row.len);
            if (!ok) detail.add(",");
            detail.add(row.slice()); row.dispose();
            ok = false;
        }
        free(server.name);
    }
    free(group.servers); group = McpGroup.init;
    detail.add("]");
    return ok;
}

private mcp_status localError(ref mcp_error e, mcp_status status, const(char)* message) {
    e = mcp_error.init; e.code = status; e.message = message;
    return status;
}

// "HTTP transport configuration": name, url and headers, all required. libmcp
// takes a bearer token for an endpoint and sets no other header, so an
// Authorization: Bearer header is the token and any other is refused by name,
// before anything is asked of the server. why says which.
private __gshared char[512] whyBuf;
private bool httpValid(json_object* config, const(char)* name, ref const(char)* why) {
    auto type = stringAt(jsonField(config, "type"));
    if (type is null || strcmp(type, "http") != 0) return false;
    auto headers = jsonField(config, "headers");
    if (name is null || !*name || stringAt(jsonField(config, "url")) is null ||
        json_object_get_type(headers) != json_type.array || json_object_array_length(headers) > 128) return false;
    bool bearer = false;
    foreach (j; 0 .. json_object_array_length(headers)) {
        auto entry = json_object_array_get_idx(headers, j);
        auto key = stringAt(jsonField(entry, "name")), value = stringAt(jsonField(entry, "value"));
        if (key is null || value is null) return false;
        if (strcasecmp(key, "Authorization") != 0) {
            snprintf(whyBuf.ptr, whyBuf.length, "the http MCP server %s names the header %s; libmcp sets no header but Authorization: Bearer", name, key);
            why = whyBuf.ptr;
            return false;
        }
        if (bearer || strncmp(value, "Bearer ", 7) != 0) {
            snprintf(whyBuf.ptr, whyBuf.length, "the http MCP server %s names an Authorization that is not Bearer; libmcp sets no other", name);
            why = whyBuf.ptr;
            return false;
        }
        bearer = true;
    }
    return true;
}

// The bearer token an http server's headers carry, or null: what follows
// "Bearer " in the one Authorization header httpValid let through.
private const(char)* bearerOf(json_object* config) {
    auto headers = jsonField(config, "headers");
    foreach (j; 0 .. json_object_array_length(headers)) {
        auto value = stringAt(jsonField(json_object_array_get_idx(headers, j), "value"));
        if (value !is null) return value + 7;
    }
    return null;
}

// Streamable HTTP, through libmcp: it holds TLS verification mandatory and
// plain HTTP to loopback only, and its refusal is the session's failure.
private mcp_status startHttp(json_object* config, const(char)* capabilities, ref McpServer server,
                              ref mcp_response response, ref mcp_error error) {
    mcp_options options;
    mcp_options_init(&options);
    server.timeoutMs = options.timeout_ms;
    options.client_name = "ground";
    options.on_message = cast(typeof(options.on_message)) &ground_mcp_message; options.context = server.name;
    mcp_features features;
    return mcp_client_open_http(&options, featuresOf(capabilities, features) ? &features : null,
        stringAt(jsonField(config, "url")), bearerOf(config), &server.client, &response, &error);
}

// How long a starting server has to answer libmcp's server/discover before
// it is taken for a legacy one and asked initialize. libmcp's own is 500ms; a
// server launched through npx or uvx takes seconds to start, and one that
// speaks 2026-07-28 alone refuses initialize. A legacy server answers
// server/discover at once, with method not found, so only one that never
// answers it waits this long.
enum MCP_PROBE_MS = 10_000;

// argv/env use the parsed JSON's strings only until spawn returns. ACP's env
// entries override inherited keys; the library receives a complete environment.
private mcp_status startServer(json_object* config, const(char)* cwd, const(char)* capabilities,
                               ref McpServer server, ref mcp_response response, ref mcp_error error) {
    auto args = jsonField(config, "args"), env = jsonField(config, "env");
    auto argc = json_object_array_length(args), envc = json_object_array_length(env);
    auto argv = cast(const(char)**) calloc(argc + 2, (char*).sizeof);
    if (argv is null) return localError(error, mcp_status.MCP_NO_MEMORY, "allocate MCP argv");
    scope(exit) free(argv);
    argv[0] = stringAt(jsonField(config, "command"));
    foreach (i; 0 .. argc) argv[i + 1] = stringAt(json_object_array_get_idx(args, i));
    size_t inherited;
    while (environ[inherited] !is null) inherited++;
    auto envp = cast(const(char)**) calloc(inherited + envc + 1, (char*).sizeof);
    auto values = cast(char**) calloc(envc + 1, (char*).sizeof);
    if (envp is null || values is null) {
        free(envp); free(values);
        return localError(error, mcp_status.MCP_NO_MEMORY, "allocate MCP environment");
    }
    scope(exit) { foreach (i; 0 .. envc) free(values[i]); free(values); free(envp); }
    foreach (i; 0 .. envc) {
        auto entry = json_object_array_get_idx(env, i);
        auto name = stringAt(jsonField(entry, "name")), value = stringAt(jsonField(entry, "value"));
        auto n = strlen(name), v = strlen(value);
        values[i] = cast(char*) malloc(n + v + 2);
        if (values[i] is null) return localError(error, mcp_status.MCP_NO_MEMORY, "allocate MCP environment value");
        memcpy(values[i], name, n); values[i][n] = '=';
        memcpy(values[i] + n + 1, value, v + 1);
    }
    size_t used;
    foreach (i; 0 .. inherited) {
        bool replaced;
        foreach (j; 0 .. envc) {
            auto key = stringAt(jsonField(json_object_array_get_idx(env, j), "name"));
            auto n = strlen(key);
            if (strncmp(environ[i], key, n) == 0 && environ[i][n] == '=') { replaced = true; break; }
        }
        if (!replaced) envp[used++] = environ[i];
    }
    foreach (i; 0 .. envc) envp[used++] = values[i];
    mcp_options options;
    mcp_options_init(&options);
    server.timeoutMs = options.timeout_ms;
    options.probe_timeout_ms = MCP_PROBE_MS;
    options.command = argv[0]; options.argv = cast(const(char*)*) argv;
    options.envp = cast(const(char*)*) envp; options.cwd = cwd;
    options.client_name = "ground";
    options.on_message = cast(typeof(options.on_message)) &ground_mcp_message; options.context = server.name;
    mcp_features features;
    return mcp_client_open_ex(&options, featuresOf(capabilities, features) ? &features : null,
        &server.client, &response, &error);
}

private mcp_status discoverTools(ref McpServer server, ref mcp_response response, ref mcp_response validation, ref mcp_error error) {
    const(char)* cursor;
    // Pages keep their storage, so cursor remains valid until the next call.
    json_object* parsed;
    scope(exit) json_object_put(parsed);
    McpPage** tail = &server.tools;
    foreach (_; 0 .. 128) {
        auto status = mcp_tools_list(server.client, cursor, &response, &error);
        // Servers with no tools capability can still supply resources/prompts.
        if (status == mcp_status.MCP_UNSUPPORTED) return mcp_status.MCP_OK;
        if (status != mcp_status.MCP_OK) return status;
        auto nextParsed = parseJson(response.json[0 .. response.length]);
        auto result = jsonField(nextParsed, "result");
        if (json_object_get_type(jsonField(result, "tools")) != json_type.array) {
            json_object_put(nextParsed);
            return localError(error, mcp_status.MCP_PROTOCOL_ERROR, "tools/list result has no tools array");
        }
        auto tools = jsonField(result, "tools");
        foreach (i; 0 .. json_object_array_length(tools)) {
            auto definition = json_object_array_get_idx(tools, i);
            auto row = cast(McpContract*) calloc(1, McpContract.sizeof);
            if (row is null) { json_object_put(nextParsed); return localError(error, mcp_status.MCP_NO_MEMORY, "allocate tool contract"); }
            auto status_ = mcp_tool_compile(json_object_to_json_string_ext(definition, JSON_C_TO_STRING_PLAIN), null, &row.tool, &validation, &error);
            if (status_ != mcp_status.MCP_OK) { free(row); json_object_put(nextParsed); return status_; }
            for (auto previous = server.contracts; previous !is null; previous = previous.next) {
                if (strcmp(mcp_tool_name(previous.tool), mcp_tool_name(row.tool)) == 0) {
                    mcp_tool_destroy(row.tool); free(row); json_object_put(nextParsed);
                    return localError(error, mcp_status.MCP_PROTOCOL_ERROR, "duplicate tool name in server catalog");
                }
            }
            row.next = server.contracts; server.contracts = row;
        }
        auto next = jsonField(result, "nextCursor");
        auto nextCursor = next is null ? null : stringAt(next);
        if (next !is null && nextCursor is null) {
            json_object_put(nextParsed);
            return localError(error, mcp_status.MCP_PROTOCOL_ERROR, "tools/list nextCursor is not a string");
        }
        if (cursor !is null && nextCursor !is null && strcmp(cursor, nextCursor) == 0) {
            json_object_put(nextParsed);
            return localError(error, mcp_status.MCP_PROTOCOL_ERROR, "tools/list repeated its cursor");
        }
        auto page = cast(McpPage*) calloc(1, McpPage.sizeof);
        if (page is null) { json_object_put(nextParsed); return localError(error, mcp_status.MCP_NO_MEMORY, "allocate tool catalog page"); }
        page.response = response; response = mcp_response.init;
        *tail = page; tail = &page.next;
        json_object_put(parsed); parsed = nextParsed;
        cursor = nextCursor;
        if (cursor is null) return mcp_status.MCP_OK;
    }
    return localError(error, mcp_status.MCP_MESSAGE_TOO_LARGE, "tools/list exceeded 128 pages");
}

// Every prompts/list page, kept as it came. A server that offers no prompts
// has none, and that is not a failure.
private mcp_status discoverPrompts(ref McpServer server, ref mcp_response response, ref mcp_error error) {
    const(char)* cursor;
    json_object* parsed;
    scope(exit) json_object_put(parsed);
    McpPage** tail = &server.prompts;
    foreach (_; 0 .. 128) {
        auto status = mcp_prompts_list(server.client, cursor, &response, &error);
        if (status == mcp_status.MCP_UNSUPPORTED) return mcp_status.MCP_OK;
        if (status != mcp_status.MCP_OK) return status;
        auto nextParsed = parseJson(response.json[0 .. response.length]);
        auto result = jsonField(nextParsed, "result");
        if (json_object_get_type(jsonField(result, "prompts")) != json_type.array) {
            json_object_put(nextParsed);
            return localError(error, mcp_status.MCP_PROTOCOL_ERROR, "prompts/list result has no prompts array");
        }
        auto next = jsonField(result, "nextCursor");
        auto nextCursor = next is null ? null : stringAt(next);
        if (next !is null && nextCursor is null) {
            json_object_put(nextParsed);
            return localError(error, mcp_status.MCP_PROTOCOL_ERROR, "prompts/list nextCursor is not a string");
        }
        if (cursor !is null && nextCursor !is null && strcmp(cursor, nextCursor) == 0) {
            json_object_put(nextParsed);
            return localError(error, mcp_status.MCP_PROTOCOL_ERROR, "prompts/list repeated its cursor");
        }
        auto page = cast(McpPage*) calloc(1, McpPage.sizeof);
        if (page is null) { json_object_put(nextParsed); return localError(error, mcp_status.MCP_NO_MEMORY, "allocate prompt catalog page"); }
        page.response = response; response = mcp_response.init;
        *tail = page; tail = &page.next;
        json_object_put(parsed); parsed = nextParsed;
        cursor = nextCursor;
        if (cursor is null) return mcp_status.MCP_OK;
    }
    return localError(error, mcp_status.MCP_MESSAGE_TOO_LARGE, "prompts/list exceeded 128 pages");
}

// A prompt of one of the session's servers, as prompts/get gives it, with
// arguments, a JSON object.
mcp_status getMcpPrompt(ref McpGroup group, const(char)* serverName, const(char)* promptName,
                        const(char)* arguments, ref mcp_response response, ref mcp_error error) {
    foreach (i; 0 .. group.count) {
        auto server = &group.servers[i];
        if (strcmp(server.name, serverName) == 0)
            return mcp_prompts_get(server.client, promptName, arguments, &response, &error);
    }
    return localError(error, mcp_status.MCP_INVALID_ARGUMENT, "session has no MCP server with that name");
}

// Validate the entire configuration before launching any process. A failure
// after launching rolls every connection back before session/new answers.
// capabilities, when given, is what the servers are told they may ask, as
// MCP's client capabilities: what the call under way's asker answers.
bool openMcp(const(char)[] line, const(char)[] cwd, ref McpGroup group, ref Reply detail,
             const(char)* capabilities = null) {
    auto root = parseJson(line);
    scope(exit) json_object_put(root);
    auto configs = jsonField(jsonField(root, "params"), "mcpServers");
    mcp_error error;
    mcp_response response, validation;
    const(char)* failedName;
    auto count = json_object_get_type(configs) == json_type.array ? json_object_array_length(configs) : 0;
    bool valid = json_object_get_type(configs) == json_type.array && count <= 32;
    const(char)* why = "MCP needs unique named servers, stdio with command, args and env or http with url and headers (limits: 32 servers, 128 args/env entries); SSE is unsupported";
    foreach (i; 0 .. (valid ? count : 0)) {
        auto config = json_object_array_get_idx(configs, i);
        auto name = stringAt(jsonField(config, "name")), command = stringAt(jsonField(config, "command"));
        foreach (j; 0 .. i) if (name !is null && strcmp(name, stringAt(jsonField(json_object_array_get_idx(configs, j), "name"))) == 0) valid = false;
        if (!valid) break;
        if (jsonField(config, "type") !is null) {
            if (!httpValid(config, name, why)) { valid = false; break; }
            continue;
        }
        auto args = jsonField(config, "args"), env = jsonField(config, "env");
        if (name is null || !*name || command is null || !*command || jsonField(config, "type") !is null ||
            json_object_get_type(args) != json_type.array || json_object_get_type(env) != json_type.array ||
            json_object_array_length(args) > 128 || json_object_array_length(env) > 128) { valid = false; break; }
        foreach (j; 0 .. json_object_array_length(args)) if (stringAt(json_object_array_get_idx(args, j)) is null) valid = false;
        foreach (j; 0 .. json_object_array_length(env)) {
            auto entry = json_object_array_get_idx(env, j);
            auto key = stringAt(jsonField(entry, "name")), value = stringAt(jsonField(entry, "value"));
            if (key is null || !*key || value is null) { valid = false; break; }
            foreach (k; 0 .. strlen(key)) if (key[k] == '=') valid = false;
            foreach (k; 0 .. j) {
                auto previous = stringAt(jsonField(json_object_array_get_idx(env, k), "name"));
                if (previous !is null && strcmp(key, previous) == 0) valid = false;
            }
        }
        if (!valid) break;
    }
    if (!valid) {
        localError(error, mcp_status.MCP_INVALID_ARGUMENT, why);
    } else if (count == 0) return true;
    else {
        group.servers = cast(McpServer*) calloc(count, McpServer.sizeof);
        auto dir = cast(char*) malloc(cwd.length + 1);
        scope(exit) free(dir);
        if (group.servers is null || dir is null) {
            localError(error, mcp_status.MCP_NO_MEMORY, "allocate session MCP servers");
        } else {
            memcpy(dir, cwd.ptr, cwd.length); dir[cwd.length] = 0;
            group.count = count;
            foreach (i; 0 .. count) {
                auto config = json_object_array_get_idx(configs, i);
                auto server = &group.servers[i];
                server.name = copy(stringAt(jsonField(config, "name"))); failedName = server.name;
                if (server.name is null) { localError(error, mcp_status.MCP_NO_MEMORY, "copy MCP server name"); break; }
                auto status = jsonField(config, "type") !is null
                    ? startHttp(config, capabilities, *server, response, error)
                    : startServer(config, dir, capabilities, *server, response, error);
                if (status == mcp_status.MCP_OK) {
                    mcp_response_free(&response);
                    status = discoverTools(*server, response, validation, error);
                }
                if (status == mcp_status.MCP_OK) {
                    mcp_response_free(&response);
                    status = discoverPrompts(*server, response, error);
                }
                if (status != mcp_status.MCP_OK) break;
                if (i + 1 == count) return true;
            }
        }
    }
    detail.add(`{"failure":`); failure(detail, failedName, error, response, &validation);
    mcp_response_free(&validation);
    detail.add(`,"cleanup":`);
    closeMcp(group, detail);
    detail.add("}");
    mcp_response_free(&response);
    return false;
}

// This is the harness dispatch boundary. Names stay a (server, tool) pair,
// so two servers exposing "search" never overwrite or masquerade as each other.
// stop, when given, is asked between polls while the call runs, and a yes
// cancels it at the server: MCP_CANCELLED, and no response. ask, when given,
// answers what the server asks of ground code while the call runs. hear, when
// given, hears what the server logs at warning or above while the call runs.
mcp_status callMcpTool(ref McpGroup group, const(char)* serverName, const(char)* toolName,
                       const(char)* arguments, ref mcp_response response, ref mcp_response validation, ref mcp_error error,
                       scope bool delegate() stop = null, scope Ask ask = null, scope Hear hear = null) {
    if (serverName is null || toolName is null) return localError(error, mcp_status.MCP_INVALID_ARGUMENT, "tool dispatch needs server and tool names");
    foreach (i; 0 .. group.count) {
        auto server = &group.servers[i];
        if (strcmp(server.name, serverName) == 0) {
            for (auto contract = server.contracts; contract !is null; contract = contract.next)
                if (strcmp(mcp_tool_name(contract.tool), toolName) == 0)
                    return stop is null
                        ? mcp_tool_call(server.client, contract.tool, arguments, &response, &validation, &error)
                        : stoppableCall(*server, contract.tool, arguments, response, validation, error, stop, ask, hear);
            return localError(error, mcp_status.MCP_INVALID_ARGUMENT, "tool is not in the session server catalog");
        }
    }
    return localError(error, mcp_status.MCP_INVALID_ARGUMENT, "session has no MCP server with that name");
}

// How long a poll waits before stop is asked again.
enum POLL_MS = 100;

// mcp_tool_call, as libmcp writes it: submit, poll until the request is done,
// take, and the validation report moved out. Between polls, stop is asked;
// a yes cancels the request, which libmcp says to the server as
// notifications/cancelled with this reason. What the server asks while it
// runs is ask's to answer: a legacy server's own request, through libmcp's
// handler, and a 2026-07-28 server's input_required, each input asked and the
// call continued with the answers.
private mcp_status stoppableCall(ref McpServer server, const(mcp_tool)* tool, const(char)* arguments,
                                 ref mcp_response response, ref mcp_response validation, ref mcp_error error,
                                 scope bool delegate() stop, scope Ask ask, scope Hear hear) {
    mcp_request* request;
    auto was = asking;
    asking = ask;
    scope(exit) asking = was;
    auto wasHearing = hearing;
    hearing = hear;
    scope(exit) hearing = wasHearing;
    auto status = mcp_tool_submit(server.client, tool, arguments, server.timeoutMs, &request, &error);
    if (status != mcp_status.MCP_OK) return status;
    scope(exit) mcp_request_destroy(request, null);
    while (true) {
        while (mcp_request_status(request) == mcp_status.MCP_PENDING) {
            if (stop()) {
                status = mcp_request_cancel(request, "the client cancelled the turn", &error);
                if (status != mcp_status.MCP_OK) return status;
                return localError(error, mcp_status.MCP_CANCELLED, "the client cancelled the turn");
            }
            status = mcp_client_poll(server.client, POLL_MS, &error);
            // A poll that failed leaves the request pending: it is the call's failure.
            if (status != mcp_status.MCP_OK && mcp_request_status(request) == mcp_status.MCP_PENDING) {
                mcp_error ignored;
                mcp_request_cancel(request, "ground's poll of the server failed", &ignored);
                return status;
            }
        }
        if (mcp_request_status(request) != mcp_status.MCP_INPUT_REQUIRED || ask is null) break;
        status = continued(request, response, error, stop, ask);
        if (status != mcp_status.MCP_OK) return status;
    }
    status = mcp_request_take(request, &response, &error);
    auto report = mcp_request_validation_json(request);
    if (report !is null) {
        mcp_error copied;
        if (mcp_response_set(&validation, report, &copied) != mcp_status.MCP_OK && status == mcp_status.MCP_OK) {
            error = copied;
            return copied.code;
        }
    }
    return status;
}

// "input_required": each of the result's inputRequests asked, by its method
// and params, and the request continued with the answers by their keys. An
// input refused or not asked ends the call: the asker's error, or why it
// could not ask, is the response; the turn called off is MCP_CANCELLED.
private mcp_status continued(mcp_request* request, ref mcp_response response, ref mcp_error error,
                             scope bool delegate() stop, scope Ask ask) {
    mcp_response asked;
    scope(exit) mcp_response_free(&asked);
    mcp_request_take(request, &asked, &error);
    auto message = parseJson(asked.json[0 .. asked.length]);
    scope(exit) json_object_put(message);
    auto inputs = jsonField(jsonField(message, "result"), "inputRequests");
    Reply answers;
    scope(exit) answers.dispose();
    answers.add("{");
    if (json_object_get_type(inputs) == json_type.object) {
        bool first = true;
        auto end = json_object_iter_end(inputs);
        for (auto it = json_object_iter_begin(inputs); !json_object_iter_equal(&it, &end); json_object_iter_next(&it)) {
            auto key = json_object_iter_peek_name(&it);
            auto input = json_object_iter_peek_value(&it);
            auto method = stringAt(jsonField(input, "method"));
            auto params = jsonField(input, "params");
            auto text = params is null ? "{}" : json_object_to_json_string_ext(params, JSON_C_TO_STRING_PLAIN | JSON_C_TO_STRING_NOSLASHESCAPE);
            Reply answer;
            scope(exit) answer.dispose();
            auto got = ask(method[0 .. strlen(method)], text[0 .. strlen(text)], answer);
            if (got == 2) return localError(error, mcp_status.MCP_CANCELLED, "the client cancelled the turn");
            if (got != 1) {
                answer.add("\0");
                mcp_response_set(&response, answer.slice().ptr, null);
                return localError(error, mcp_status.MCP_REMOTE_ERROR, got == 0
                    ? "the client refused what the server asked"
                    : "ground code could not ask the client what the server asked");
            }
            if (!first) answers.add(",");
            first = false;
            answers.add(`"`); putEscaped(answers, key[0 .. strlen(key)]); answers.add(`":`);
            answers.add(answer.slice());
        }
    }
    answers.add("}\0");
    if (answers.full) return localError(error, mcp_status.MCP_NO_MEMORY, "the answers to the server outgrew memory");
    if (stop()) return localError(error, mcp_status.MCP_CANCELLED, "the client cancelled the turn");
    return mcp_request_resume(request, answers.slice().ptr, &error);
}
