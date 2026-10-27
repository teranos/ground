module code.prompt;

// One turn of a session: the prompt goes to the node's gateway as chat
// completions with the session's tools, a tool_calls answer is run through
// the session's own MCP servers and handed back, until the model stops.

import matcher : indexOf;
import parse : Reads;
import code.reply : Reply, putEscaped, putNumber;

// The path on the node that the openrouter-qntx plugin answers at.
enum GATEWAY_PATH = "/api/openrouter-qntx/v1/chat/completions";
// The gateway's models list, where a model's context_length is.
enum MODELS_PATH = "/api/openrouter-qntx/v1/models";

// A tool is named to the model as its server and itself, so two servers'
// "search" stay two tools; the name comes apart at the same mark.
enum TOOL_MARK = "__";

void putToolName(ref Reply r, const(char)[] server, const(char)[] tool) {
    r.add(server); r.add(TOOL_MARK); r.add(tool);
}

const(char)[] serverOf(const(char)[] name) {
    auto at = indexOf(name, TOOL_MARK);
    return at < 0 ? null : name[0 .. cast(size_t) at];
}

const(char)[] toolOf(const(char)[] name) {
    auto at = indexOf(name, TOOL_MARK);
    return at < 0 ? name : name[cast(size_t) at + TOOL_MARK.length .. $];
}

// --- the prompt's text, read from the ACP line ---

private void putUtf8(ref Reply r, uint cp) {
    char[4] b;
    size_t n;
    if (cp < 0x80) { b[0] = cast(char) cp; n = 1; }
    else if (cp < 0x800) { b[0] = cast(char)(0xC0 | (cp >> 6)); b[1] = cast(char)(0x80 | (cp & 0x3F)); n = 2; }
    else if (cp < 0x10000) {
        b[0] = cast(char)(0xE0 | (cp >> 12)); b[1] = cast(char)(0x80 | ((cp >> 6) & 0x3F));
        b[2] = cast(char)(0x80 | (cp & 0x3F)); n = 3;
    } else {
        b[0] = cast(char)(0xF0 | (cp >> 18)); b[1] = cast(char)(0x80 | ((cp >> 12) & 0x3F));
        b[2] = cast(char)(0x80 | ((cp >> 6) & 0x3F)); b[3] = cast(char)(0x80 | (cp & 0x3F)); n = 4;
    }
    r.add(b[0 .. n]);
}

private uint hex4(const(char)[] s) {
    uint v;
    foreach (c; s) {
        v <<= 4;
        if (c >= '0' && c <= '9') v |= c - '0';
        else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
    }
    return v;
}

// The string that opens at pos (its quote), unescaped into r. Returns the
// position after its closing quote, or json.length when it never closes.
private size_t copyString(const(char)[] json, size_t pos, ref Reply r) {
    pos++;
    while (pos < json.length) {
        auto c = json[pos];
        if (c == '"') return pos + 1;
        if (c != '\\' || pos + 1 >= json.length) { r.add(json[pos .. pos + 1]); pos++; continue; }
        pos++;
        switch (json[pos]) {
            case 'n': r.add("\n"); break;
            case 't': r.add("\t"); break;
            case 'r': r.add("\r"); break;
            case 'b': r.add("\b"); break;
            case 'f': r.add("\f"); break;
            case 'u':
                if (pos + 4 < json.length) {
                    uint cp = hex4(json[pos + 1 .. pos + 5]);
                    pos += 4;
                    if (cp >= 0xD800 && cp < 0xDC00 && pos + 6 < json.length && json[pos + 1] == '\\' && json[pos + 2] == 'u') {
                        uint lo = hex4(json[pos + 3 .. pos + 7]);
                        if (lo >= 0xDC00 && lo < 0xE000) { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00); pos += 6; }
                    }
                    putUtf8(r, cp);
                }
                break;
            default: r.add(json[pos .. pos + 1]); break;
        }
        pos++;
    }
    return pos;
}

