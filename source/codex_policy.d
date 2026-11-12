module codex_policy;

// A native control's parameters use the same PBT parser and compiled sand
// as every other control. No thresholds are hidden in the engine.
struct CodexPolicy {
    bool present;
    bool enabled = true;
    int mediumBelow = -1;
    int lowBelow = -1;
    int skipBefore5hResetMinutes;
    int interval;
    const(char)[] error;
}

private int boundedNumber(const(char)[] text, int maximum) {
    if (text.length == 0 || text.length > 3) return -1;
    int number;
    foreach (c; text) {
        if (c < '0' || c > '9') return -1;
        number = number * 10 + c - '0';
    }
    return number <= maximum ? number : -1;
}

CodexPolicy codexPolicyControl(C)(ref const C control) {
    CodexPolicy p;
    p.present = true;
    p.interval = control.interval;
    foreach (i; 0 .. control.paramCount) {
        auto key = control.paramKeys[i];
        auto value = control.paramValues[i];
        foreach (j; 0 .. i) if (control.paramKeys[j] == key) {
            p.error = "codex-effort has a duplicate parameter"; return p;
        }
        if (key == "enabled") {
            if (value != "true" && value != "false") {
                p.error = "codex-effort enabled must be true or false"; return p;
            }
            p.enabled = value == "true";
        } else if (key == "medium_below" || key == "low_below") {
            auto number = boundedNumber(value, 100);
            if (number < 0) { p.error = "codex-effort thresholds must be whole percentages from 0 to 100"; return p; }
            if (key == "medium_below") p.mediumBelow = number;
            else p.lowBelow = number;
        } else if (key == "skip_before_5h_reset_minutes") {
            auto number = boundedNumber(value, 300);
            if (number < 0) { p.error = "codex-effort skip_before_5h_reset_minutes must be whole minutes from 0 to 300"; return p; }
            p.skipBefore5hResetMinutes = number;
        } else { p.error = "unknown codex-effort parameter"; return p; }
    }
    if (!p.enabled) return p;
    if (p.mediumBelow < 0 || p.lowBelow < 0 || p.lowBelow > p.mediumBelow)
        p.error = "codex-effort requires 0 <= low_below <= medium_below <= 100";
    else if (p.interval < 1 || p.interval > 86400)
        p.error = "codex-effort interval must be between 1 and 86400 seconds";
    return p;
}

// Last matching declaration wins within a layer, so a later path-specific
// control can override the global one. Each declaration is a whole policy.
CodexPolicy codexPolicyFor(P)(auto ref const P parsed, const(char)[] cwd,
                              const(char)[] event, const(char)[] origin = "") {
    import hooks : scopeMatches;
    CodexPolicy selected;
    foreach (ref scope_; parsed.scopes[0 .. parsed.scopeCount]) {
        bool eventMatches = scope_.event == event;
        foreach (e; scope_.extraEvents[0 .. scope_.extraEventCount])
            if (e == event) eventMatches = true;
        if (!eventMatches || !scopeMatches(scope_, cwd)) continue;
        foreach (ref control; parsed.ctrlPool[scope_.controlStart .. scope_.controlEnd]) {
            if (control.name != "codex-effort") continue;
            if (control.origin.length && control.origin != origin) continue;
            selected = codexPolicyControl(control);
            if (scope_.cmdCount || scope_.editedCount || scope_.publicOnly || scope_.mcpTool.length)
                selected.error = "codex-effort scopes support path and event selectors only";
        }
    }
    return selected;
}

CodexPolicy codexPolicyHere(const(char)[] cwd, const(char)[] event) {
    import controls : sand;
    import sand.layered : sourceLayers;
    import git : originOf;
    auto origin = originOf(cwd);
    CodexPolicy selected;
    foreach (layer; sourceLayers(sand())) {
        if (layer is null) continue;
        auto policy = codexPolicyFor(layer.parsed, cwd, event, origin);
        if (policy.present) selected = policy;
    }
    return selected;
}
