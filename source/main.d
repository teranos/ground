module main;

import matcher;
import controls : HookEvent;
import sqlite : writeAttestation;
import core.stdc.stdio : stdin, stdout, stderr, fread, fputs, fprintf, fwrite;
import core.stdc.stdlib : exit;
import core.sys.posix.unistd : isatty;

// Parse hook_event_name string to HookEvent. CTFE-unrolled.
bool parseHookEvent(const(char)[] name, ref HookEvent event) {
    static foreach (member; __traits(allMembers, HookEvent)) {
        if (name == member) {
            event = __traits(getMember, HookEvent, member);
            return true;
        }
    }
    return false;
}

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

// Writes the hook JSON response to stdout.
// The command is embedded in the JSON, with quotes escaped.
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

void writeResponse(const(char)[] command, const(char)[] context, const(char)[] decision) {
    fputs(`{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"`, stdout);
    fputs2(decision);
    fputs(`","updatedInput":{"command":"`, stdout);
    writeJsonString(command);
    fputs(`"},"additionalContext":"`, stdout);
    writeJsonString(context);
    fputs(`"}}`, stdout);
    fputs("\n", stdout);
}

// fputs for const(char)[] slices (fputs needs null-terminated strings)
void fputs2(const(char)[] s) {
    foreach (c; s) {
        char[1] buf = c;
        fwrite(&buf[0], 1, 1, stdout);
    }
}

enum VERSION = import(".version");

void printVersion() {
    fputs("graunde ", stderr);
    // Print version without trailing newline from git describe
    foreach (c; VERSION)
        if (c != '\n' && c != '\r') {
            char[1] buf = c;
            fwrite(&buf[0], 1, 1, stderr);
        }
}

extern (C) int main() {
    if (isatty(0)) {
        printVersion();
        fputs(" — Ground Control for Claude Code\n", stderr);
        return 0;
    }

    auto input = readStdin();
    if (input is null) {
        fputs("graunde: empty stdin\n", stderr);
        return 1;
    }

    // Common fields
    auto cwd = extractCwd(input);
    if (cwd is null) cwd = "";
    auto sessionId = extractSessionId(input);
    if (sessionId is null) sessionId = "";

    auto eventName = extractHookEventName(input);
    if (eventName is null) return 0;

    HookEvent event;
    if (!parseHookEvent(eventName, event)) return 0;

    if (event == HookEvent.PreToolUse) {
        auto toolName = extractToolName(input);
        auto toolUseId = extractToolUseId(input);
        if (toolUseId is null) toolUseId = "unknown";

        auto command = extractCommand(input);

        if (command !is null) {
            // Bash — check controls
            auto result = checkCommand(command, cwd);

            if (result.control !is null) {
                writeAttestation(result.control.name, cwd, sessionId, toolUseId, command);

                // Msg-only control — no amendment, just decision + context
                // TODO(#3): query branch story and append to context
                if (result.control.arg.value.length == 0 && result.control.omit.value.length == 0) {
                    writeResponse(command, result.control.msg.value, result.decision);
                    return 0;
                }

                Buf amended;
                if (result.control.omit.value.length > 0)
                    amended = applyOmit(result.control, result.segment);
                else
                    amended = applyArg(result.control, result.segment);

                if (amended.slice() != result.segment) {
                    auto segIdx = indexOf(command, result.segment);
                    if (segIdx >= 0) {
                        Buf full;
                        full.put(command[0 .. cast(size_t) segIdx]);
                        full.put(amended.slice());
                        full.put(command[cast(size_t) segIdx + result.segment.length .. $]);
                        writeResponse(full.slice(), result.control.msg.value, result.decision);
                        return 0;
                    }
                }
                return 0;
            }

            // No control match — still attest the tool call
            writeAttestation(toolName !is null ? toolName : "Bash", cwd, sessionId, toolUseId, command);
            return 0;
        }

        // Non-Bash tool (Edit/Write/Read/etc.) — attest with file_path if available
        auto filePath = extractFilePath(input);
        writeAttestation(
            toolName !is null ? toolName : "unknown",
            cwd, sessionId, toolUseId,
            filePath !is null ? filePath : ""
        );
        return 0;
    }

    // Lifecycle events — attest and pass through
    if (event == HookEvent.PostToolUse || event == HookEvent.PreCompact
        || event == HookEvent.Stop || event == HookEvent.SessionStart) {
        auto toolUseId = extractToolUseId(input);
        auto id = toolUseId !is null ? toolUseId : buildEventId(eventName);
        auto detail = extractCommand(input);
        if (detail is null) detail = extractFilePath(input);
        if (detail is null) detail = eventName;
        writeAttestation(eventName, cwd, sessionId, id, detail);
    }

    // Unknown events — exit 0, no output
    return 0;
}