// The position after the value that starts at pos, strings and nesting honoured.
size_t skipValue(const(char)[] json, size_t pos) {
    if (pos >= json.length) return pos;
    if (json[pos] == '"') { Reply none; return copyString(json, pos, none); }
    if (json[pos] != '{' && json[pos] != '[') {
        while (pos < json.length && json[pos] != ',' && json[pos] != '}' && json[pos] != ']') pos++;
        return pos;
    }
    int depth;
    while (pos < json.length) {
        auto c = json[pos];
        if (c == '"') { Reply none; pos = copyString(json, pos, none); continue; }
        if (c == '{' || c == '[') depth++;
        else if (c == '}' || c == ']') { depth--; if (depth == 0) return pos + 1; }
        pos++;
    }
    return pos;
}

// What a prompt's blocks are: all read, one of another kind, or no prompt libacp reads.
enum Blocks { read, other, refused }

// The prompt's text blocks, in order, one line each, as libacp reads params. A
// resource_link goes into links to be read, its name and its uri each ended by
// a NUL. A resource embedded with its text, "for pieces of context that are
// referenced in the message", goes into embedded, its uri and its text each
// ended by a NUL. A block of another kind has no text to give the model, and
// is not pretended to: other gets the type of the first such block, empty when
// it names none; a resource holding a blob is "resource holding a blob".
// refused: libacp's refusal of the prompt itself is in said.
@Reads("prompt") Blocks promptText(const(char)[] params, ref Reply r, ref Reply other, ref Reply links, ref Reply embedded,
        ref Reply said) {
    import libacp : acp_prompt, acp_prompt_read, acp_prompt_free, acp_block_kind, acp_buffer, acp_buffer_free, acp_status;
    import core.stdc.string : strlen;
    acp_prompt prompt;
    scope(exit) acp_prompt_free(&prompt);
    acp_buffer refusal;
    scope(exit) acp_buffer_free(&refusal);
    if (acp_prompt_read(params.ptr, params.length, &prompt, &refusal) != acp_status.ACP_OK) {
        if (refusal.data !is null) said.add(refusal.data[0 .. refusal.length]);
        else said.add(`{"code":-32603,"message":"libacp could not read session/prompt's prompt"}`);
        return Blocks.refused;
    }
    static const(char)[] of(const(char)* s) { return s is null ? "" : s[0 .. strlen(s)]; }
    bool first = true, all = true;
    foreach (ref b; prompt.blocks[0 .. prompt.count]) {
        final switch (b.kind) {
            case acp_block_kind.ACP_BLOCK_TEXT:
                if (!first) r.add("\n");
                first = false;
                r.add(of(b.text));
                break;
            case acp_block_kind.ACP_BLOCK_RESOURCE_LINK:
                links.add(of(b.name)); links.add("\0"); links.add(of(b.uri)); links.add("\0");
                break;
            case acp_block_kind.ACP_BLOCK_RESOURCE:
                embedded.add(of(b.uri)); embedded.add("\0"); embedded.add(of(b.text)); embedded.add("\0");
                break;
            case acp_block_kind.ACP_BLOCK_OTHER:
                if (all) other.add(b.holds_blob ? "resource holding a blob" : of(b.type));
                all = false;
                break;
        }
    }
    return all ? Blocks.read : Blocks.other;
}

// "Absolute path to the file to read": a file:// uri on this machine, its
// authority empty or localhost, percent-decoded into path. false for any
// other uri, a path that is not absolute, or an escape that is no byte or is
// NUL.
bool fileUriPath(const(char)[] uri, ref Reply path) {
    enum scheme = "file://";
    if (uri.length < scheme.length || uri[0 .. scheme.length] != scheme) return false;
    auto rest = uri[scheme.length .. $];
    size_t slash = 0;
    while (slash < rest.length && rest[slash] != '/') slash++;
    auto authority = rest[0 .. slash];
    if (authority.length > 0 && authority != "localhost") return false;
    rest = rest[slash .. $];
    if (rest.length == 0) return false;
    static int hex(char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }
    for (size_t i = 0; i < rest.length; i++) {
        if (rest[i] != '%') { char[1] c = [rest[i]]; path.add(c[]); continue; }
        if (i + 2 >= rest.length) return false;
        auto hi = hex(rest[i + 1]), lo = hex(rest[i + 2]);
        if (hi < 0 || lo < 0 || (hi == 0 && lo == 0)) return false;
        char[1] c = [cast(char)(hi * 16 + lo)];
        path.add(c[]);
        i += 2;
    }
    return true;
}

// --- elicitation: what a session's MCP server asks the user ---

