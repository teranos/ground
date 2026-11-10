module codex_effort_test;

import effort : codexWanted, codexLowers;

static assert(codexWanted(50, 50, 20) == "");
static assert(codexWanted(49.9, 50, 20) == "medium");
static assert(codexWanted(20, 50, 20) == "medium");
static assert(codexWanted(19.9, 50, 20) == "low");
static assert(codexWanted(0, 50, 20) == "low");
static assert(codexWanted(-1, 50, 20) == "");
static assert(codexWanted(double.nan, 50, 20) == "");
static assert(codexWanted(101, 50, 20) == "");
static assert(codexLowers("high", "medium"));
static assert(codexLowers("medium", "low"));
static assert(!codexLowers("low", "medium"));
static assert(!codexLowers("minimal", "low"));
static assert(!codexLowers("unknown", "low"));
static assert(!codexLowers("high", ""));

import codex_policy : codexPolicyFor;
import proto : parsePbt;
private enum customPolicy = parsePbt(`scope {
    event: ["PreModelRequest", "PostModelRequest"]
    control { name: "codex-effort" interval: "90"
        handler_params { enabled: "true" medium_below: "70" low_below: "30" skip_before_5h_reset_minutes: "45" }
    }
}`);
static assert(codexPolicyFor(customPolicy, "/tmp", "PostModelRequest").mediumBelow == 70);
static assert(codexPolicyFor(customPolicy, "/tmp", "PreModelRequest").lowBelow == 30);
static assert(codexPolicyFor(customPolicy, "/tmp", "PreModelRequest").interval == 90);
static assert(!codexPolicyFor(customPolicy, "/tmp", "Stop").present);
static assert(codexPolicyFor(customPolicy, "/tmp", "PostModelRequest").skipBefore5hResetMinutes == 45);
static assert(codexWanted(60, 70, 30) == "medium");
static assert(codexWanted(25, 70, 30) == "low");
static assert(codexWanted(25, 20, 30) == "");

private enum disabledPolicy = parsePbt(`scope {
    event: "PostModelRequest"
    control { name: "codex-effort" handler_params { enabled: "false" } }
}`);
static assert(!codexPolicyFor(disabledPolicy, "/tmp", "PostModelRequest").enabled);
private enum scopedPolicy = parsePbt(`scope {
    path: "/project"
    event: "PostModelRequest"
    control { name: "codex-effort" interval: "60"
        handler_params { medium_below: "60" low_below: "10" }
    }
}`);
static assert(!codexPolicyFor(scopedPolicy, "/elsewhere", "PostModelRequest").present);
static assert(codexPolicyFor(scopedPolicy, "/project", "PostModelRequest").present);
static assert(!__traits(compiles, { enum bad = parsePbt(`control {
    name: "codex-effort" interval: "60" handler_params { medium_below: "20" low_below: "50" }
}`); }));
static assert(!__traits(compiles, { enum bad = parsePbt(`control {
    name: "codex-effort" interval: "60" handler_params { medium_below: "50" low_below: "20" enabld: "false" }
}`); }));
static assert(!__traits(compiles, { enum bad = parsePbt(`control {
    name: "codex-effort" interval: "0" handler_params { medium_below: "50" low_below: "20" }
}`); }));

unittest {
    import sand.view : Sand, viewOf, SAND_ABI;
    import sand.layered : layer, sourceLayers;
    static immutable custom = customPolicy;
    static immutable disabled = disabledPolicy;
    static immutable empty = parsePbt("");
    auto floor = Sand(SAND_ABI, viewOf(custom));
    auto local = Sand(SAND_ABI, viewOf(disabled));
    auto comet = Sand(SAND_ABI, viewOf(empty));
    auto combined = layer(&floor, &local, &comet);
    auto sources = sourceLayers(combined);
    assert(sources[0] is &floor && sources[1] is &local && sources[2] is &comet);
    import codex_policy : CodexPolicy;
    CodexPolicy selected;
    foreach (s; sources) {
        auto p = codexPolicyFor(s.parsed, "/tmp", "PostModelRequest");
        if (p.present) selected = p;
    }
    assert(selected.present && !selected.enabled, "an empty comet must not discard the local override");
    auto single = sourceLayers(&floor);
    assert(single[0] is &floor && single[1] is null && single[2] is null);
}

