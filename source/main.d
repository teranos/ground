module main;

import matcher;
import core.stdc.stdio : stdin, stdout, stderr, fread, fputs, fprintf, fwrite;
import core.stdc.stdlib : exit;

// Reads all of stdin into a static buffer.
// Returns the filled slice, or null on failure/empty.
const(char)[] readStdin() {
    __gshared char[8192] buf = 0;
    size_t total = 0;

    while (total < buf.length) {
        auto n = fread(&buf[total], 1, buf.length - total, stdin);
        if (n == 0) break;
        total += n;
    }

    if (total == 0) return null;
    return buf[0 .. total];
}

// Extracts the value of "command" from the hook JSON.
// Handles JSON escape sequences: \" becomes ", \\ becomes \.
// Returns unescaped command in a static buffer.
const(char)[] extractCommand(const(char)[] json) {
    __gshared char[8192] cmdBuf = 0;

    enum needle = `"command"`;
    auto idx = indexOf(json, needle);
    if (idx < 0) return null;

    // Skip past "command", then whitespace, then colon, then whitespace, then opening quote
    size_t pos = cast(size_t) idx + needle.length;
    while (pos < json.length && json[pos] == ' ') pos++;
    if (pos >= json.length || json[pos] != ':') return null;
    pos++;
    while (pos < json.length && json[pos] == ' ') pos++;
    if (pos >= json.length || json[pos] != '"') return null;
    pos++; // skip opening quote

    // Read value, unescaping as we go
    size_t len = 0;
    while (pos < json.length && len < cmdBuf.length) {
        if (json[pos] == '\\' && pos + 1 < json.length) {
            pos++; // skip backslash, take next char literally
            cmdBuf[len++] = json[pos];
            pos++;
        } else if (json[pos] == '"') {
            break; // unescaped quote = end of string
        } else {
            cmdBuf[len++] = json[pos];
            pos++;
        }
    }

    if (len == 0) return null;
    return cmdBuf[0 .. len];
}

// Writes the hook JSON response to stdout.
// The command is embedded in the JSON, with quotes escaped.
void writeResponse(const(char)[] command) {
    fputs(`{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"`, stdout);
    // Escape the command value for JSON
    foreach (c; command) {
        if (c == '"')
            fputs(`\"`, stdout);
        else if (c == '\\')
            fputs(`\\`, stdout);
        else {
            char[1] buf = c;
            fwrite(&buf[0], 1, 1, stdout);
        }
    }
    fputs(`"}}}`, stdout);
    fputs("\n", stdout);
}

extern (C) int main() {
    auto input = readStdin();
    if (input is null) {
        fputs("graunde: empty stdin\n", stderr);
        return 1;
    }

    auto command = extractCommand(input);
    if (command is null) {
        fputs("graunde: missing tool_input.command\n", stderr);
        return 1;
    }

    auto result = checkCommand(command);

    if (result.control is null)
        return 0;

    Buf amended;
    if (result.control.omit.value.length > 0)
        amended = applyOmit(result.control, result.segment);
    else
        amended = applyArg(result.control, result.segment);

    // If the amended segment differs, rebuild the full command
    if (amended.slice() != result.segment) {
        auto segIdx = indexOf(command, result.segment);
        if (segIdx >= 0) {
            Buf full;
            full.put(command[0 .. cast(size_t) segIdx]);
            full.put(amended.slice());
            full.put(command[cast(size_t) segIdx + result.segment.length .. $]);
            writeResponse(full.slice());
            return 0;
        }
    }

    return 0;
}