// --- cost ---

// An amount in billionths of a dollar as Cost's amount, a decimal: as few
// fractional digits as it needs, and none for a whole one.
void putAmount(ref Reply r, long nano) {
    putNumber(r, cast(ulong) (nano / 1_000_000_000));
    long fraction = nano % 1_000_000_000;
    if (fraction == 0) return;
    char[9] digits;
    foreach_reverse (i; 0 .. 9) { digits[i] = cast(char)('0' + fraction % 10); fraction /= 10; }
    size_t end = 9;
    while (end > 0 && digits[end - 1] == '0') end--;
    r.add("."); r.add(digits[0 .. end]);
}

// --- the model's context window ---

// A model's context_length, "Maximum context length in tokens", from the
// gateway's models list, by its id. false when the list is not one, or names
// no such model, or gives it no length.
bool contextLengthOf(const(char)[] models, const(char)[] model, ref ulong size) {
    auto root = parseJson(models);
    scope(exit) json_object_put(root);
    auto data = jsonField(root, "data");
    if (json_object_get_type(data) != json_type.array) return false;
    foreach (i; 0 .. json_object_array_length(data)) {
        auto entry = json_object_array_get_idx(data, i);
        if (text(jsonField(entry, "id")) != model) continue;
        auto length = jsonField(entry, "context_length");
        if (json_object_get_type(length) != json_type.int_ || json_object_get_int64(length) <= 0) return false;
        size = cast(ulong) json_object_get_int64(length);
        return true;
    }
    return false;
}

// --- a session's title ---

// How long a title runs before it is cut, in bytes, not counting the ellipsis.
enum TITLE_BYTES = 80;

// A session's title from what the user typed: "May be auto-generated from the
// first prompt." The first line with words in it, its runs of spaces made one;
// longer than TITLE_BYTES, it is cut after the last word that ends within them,
// or where a character ends when one word is longer, and an ellipsis says so.
// Nothing typed adds nothing.
void titleOf(const(char)[] typed, ref Reply title) {
    size_t p = 0;
    while (p < typed.length && (typed[p] == ' ' || typed[p] == '\t' || typed[p] == '\r' || typed[p] == '\n')) p++;
    // One byte past TITLE_BYTES is enough to know the line runs past them.
    char[TITLE_BYTES + 1] line;
    size_t n = 0;
    bool space = false;
    for (; p < typed.length && typed[p] != '\n' && n < line.length; p++) {
        auto c = typed[p];
        if (c == ' ' || c == '\t' || c == '\r') { space = true; continue; }
        if (space) { line[n++] = ' '; space = false; if (n == line.length) break; }
        line[n++] = c;
    }
    if (n <= TITLE_BYTES) { title.add(line[0 .. n]); return; }
    size_t cut = TITLE_BYTES;
    if (line[cut] != ' ') {
        while (cut > 0 && line[cut] != ' ') cut--;
        if (cut == 0) {
            cut = TITLE_BYTES;
            while (cut > 0 && (line[cut] & 0xC0) == 0x80) cut--;
        }
    }
    title.add(line[0 .. cut]);
    title.add("…");
}

// --- commands: a session's MCP prompts ---

// What a prompt takes, read from its prompts/list entry: how many arguments,
// and the first one's name, hint and whether it is required.
private struct Arguments { size_t count; const(char)[] name, hint; bool required; }
private Arguments argumentsOf(json_object* prompt) {
    Arguments a;
    auto list = jsonField(prompt, "arguments");
    if (json_object_get_type(list) != json_type.array) return a;
    a.count = json_object_array_length(list);
    if (a.count == 0) return a;
    auto first = json_object_array_get_idx(list, 0);
    a.name = text(jsonField(first, "name"));
    a.hint = text(jsonField(first, "description"));
    if (a.hint.length == 0) a.hint = a.name;
    auto required = jsonField(first, "required");
    a.required = json_object_get_type(required) == json_type.boolean && json_object_get_boolean(required) != 0;
    return a;
}

