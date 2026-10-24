module code.prompt;

// One turn of a session: the prompt goes to the node's gateway as chat
// completions with the session's tools, a tool_calls answer is run through
// the session's own MCP servers and handed back, until the model stops.

import matcher : indexOf;
import parse : Reads;
import code.reply : Reply, putEscaped, putNumber;

// The path on the node that the openrouter-qntx plugin answers at.
enum GATEWAY_PATH = "/api/openrouter-qntx/v1/chat/completions";

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
private size_t skipValue(const(char)[] json, size_t pos) {
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

private size_t blanks(const(char)[] json, size_t pos) {
    while (pos < json.length && (json[pos] == ' ' || json[pos] == '\n' || json[pos] == '\t' || json[pos] == '\r')) pos++;
    return pos;
}

// The prompt's text blocks, in order, one line each. A block of another kind
// has no text to give the model, and is not pretended to: false, and other
// gets the type of the first such block, empty when it names none.
@Reads("prompt") bool promptText(const(char)[] line, ref Reply r, ref Reply other) {
    auto at = indexOf(line, `"prompt"`);
    if (at < 0) return true;
    size_t pos = blanks(line, cast(size_t) at + `"prompt"`.length);
    if (pos >= line.length || line[pos] != ':') return true;
    pos = blanks(line, pos + 1);
    if (pos >= line.length || line[pos] != '[') return true;
    pos = blanks(line, pos + 1);
    bool first = true, all = true;
    while (pos < line.length && line[pos] == '{') {
        auto end = skipValue(line, pos);
        auto block = line[pos .. end];
        bool text;
        Reply value, kind;
        size_t p = 1;
        while (p < block.length) {
            p = blanks(block, p);
            if (p >= block.length || block[p] != '"') break;
            Reply key;
            p = copyString(block, p, key);
            p = blanks(block, p);
            if (p >= block.length || block[p] != ':') break;
            p = blanks(block, p + 1);
            if (key.slice() == "type" && p < block.length && block[p] == '"') {
                kind.len = 0; copyString(block, p, kind);
                text = kind.slice() == "text";
            }
            if (key.slice() == "text" && p < block.length && block[p] == '"') { value.len = 0; copyString(block, p, value); }
            p = skipValue(block, p);
            p = blanks(block, p);
            if (p < block.length && block[p] == ',') p++;
        }
        if (!text && all) { all = false; other.add(kind.slice()); }
        if (text) {
            if (!first) r.add("\n");
            first = false;
            r.add(value.slice());
        }
        pos = blanks(line, end);
        if (pos < line.length && line[pos] == ',') pos = blanks(line, pos + 1);
    }
    return all;
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

struct Call { const(char)[] id; const(char)[] name; const(char)[] arguments; }

// What the model answered: its text, or the calls it wants made. The slices
// point into the parsed JSON, which lives until dispose.
struct Completion {
    json_object* root;
    const(char)[] message;  // choices[0].message, as the gateway wrote it
    const(char)[] content;
    Call* calls;
    size_t callCount;
    void dispose() {
        json_object_put(root); root = null;
        free(calls); calls = null; callCount = 0;
        message = null; content = null;
    }
}

bool completionOf(const(char)[] json, ref Completion c) {
    c.root = parseJson(json);
    auto choices = jsonField(c.root, "choices");
    if (json_object_get_type(choices) != json_type.array || json_object_array_length(choices) == 0) return false;
    auto message = jsonField(json_object_array_get_idx(choices, 0), "message");
    if (json_object_get_type(message) != json_type.object) return false;
    c.message = raw(message);
    c.content = text(jsonField(message, "content"));
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
