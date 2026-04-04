module posttoolusefailure;

import matcher : contains;
import hooks : scopeMatches;
import parse : fputs2;
import core.stdc.stdio : stdout, fputs;

int handlePostToolUseFailure(const(char)[] input, const(char)[] cwd, const(char)[] sessionId) {
    import parse : extractError;
    import controls : postToolUseFailureScopes;

    auto error = extractError(input);
    if (error is null) return 0;

    foreach (ref scope_; postToolUseFailureScopes) {
        if (!scopeMatches(scope_.path, cwd))
            continue;
        foreach (ref c; scope_.controls) {
            if (c.trigger.len == 0) continue;
            bool matched = false;
            foreach (ref v; c.trigger.values)
                if (contains(error, v)) { matched = true; break; }
            if (!matched) continue;

            {
                import db : attestControlFire;
                attestControlFire(null, "GroundedPostToolUseFailure", c.name, cwd, sessionId);
            }
            fputs(`{"systemMessage":"`, stdout);
            fputs2(c.msg.value);
            fputs(`"}`, stdout);
            fputs("\n", stdout);
            return 0;
        }
    }
    return 0;
}
