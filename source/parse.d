module parse;

// Hook input is one JSON object on stdin. Its fields, per event and version, are
// the pinned agent binaries' own schemas: `ground parity <Event>` lists them.

import matcher : indexOf;
import core.stdc.stdio : stdout, fputs, fwrite;

// The top-level hook input field an extractor reads. `ground parity` counts a
// handler's calls through these against each agent's pinned contract.
struct Reads { string key; }

// Extracts a JSON string value by key into the provided buffer.
// Handles JSON escape sequences: \" becomes ", \\ becomes \, \n becomes newline.
const(char)[] extractJsonString(const(char)[] json, string key, char* buf, size_t bufLen) {
    auto idx = indexOf(json, key);
    if (idx < 0) return null;
    return extractJsonStringAt(json, idx, key, buf, bufLen);
}

const(char)[] extractJsonStringAt(const(char)[] json, ptrdiff_t idx, string key, char* buf, size_t bufLen) {
    // Skip past key, then whitespace, then colon, then whitespace, then opening quote
    size_t pos = cast(size_t) idx + key.length;
    while (pos < json.length && json[pos] == ' ') pos++;
    if (pos >= json.length || json[pos] != ':') return null;
    pos++;
    while (pos < json.length && json[pos] == ' ') pos++;
    if (pos >= json.length || json[pos] != '"') return null;
    pos++; // skip opening quote

    // Read value, unescaping JSON sequences as we go
    size_t len = 0;
    while (pos < json.length && len < bufLen) {
        if (json[pos] == '\\' && pos + 1 < json.length) {
            pos++;
            switch (json[pos]) {
                case 'n': buf[len++] = '\n'; break;
                case 't': buf[len++] = '\t'; break;
                case 'r': buf[len++] = '\r'; break;
                case '"': buf[len++] = '"'; break;
                case '\\': buf[len++] = '\\'; break;
                case '/': buf[len++] = '/'; break;
                default: buf[len++] = json[pos]; break;
            }
            pos++;
        } else if (json[pos] == '"') {
            break; // unescaped quote = end of string
        } else {
            buf[len++] = json[pos];
            pos++;
        }
    }

    if (len == 0) return null;
    return buf[0 .. len];
}

@Reads("tool_input") const(char)[] extractCommand(const(char)[] json) {
    __gshared char[8192] buf = 0;
    return extractJsonString(json, `"command"`, &buf[0], buf.length);
}

@Reads("cwd") const(char)[] extractCwd(const(char)[] json) {
    __gshared char[4096] buf = 0;
    return extractJsonString(json, `"cwd"`, &buf[0], buf.length);
}

@Reads("transcript_path") const(char)[] extractTranscriptPath(const(char)[] json) {
    __gshared char[4096] buf = 0;
    return extractJsonString(json, `"transcript_path"`, &buf[0], buf.length);
}

@Reads("session_id") const(char)[] extractSessionId(const(char)[] json) {
    __gshared char[128] buf = 0;
    return extractJsonString(json, `"session_id"`, &buf[0], buf.length);
}

@Reads("tool_use_id") const(char)[] extractToolUseId(const(char)[] json) {
    __gshared char[128] buf = 0;
    return extractJsonString(json, `"tool_use_id"`, &buf[0], buf.length);
}

@Reads("source") const(char)[] extractSource(const(char)[] json) {
    __gshared char[32] buf = 0;
    return extractJsonString(json, `"source"`, &buf[0], buf.length);
}

@Reads("hook_event_name") const(char)[] extractHookEventName(const(char)[] json) {
    __gshared char[64] buf = 0;
    return extractJsonString(json, `"hook_event_name"`, &buf[0], buf.length);
}

@Reads("tool_name") const(char)[] extractToolName(const(char)[] json) {
    __gshared char[64] buf = 0;
    return extractJsonString(json, `"tool_name"`, &buf[0], buf.length);
}

// Which permission mode the session is in. The mode the UI labels Manual
// arrives here as "default" and never as "manual", so anything comparing
// against it compares against "default".
@Reads("permission_mode") const(char)[] extractPermissionMode(const(char)[] json) {
    __gshared char[32] buf = 0;
    return extractJsonString(json, `"permission_mode"`, &buf[0], buf.length);
}

// Returns the raw JSON region for "tool_input": { ... } — no parsing, just the brace-delimited slice.
@Reads("tool_input") const(char)[] extractToolInputRegion(const(char)[] json) {
    auto idx = indexOf(json, `"tool_input"`);
    if (idx < 0) return null;
    size_t pos = cast(size_t) idx + 12; // skip "tool_input"
    while (pos < json.length && json[pos] != '{') pos++;
    if (pos >= json.length) return null;
    // Find matching closing brace
    size_t depth = 0;
    size_t start = pos;
    while (pos < json.length) {
        if (json[pos] == '{') depth++;
        else if (json[pos] == '}') { depth--; if (depth == 0) return json[start .. pos + 1]; }
        pos++;
    }
    return null;
}