// Each prompt of each server, in the order the servers gave them, until each
// says yes. A page that does not read gives none.
private void eachPrompt(ref McpGroup group,
        scope bool delegate(const(char)[] server, const(char)[] name, json_object* prompt) each) {
    foreach (i; 0 .. group.count) {
        auto server = &group.servers[i];
        auto serverName = server.name[0 .. strlen(server.name)];
        for (auto page = server.prompts; page !is null; page = page.next) {
            auto root = parseJson(page.response.json[0 .. page.response.length]);
            scope(exit) json_object_put(root);
            auto list = jsonField(jsonField(root, "result"), "prompts");
            foreach (j; 0 .. json_object_get_type(list) == json_type.array ? json_object_array_length(list) : 0) {
                auto prompt = json_object_array_get_idx(list, j);
                auto name = text(jsonField(prompt, "name"));
                if (name.length > 0 && each(serverName, name, prompt)) return;
            }
        }
    }
}

// The session's commands, as available_commands_update lists them: each MCP
// prompt that takes at most one argument, named as a tool is, server__prompt.
// "All text that was typed after the command name is provided as input", one
// text, so a prompt taking two arguments has no way to be given them.
void commandsOf(ref McpGroup group, ref Reply commands) {
    commands.add("[");
    bool first = true;
    bool each(const(char)[] server, const(char)[] name, json_object* prompt) {
        auto args = argumentsOf(prompt);
        if (args.count > 1) return false;
        if (!first) commands.add(",");
        first = false;
        commands.add(`{"name":"`);
        Reply full;
        putToolName(full, server, name);
        putEscaped(commands, full.slice());
        full.dispose();
        auto description = text(jsonField(prompt, "description"));
        if (description.length == 0) description = text(jsonField(prompt, "title"));
        if (description.length == 0) description = name;
        commands.add(`","description":"`); putEscaped(commands, description); commands.add(`"`);
        if (args.count == 1) { commands.add(`,"input":{"hint":"`); putEscaped(commands, args.hint); commands.add(`"}`); }
        commands.add("}");
        return false;
    }
    eachPrompt(group, &each);
    commands.add("]");
}

// The command a turn's typed text starts with: "/server__prompt", then the
// end or a space and its input. found, its server, prompt and argument, and
// the input with the spaces around it trimmed.
struct Command {
    Reply full, server, prompt, argument, hint;
    bool required;
    void dispose() { full.dispose(); server.dispose(); prompt.dispose(); argument.dispose(); hint.dispose(); }
}
bool commandOf(ref McpGroup group, const(char)[] typed, ref Command c, ref const(char)[] input) {
    if (typed.length < 2 || typed[0] != '/') return false;
    size_t end = 1;
    while (end < typed.length && typed[end] != ' ' && typed[end] != '\t' && typed[end] != '\n' && typed[end] != '\r') end++;
    auto asked = typed[1 .. end];
    bool found = false;
    bool each(const(char)[] server, const(char)[] name, json_object* prompt) {
        Reply full;
        scope(exit) full.dispose();
        putToolName(full, server, name);
        if (full.slice() != asked) return false;
        auto args = argumentsOf(prompt);
        if (args.count > 1) return false;
        c.full.add(asked); c.server.add(server); c.prompt.add(name);
        c.argument.add(args.name); c.hint.add(args.hint); c.required = args.required;
        found = true;
        return true;
    }
    eachPrompt(group, &each);
    if (!found) return false;
    size_t from = end, to = typed.length;
    while (from < to && (typed[from] == ' ' || typed[from] == '\t' || typed[from] == '\n' || typed[from] == '\r')) from++;
    while (to > from && (typed[to - 1] == ' ' || typed[to - 1] == '\t' || typed[to - 1] == '\n' || typed[to - 1] == '\r')) to--;
    input = typed[from .. to];
    return true;
}

