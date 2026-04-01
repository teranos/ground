module permissionrequest;

import core.stdc.stdio : stdout, fputs;
import parse : extractToolName, extractCommand, extractFilePath, writeJsonString;
import permission : evaluatePermission, Decision;

int handlePermissionRequest(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    auto toolName = extractToolName(input);
    if (toolName is null) return 0;

    auto command = extractCommand(input);
    if (command is null) command = extractFilePath(input);
    if (command is null) command = "";

    import controls : permissionScopes;
    auto result = evaluatePermission(permissionScopes, cwd, toolName, command);

    if (result.decision == Decision.deny) {
        if (result.name.length > 0) {
            import sqlite : attestControlFire;
            attestControlFire(null, "GroundedPermissionDeny", result.name, cwd, sessionId);
        }
        writeDenyResponse(result.msg);
        return 0;
    }

    if (result.decision == Decision.allow) {
        if (result.name.length > 0) {
            import sqlite : attestControlFire;
            attestControlFire(null, "GroundedPermissionAllow", result.name, cwd, sessionId);
        }
        writeAllowResponse();
        return 0;
    }

    if (result.decision == Decision.ask) {
        if (result.name.length > 0) {
            import sqlite : attestControlFire;
            attestControlFire(null, "GroundedPermissionAsk", result.name, cwd, sessionId);
        }
        // Fall through to normal prompt
        return 0;
    }

    // Decision.none — no match, fall through to normal prompt
    return 0;
}

// PermissionRequest JSON format (distinct from PreToolUse):
//   {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow|deny","message":"..."}}}
// PreToolUse uses "permissionDecision" key instead — see main.d writeDenyResponse.
// writeJsonString emits escaped content without surrounding quotes.
void writeAllowResponse() {
    fputs(`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`, stdout);
    fputs("\n", stdout);
}

void writeDenyResponse(const(char)[] msg) {
    fputs(`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"`, stdout);
    if (msg.length > 0)
        writeJsonString(msg);
    fputs(`"}}}`, stdout);
    fputs("\n", stdout);
}