// The JSON from "tool_response" onward, or null before the tool has answered.
// A key looked up from here cannot be one the command happened to quote.
@Reads("tool_response") const(char)[] toolResponseRegion(const(char)[] json) {
    auto idx = indexOf(json, `"tool_response"`);
    if (idx < 0) return null;
    size_t pos = cast(size_t) idx + `"tool_response"`.length;
    while (pos < json.length && json[pos] != '{') pos++;
    if (pos >= json.length) return null;
    return json[pos .. $];
}

// What the tool printed. Unescaped, so a rite reads the lines git wrote and
// not the two-character \n the hook carries them as.
@Reads("tool_response") const(char)[] extractToolOutput(const(char)[] json) {
    __gshared char[65536] buf = 0;
    auto region = toolResponseRegion(json);
    if (region is null) return null;
    return extractJsonString(region, `"stdout"`, &buf[0], buf.length);
}

@Reads("tool_input") const(char)[] extractFilePath(const(char)[] json) {
    __gshared char[4096] buf = 0;
    return extractJsonString(json, `"file_path"`, &buf[0], buf.length);
}

@Reads("tool_input") const(char)[] extractNewString(const(char)[] json) {
    __gshared char[16384] buf = 0;
    return extractJsonString(json, `"new_string"`, &buf[0], buf.length);
}

// The text an edit would add — Edit's new_string, or Write's content.
// Unescaped, so a caller counting lines sees newlines rather than the
// two-character \n the raw tool_input carries.
@Reads("tool_input") const(char)[] extractWrittenText(const(char)[] json) {
    __gshared char[32768] buf = 0;
    auto s = extractJsonString(json, `"new_string"`, &buf[0], buf.length);
    if (s !is null) return s;
    return extractJsonString(json, `"content"`, &buf[0], buf.length);
}

@Reads("tool_input") const(char)[] extractUrl(const(char)[] json) {
    __gshared char[4096] buf = 0;
    return extractJsonString(json, `"url"`, &buf[0], buf.length);
}

@Reads("tool_response") const(char)[] extractStdout(const(char)[] json) {
    __gshared char[4096] buf = 0;
    return extractJsonString(json, `"stdout"`, &buf[0], buf.length);
}

@Reads("tool_response") const(char)[] extractStderr(const(char)[] json) {
    __gshared char[4096] buf = 0;
    return extractJsonString(json, `"stderr"`, &buf[0], buf.length);
}

@Reads("error") const(char)[] extractError(const(char)[] json) {
    __gshared char[4096] buf = 0;
    return extractJsonString(json, `"error"`, &buf[0], buf.length);
}

@Reads("last_assistant_message") const(char)[] extractLastAssistantMessage(const(char)[] json) {
    __gshared char[8192] buf = 0;
    // last_assistant_message is near the end of the JSON — search backwards
    import matcher : lastIndexOf;
    auto idx = lastIndexOf(json, `"last_assistant_message"`);
    if (idx < 0) return null;
    return extractJsonStringAt(json, idx, `"last_assistant_message"`, &buf[0], buf.length);
}

// tool_response.filePath (camelCase, distinct from tool_input.file_path)
@Reads("tool_response") const(char)[] extractResponseFilePath(const(char)[] json) {
    __gshared char[4096] buf = 0;
    return extractJsonString(json, `"filePath"`, &buf[0], buf.length);
}

bool extractBool(const(char)[] json, string key) {
    auto idx = indexOf(json, key);
    if (idx < 0) return false;

    size_t pos = cast(size_t) idx + key.length;
    while (pos < json.length && json[pos] == ' ') pos++;
    if (pos >= json.length || json[pos] != ':') return false;
    pos++;
    while (pos < json.length && json[pos] == ' ') pos++;

    if (pos + 4 <= json.length && json[pos .. pos + 4] == "true")
        return true;
    return false;
}

// Build unique ID for non-tool events (no tool_use_id available)
const(char)[] buildEventId(const(char)[] eventName) {
    import db : formatTimestamp;
    __gshared char[256] buf = 0;
    size_t len = 0;
    foreach (c; "ground:") { if (len < 255) buf[len++] = c; }
    foreach (c; eventName) { if (len < 255) buf[len++] = c; }
    if (len < 255) buf[len++] = ':';
    foreach (c; formatTimestamp()) { if (len < 255) buf[len++] = c; }
    return buf[0 .. len];
}

// Writes a JSON-escaped string to stdout.
void writeJsonString(const(char)[] s) {
    foreach (c; s) {
        switch (c) {
            case '"': fputs(`\"`, stdout); break;
            case '\\': fputs(`\\`, stdout); break;
            case '\n': fputs(`\n`, stdout); break;
            case '\r': fputs(`\r`, stdout); break;
            case '\t': fputs(`\t`, stdout); break;
            default:
                char[1] buf = c;
                fwrite(&buf[0], 1, 1, stdout);
                break;
        }
    }
}

// fputs for const(char)[] slices (fputs needs null-terminated strings)
void fputs2(const(char)[] s) {
    foreach (c; s) {
        char[1] buf = c;
        fwrite(&buf[0], 1, 1, stdout);
    }
}