// What prompts/get gave, as the history keeps the conversation: each message
// by its role, its text the text of a text block or of an embedded text
// resource. 1 added; -1 a message the model cannot be asked, its content's
// type in why; -2 not a prompt.
int promptMessages(const(char)[] response, ref Reply history, ref Reply why) {
    auto root = parseJson(response);
    scope(exit) json_object_put(root);
    auto messages = jsonField(jsonField(root, "result"), "messages");
    if (json_object_get_type(messages) != json_type.array) return -2;
    // Read whole before any is kept, so a prompt the model cannot be asked adds nothing.
    foreach (i; 0 .. json_object_array_length(messages)) {
        auto content = jsonField(json_object_array_get_idx(messages, i), "content");
        auto type = text(jsonField(content, "type"));
        bool readable = type == "text" ? text(jsonField(content, "text")) !is null
            : type == "resource" && text(jsonField(jsonField(content, "resource"), "text")) !is null;
        if (!readable) { why.add(type.length > 0 ? type : "a message with no content type"); return -1; }
    }
    foreach (i; 0 .. json_object_array_length(messages)) {
        auto message = json_object_array_get_idx(messages, i);
        auto content = jsonField(message, "content");
        auto said = text(jsonField(content, "type")) == "text" ? text(jsonField(content, "text"))
            : text(jsonField(jsonField(content, "resource"), "text"));
        if (text(jsonField(message, "role")) == "assistant") {
            comma(history);
            history.add(`{"role":"assistant","content":"`); putEscaped(history, said); history.add(`"}`);
        } else userMessage(history, said);
    }
    return 1;
}

// --- the history: the messages array's inside, grown a message at a time ---

private void comma(ref Reply h) { if (h.len > 0) h.add(","); }

void userMessage(ref Reply h, const(char)[] text) {
    comma(h);
    h.add(`{"role":"user","content":"`); putEscaped(h, text); h.add(`"}`);
}

// The model's own message, as the gateway gave it, so its tool_calls come
// back to it exactly as it made them.
void assistantMessage(ref Reply h, const(char)[] json) {
    comma(h);
    h.add(json);
}

void toolMessage(ref Reply h, const(char)[] callId, const(char)[] content) {
    comma(h);
    h.add(`{"role":"tool","tool_call_id":"`); putEscaped(h, callId);
    h.add(`","content":"`); putEscaped(h, content); h.add(`"}`);
}

// The body the gateway gets: the model, the messages, the tools when there
// are any, and the session's effort, which the plugin hands OpenRouter as is.
void requestBody(ref Reply b, const(char)[] model, const(char)[] history, const(char)[] tools, const(char)[] effort) {
    b.add(`{"model":"`); putEscaped(b, model);
    b.add(`","messages":[`); b.add(history); b.add(`]`);
    if (tools.length > 0) { b.add(`,"tools":[`); b.add(tools); b.add(`]`); }
    b.add(`,"reasoning":{"effort":"`); putEscaped(b, effort); b.add(`"}`);
    b.add(`}`);
}

// --- runtime: the tools the session has, and what the model answered ---

import libjsonc;
import code.mcp : McpGroup;
import core.stdc.string : strlen;
import core.stdc.stdlib : calloc, free;

private const(char)[] text(json_object* value) {
    if (value is null || json_object_get_type(value) != json_type.string_) return null;
    auto s = json_object_get_string(value);
    return s is null ? null : s[0 .. cast(size_t) json_object_get_string_len(value)];
}

private const(char)[] raw(json_object* value) {
    auto s = json_object_to_json_string_ext(value, JSON_C_TO_STRING_PLAIN);
    return s is null ? null : s[0 .. strlen(s)];
}

// Every tool of every server, as chat completions' functions. A page whose
// JSON does not read is named, not skipped.
bool toolsOf(ref McpGroup group, ref Reply tools, ref Reply detail) {
    bool first = true;
    foreach (i; 0 .. group.count) {
        auto server = &group.servers[i];
        auto name = server.name[0 .. strlen(server.name)];
        for (auto page = server.tools; page !is null; page = page.next) {
            auto root = parseJson(page.response.json[0 .. page.response.length]);
            scope(exit) json_object_put(root);
            auto list = jsonField(jsonField(root, "result"), "tools");
            if (json_object_get_type(list) != json_type.array) {
                detail.add(`{"server":"`); putEscaped(detail, name); detail.add(`","message":"a tools/list page has no tools array"}`);
                return false;
            }
            foreach (j; 0 .. json_object_array_length(list)) {
                auto tool = json_object_array_get_idx(list, j);
                auto toolName = text(jsonField(tool, "name"));
                if (toolName is null) {
                    detail.add(`{"server":"`); putEscaped(detail, name); detail.add(`","message":"a tool has no name"}`);
                    return false;
                }
                if (!first) tools.add(",");
                first = false;
                tools.add(`{"type":"function","function":{"name":"`);
                Reply full; putToolName(full, name, toolName); putEscaped(tools, full.slice()); full.dispose();
                tools.add(`"`);
                auto description = jsonField(tool, "description");
                if (description !is null) { tools.add(`,"description":`); tools.add(raw(description)); }
                auto schema = jsonField(tool, "inputSchema");
                if (schema !is null) { tools.add(`,"parameters":`); tools.add(raw(schema)); }
                tools.add(`}}`);
            }
        }
    }
    return true;
}

