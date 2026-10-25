module permissionrequest;

import core.stdc.stdio : stdout, fputs;
import parse : extractToolName, extractCommand, extractFilePath, extractUrl, writeJsonString;
import permission : evaluatePermission, Decision, PermissionResult, PermissionScope;

// The rules' answer in the session's mode, as the event names it: a rule's
// allow is granted by the mode, and an unknown mode grants nothing.
PermissionResult permissionFor(const(PermissionScope)[] scopes, const(char)[] cwd,
        const(char)[] toolName, const(char)[] command, const(char)[] modeWire) {
    import sessionmode : parseSessionMode;
    return evaluatePermission(scopes, cwd, toolName, command, parseSessionMode(modeWire));
}

int handlePermissionRequest(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    auto toolName = extractToolName(input);
    if (toolName is null) return 0;

    auto command = extractCommand(input);
    if (command is null) command = extractFilePath(input);
    if (command is null) command = extractUrl(input);
    if (command is null) command = "";

    import controls : permissionScopes;
    import parse : extractPermissionMode;
    auto result = permissionFor(permissionScopes, cwd, toolName, command, extractPermissionMode(input));

    if (result.decision == Decision.deny) {
        if (result.name.length > 0) {
            import db : attestControlFire;
            attestControlFire(null, "GroundedPermissionDeny", result.name, cwd, sessionId);
        }
        writeDenyResponse(result.msg);
        return 0;
    }

    if (result.decision == Decision.allow) {
        if (result.name.length > 0) {
            import db : attestControlFire;
            attestControlFire(null, "GroundedPermissionAllow", result.name, cwd, sessionId);
        }
        writeAllowResponse();
        return 0;
    }

    if (result.decision == Decision.ask) {
        if (result.name.length > 0) {
            import db : attestControlFire;
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