import codexrpc : websocketAccept;
static assert(() {
    char[24] key = "dGhlIHNhbXBsZSBub25jZQ==";
    return websocketAccept(key)[] == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";
}());

import codexeffort : codexRemaining, codexEffortEvent;
import libjsonc : parseJson, json_object_put;

unittest {
    double reading(const(char)[] json) {
        auto obj = parseJson(json);
        scope(exit) json_object_put(obj);
        return codexRemaining(obj, 100);
    }
    assert(reading(`{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":30,"resetsAt":200},"secondary":{"usedPercent":85,"resetsAt":200}}}}`) == 15);
    assert(reading(`{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":30,"resetsAt":200},"secondary":{"usedPercent":85,"resetsAt":100}}}}`) == 70);
    assert(reading(`{"rateLimits":{"limitId":"codex","primary":{"usedPercent":51,"resetsAt":200}}}`) == 49);
    assert(reading(`{"rateLimits":{"limitId":"other","primary":{"usedPercent":51,"resetsAt":200}}}`) == -1);
    assert(reading(`{"rateLimitsByLimitId":{},"rateLimits":{"limitId":"codex","primary":{"usedPercent":51,"resetsAt":200}}}`) == -1);
    assert(reading(`{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":true,"resetsAt":200}}}}`) == -1);
    assert(reading(`{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":101,"resetsAt":200}}}}`) == -1);
    assert(reading(`{}`) == -1);
}

static assert(codexPolicyFor(scopedPolicy, "/project", "PostModelRequest").skipBefore5hResetMinutes == 0);
static assert(!__traits(compiles, { enum bad = parsePbt(`control {
    name: "codex-effort" interval: "60" handler_params {
        medium_below: "50" low_below: "20" skip_before_5h_reset_minutes: "301"
    }
}`); }));
static assert(!__traits(compiles, { enum bad = parsePbt(`control {
    name: "codex-effort" interval: "60" handler_params {
        medium_below: "50" low_below: "20" skip_before_5h_reset_minutes: "1.5"
    }
}`); }));

unittest {
    import codexeffort : codexResetGrace;
    bool grace(const(char)[] json, int minutes = 60) {
        auto obj = parseJson(json);
        scope(exit) json_object_put(obj);
        return codexResetGrace(obj, 100, minutes);
    }
    enum atHour = `{"rateLimits":{"limitId":"codex","primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":3700}}}`;
    assert(grace(atHour), "exactly one hour is inside the grace period");
    assert(!grace(atHour, 59));
    assert(!grace(atHour, 0));
    assert(!grace(`{"rateLimits":{"limitId":"codex","primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":3701}}}`));
    assert(grace(`{"rateLimitsByLimitId":{"codex":{"secondary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":101}}}}`));
    assert(!grace(`{"rateLimits":{"limitId":"codex","primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":100}}}`));
    assert(!grace(`{"rateLimits":{"limitId":"codex","primary":{"usedPercent":99,"windowDurationMins":10080,"resetsAt":101}}}`));
    assert(!grace(`{"rateLimits":{"limitId":"codex","primary":{"usedPercent":99,"resetsAt":101}}}`));
    assert(!grace(`{"rateLimits":{"limitId":"codex","primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":null}}}`));
    assert(!grace(`{"rateLimits":{"limitId":"other","primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":101}}}`));
    assert(!grace(`{"rateLimitsByLimitId":{},"rateLimits":{"limitId":"codex","primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":101}}}`));
}