// Whether the session's catalog says the tool, by its full name, only reads:
// its MCP annotations' readOnlyHint is true. A tool that says nothing does not.
bool readOnlyTool(ref McpGroup group, const(char)[] full) {
    foreach (i; 0 .. group.count) {
        auto server = &group.servers[i];
        auto name = server.name[0 .. strlen(server.name)];
        for (auto page = server.tools; page !is null; page = page.next) {
            auto root = parseJson(page.response.json[0 .. page.response.length]);
            scope(exit) json_object_put(root);
            auto list = jsonField(jsonField(root, "result"), "tools");
            if (json_object_get_type(list) != json_type.array) continue;
            foreach (j; 0 .. json_object_array_length(list)) {
                auto tool = json_object_array_get_idx(list, j);
                auto toolName = text(jsonField(tool, "name"));
                if (toolName is null) continue;
                Reply n;
                putToolName(n, name, toolName);
                bool same = n.slice() == full;
                n.dispose();
                if (!same) continue;
                auto hint = jsonField(jsonField(tool, "annotations"), "readOnlyHint");
                return json_object_get_type(hint) == json_type.boolean && json_object_get_boolean(hint) != 0;
            }
        }
    }
    return false;
}

// A conversation told back to the client, a session/update a step, as the
// turns that made it told them live: what the user said, what the model said,
// each call it asked for, and how each one came out. A call came out completed
// when its answer is an MCP response's result, and failed otherwise, as live.
// false when the history is not one ground code wrote, or send failed.
// --- what a tool call shows the user ---

// What a call shows, from what it answered as the history keeps it, MCP's content blocks as they came:
// "enabling agents to seamlessly forward content from MCP tool outputs without transformation"
// Or what failed it, as text. Blocks go into blocks as their array, the text into said.
void toolContentOf(const(char)[] output, ref Reply blocks, ref Reply said) {
    auto root = parseJson(output);
    scope(exit) json_object_put(root);
    json_object* inner;
    scope(exit) json_object_put(inner);
    json_object* found;
    const(char)[] text_;
    if (root is null) text_ = output;
    else if (jsonField(root, "result") !is null) found = jsonField(jsonField(root, "result"), "content");
    else if (jsonField(root, "error") !is null) text_ = text(jsonField(jsonField(root, "error"), "message"));
    else {
        // ground code's own: the response it failed on, when there was one.
        auto response = text(jsonField(root, "response"));
        if (response.length > 0) inner = parseJson(response);
        if (jsonField(inner, "result") !is null) found = jsonField(jsonField(inner, "result"), "content");
        else if (jsonField(inner, "error") !is null) text_ = text(jsonField(jsonField(inner, "error"), "message"));
        if (found is null && text_.length == 0) {
            text_ = text(jsonField(root, "why"));
            if (text_.length == 0) text_ = text(jsonField(root, "message"));
        }
    }
    if (json_object_get_type(found) == json_type.array && json_object_array_length(found) > 0) {
        auto array = json_object_to_json_string_ext(found, JSON_C_TO_STRING_PLAIN | JSON_C_TO_STRING_NOSLASHESCAPE);
        blocks.add(array[0 .. strlen(array)]);
    } else said.add(text_);
}

