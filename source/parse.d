module parse;

import matcher : indexOf;
import core.stdc.stdio : stdout, fputs, fwrite;

// Extracts a JSON string value by key into the provided buffer.
// Handles JSON escape sequences: \" becomes ", \\ becomes \, \n becomes newline.
const(char)[] extractJsonString(const(char)[] json, string key, char* buf, size_t bufLen) {
    auto idx = indexOf(json, key);
    if (idx < 0) return null;

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

const(char)[] extractCommand(const(char)[] json) {
    __gshared char[8192] buf = 0;
    return extractJsonString(json, `"command"`, &buf[0], buf.length);
}

const(char)[] extractCwd(const(char)[] json) {
    __gshared char[4096] buf = 0;
    return extractJsonString(json, `"cwd"`, &buf[0], buf.length);
}

const(char)[] extractSessionId(const(char)[] json) {
    __gshared char[128] buf = 0;
    return extractJsonString(json, `"session_id"`, &buf[0], buf.length);
}

const(char)[] extractToolUseId(const(char)[] json) {
    __gshared char[128] buf = 0;
    return extractJsonString(json, `"tool_use_id"`, &buf[0], buf.length);
}

const(char)[] extractSource(const(char)[] json) {
    __gshared char[32] buf = 0;
    return extractJsonString(json, `"source"`, &buf[0], buf.length);
}

const(char)[] extractHookEventName(const(char)[] json) {
    __gshared char[64] buf = 0;
    return extractJsonString(json, `"hook_event_name"`, &buf[0], buf.length);
}

const(char)[] extractToolName(const(char)[] json) {
    __gshared char[64] buf = 0;
    return extractJsonString(json, `"tool_name"`, &buf[0], buf.length);
}

const(char)[] extractFilePath(const(char)[] json) {
    __gshared char[4096] buf = 0;
    return extractJsonString(json, `"file_path"`, &buf[0], buf.length);
}

const(char)[] extractStdout(const(char)[] json) {
    __gshared char[4096] buf = 0;
    return extractJsonString(json, `"stdout"`, &buf[0], buf.length);
}

const(char)[] extractStderr(const(char)[] json) {
    __gshared char[4096] buf = 0;
    return extractJsonString(json, `"stderr"`, &buf[0], buf.length);
}

const(char)[] extractLastAssistantMessage(const(char)[] json) {
    __gshared char[8192] buf = 0;
    return extractJsonString(json, `"last_assistant_message"`, &buf[0], buf.length);
}

// tool_response.filePath (camelCase, distinct from tool_input.file_path)
const(char)[] extractResponseFilePath(const(char)[] json) {
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
    import sqlite : formatTimestamp;
    __gshared char[256] buf = 0;
    size_t len = 0;
    foreach (c; "graunde:") { if (len < 255) buf[len++] = c; }
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