// A tool_call, or a tool_call_update when update, as libacp writes it, into u. A field that is
// null is not written; rawOutput, when given, also gives what the call shows. false when libacp
// could not write it.
bool putToolCall(ref Reply u, bool update, const(char)[] id, const(char)[] title, const(char)[] name,
        const(char)[] kind, const(char)[] status, const(char)[] rawInput, const(char)[] rawOutput) {
    import libacp : acp_tool_call, acp_tool_call_write, acp_buffer, acp_buffer_free, acp_status;
    Reply blocks, said, text_;
    scope(exit) { blocks.dispose(); said.dispose(); text_.dispose(); }
    if (rawOutput !is null) toolContentOf(rawOutput, blocks, said);
    // Each field as C reads it, its own bytes and a NUL; size_t.max is one not given.
    size_t at(const(char)[] s) {
        if (s is null) return size_t.max;
        auto from = text_.len; text_.add(s); text_.add("\0"); return from;
    }
    auto idAt = at(id), titleAt = at(title), nameAt = at(name), kindAt = at(kind), statusAt = at(status);
    auto inputAt = at(rawInput), outputAt = at(rawOutput);
    auto blocksAt = at(blocks.len > 0 ? blocks.slice() : null), saidAt = at(said.len > 0 ? said.slice() : null);
    if (text_.full || blocks.full || said.full) return false;
    const(char)* c(size_t from) { return from == size_t.max ? null : text_.slice().ptr + from; }
    auto call = acp_tool_call(update, c(idAt), c(titleAt), c(nameAt), c(kindAt), c(statusAt), c(inputAt), c(outputAt),
        c(blocksAt), c(saidAt));
    acp_buffer written;
    scope(exit) acp_buffer_free(&written);
    if (acp_tool_call_write(&call, &written) != acp_status.ACP_OK) return false;
    u.add(written.data[0 .. written.length]);
    return !u.full;
}

// A text chunk, the agent's message, its thought or the user's, as libacp writes it, into u.
bool putChunk(ref Reply u, int kind, const(char)[] text_) {
    import libacp : acp_chunk_kind, acp_text_chunk_write, acp_buffer, acp_buffer_free, acp_status;
    acp_buffer written;
    scope(exit) acp_buffer_free(&written);
    if (acp_text_chunk_write(cast(acp_chunk_kind) kind, text_.ptr, text_.length, &written) != acp_status.ACP_OK) return false;
    u.add(written.data[0 .. written.length]);
    return !u.full;
}

// The history, told again. readOnly, when given, says which of the calls'
// tools are read-only, so their replayed calls say kind read as they did live.
bool replayHistory(const(char)[] history, scope bool delegate(const(char)[] update) send,
        scope bool delegate(const(char)[] tool) readOnly = null) {
    Reply all;
    scope(exit) all.dispose();
    all.add("["); all.add(history); all.add("]");
    if (all.full) return false;
    auto root = parseJson(all.slice());
    scope(exit) json_object_put(root);
    if (json_object_get_type(root) != json_type.array) return false;
    bool told(ref Reply u) { bool ok = !u.full && send(u.slice()); u.dispose(); return ok; }
    foreach (i; 0 .. json_object_array_length(root)) {
        auto m = json_object_array_get_idx(root, i);
        auto role = text(jsonField(m, "role"));
        auto content = text(jsonField(m, "content"));
        // The model's reasoning before its words, as the turn told it.
        auto reasoning = role == "assistant" ? text(jsonField(m, "reasoning")) : null;
        if (reasoning.length > 0) {
            Reply u;
            scope(exit) u.dispose();
            if (!putChunk(u, 1, reasoning) || !told(u)) return false;
        }
        if (role == "user" || (role == "assistant" && content.length > 0)) {
            Reply u;
            scope(exit) u.dispose();
            if (!putChunk(u, role == "user" ? 2 : 0, content) || !told(u)) return false;
        }
        if (role == "assistant") {
            auto calls = jsonField(m, "tool_calls");
            foreach (j; 0 .. json_object_get_type(calls) == json_type.array ? json_object_array_length(calls) : 0) {
                auto call = json_object_array_get_idx(calls, j);
                auto fn = jsonField(call, "function");
                auto id = text(jsonField(call, "id")), name = text(jsonField(fn, "name")), args = text(jsonField(fn, "arguments"));
                if (id is null || name is null || args is null) return false;
                Reply u;
                scope(exit) u.dispose();
                auto kind = readOnly !is null && readOnly(name) ? "read" : null;
                if (!putToolCall(u, false, id, name, name, kind, null, args, null) || !told(u)) return false;
            }
        }
        else if (role == "tool") {
            auto id = text(jsonField(m, "tool_call_id"));
            if (id is null || content is null) return false;
            auto answer = parseJson(content);
            scope(exit) json_object_put(answer);
            bool completed = jsonField(answer, "result") !is null;
            Reply u;
            scope(exit) u.dispose();
            if (!putToolCall(u, true, id, null, null, null, completed ? "completed" : "failed", null, content) || !told(u)) return false;
        }
        else if (role != "user" && role != "assistant") return false;
    }
    return true;
}

struct Call { const(char)[] id; const(char)[] name; const(char)[] arguments; }

// What the model answered: its text, or the calls it wants made. The slices
// point into the parsed JSON, which lives until dispose.
struct Completion {
    json_object* root;
    const(char)[] message;  // choices[0].message, as the gateway wrote it
    const(char)[] content;
    const(char)[] reasoning; // "Reasoning tokens will appear in the reasoning field of each message"
    const(char)[] finish;   // choices[0].finish_reason: why the model stopped, when the gateway says
    Call* calls;
    size_t callCount;
    bool hasUsage;  // the answer says what the conversation holds now
    ulong used;     // usage.total_tokens: "Tokens currently in context"
    bool hasCost;   // the answer says what it cost
    long costNano;  // usage.cost, "The total amount charged", in billionths of a dollar
    void dispose() {
        json_object_put(root); root = null;
        free(calls); calls = null; callCount = 0;
        message = null; content = null; reasoning = null; finish = null;
        hasUsage = false; used = 0; hasCost = false; costNano = 0;
    }
}

bool completionOf(const(char)[] json, ref Completion c) {
    c.root = parseJson(json);
    auto choices = jsonField(c.root, "choices");
    if (json_object_get_type(choices) != json_type.array || json_object_array_length(choices) == 0) return false;
    auto choice = json_object_array_get_idx(choices, 0);
    auto message = jsonField(choice, "message");
    if (json_object_get_type(message) != json_type.object) return false;
    c.finish = text(jsonField(choice, "finish_reason"));
    c.message = raw(message);
    c.content = text(jsonField(message, "content"));
    c.reasoning = text(jsonField(message, "reasoning"));
    // "Full usage details are now always included automatically in every
    // response": what was asked and answered, together what the context holds.
    auto total = jsonField(jsonField(c.root, "usage"), "total_tokens");
    if (json_object_get_type(total) == json_type.int_ && json_object_get_int64(total) >= 0) {
        c.hasUsage = true;
        c.used = cast(ulong) json_object_get_int64(total);
    }
    // "cost: The total amount charged to your account", in credits, which are
    // US dollars; kept in billionths so a session's sum stays exact. A node
    // that brings its own provider key ("is_byok") is charged by the provider
    // too, on that key: "cost_details.upstream_inference_cost: The actual cost
    // charged by the upstream AI provider". Without its own key the provider
    // is paid out of cost, and that is not added again.
    auto usage = jsonField(c.root, "usage");
    auto cost = jsonField(usage, "cost");
    auto kind = json_object_get_type(cost);
    if ((kind == json_type.double_ || kind == json_type.int_) && json_object_get_double(cost) >= 0) {
        import core.stdc.math : llround;
        double spent = json_object_get_double(cost);
        auto byok = jsonField(usage, "is_byok");
        if (json_object_get_type(byok) == json_type.boolean && json_object_get_boolean(byok) != 0) {
            auto upstream = jsonField(jsonField(usage, "cost_details"), "upstream_inference_cost");
            auto up = json_object_get_type(upstream);
            if ((up == json_type.double_ || up == json_type.int_) && json_object_get_double(upstream) >= 0)
                spent += json_object_get_double(upstream);
        }
        c.hasCost = true;
        c.costNano = llround(spent * 1e9);
    }
    auto calls = jsonField(message, "tool_calls");
    if (calls is null) return true;
    if (json_object_get_type(calls) != json_type.array) return false;
    c.callCount = json_object_array_length(calls);
    if (c.callCount == 0) return true;
    c.calls = cast(Call*) calloc(c.callCount, Call.sizeof);
    if (c.calls is null) { c.callCount = 0; return false; }
    foreach (i; 0 .. c.callCount) {
        auto call = json_object_array_get_idx(calls, i);
        auto fn = jsonField(call, "function");
        c.calls[i] = Call(text(jsonField(call, "id")), text(jsonField(fn, "name")), text(jsonField(fn, "arguments")));
        if (c.calls[i].id is null || c.calls[i].name is null || c.calls[i].arguments is null) return false;
    }
    return true;
}
