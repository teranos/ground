module controls;

public import hooks;
import proto : parsePbt, buildScopes, ScopeSet, mergeScopes;

static if (__traits(compiles, { import qntx; }))
    import qntx;

version (OSX)
    import macos;

// --- Parsed pbt (CTFE) ---

enum baseParsed = parsePbt(import("controls/controls.pbt"));

// --- Handler resolvers (CTFE) ---

CheckFn resolveCheck(string name) {
    switch (name) {
        case "binaryShadowed": return &binaryShadowed;
        case "controlsAreStale": return &controlsAreStale;
        default: return null;
    }
}

DelayFn resolveDelay(string name) {
    switch (name) {
        case "ciDelay": return &ciDelay;
        default: return null;
    }
}

DeliverFn resolveDeliver(string name) {
    switch (name) {
        case "ciDeliver": return &ciDeliver;
        default: return null;
    }
}

// --- Scope arrays (CTFE) ---
// Two-step: build ScopeSet (by value, no escape), then slice the static immutable.

// TODO: catch hardcoded URLs in error messages that claim to report runtime values

// PreToolUse
private static immutable _preToolBase = buildScopes!(resolveCheck, resolveDelay, resolveDeliver)(baseParsed, "PreToolUse");

static if (__traits(compiles, macos.macosScopes))
    private static immutable _preToolMacos = macos.macosScopes;
static if (__traits(compiles, qntx.qntxScopes))
    private static immutable _preToolQntx = qntx.qntxScopes;

static if (__traits(compiles, _preToolQntx) && __traits(compiles, _preToolMacos)) {
    private static immutable _preToolMerged = mergeScopes(&_preToolBase, &_preToolMacos, &_preToolQntx);
    static immutable allScopes = _preToolMerged.items[0 .. _preToolMerged.len];
} else static if (__traits(compiles, _preToolQntx)) {
    private static immutable _preToolMerged = mergeScopes(&_preToolBase, &_preToolQntx);
    static immutable allScopes = _preToolMerged.items[0 .. _preToolMerged.len];
} else static if (__traits(compiles, _preToolMacos)) {
    private static immutable _preToolMerged = mergeScopes(&_preToolBase, &_preToolMacos);
    static immutable allScopes = _preToolMerged.items[0 .. _preToolMerged.len];
} else {
    static immutable allScopes = _preToolBase.items[0 .. _preToolBase.len];
}

// PreToolUseFile
static if (__traits(compiles, qntx.qntxFileScopes)) {
    private static immutable _fileSet = qntx.qntxFileScopes;
    static immutable fileScopes = _fileSet.items[0 .. _fileSet.len];
} else {
    static immutable Scope[] fileScopes = [];
}

// UserPromptSubmit
private static immutable _upBase = buildScopes(baseParsed, "UserPromptSubmit");

static if (__traits(compiles, macos.macosUserPromptScopes))
    private static immutable _upMacos = macos.macosUserPromptScopes;
static if (__traits(compiles, qntx.qntxUserPromptScopes))
    private static immutable _upQntx = qntx.qntxUserPromptScopes;

static if (__traits(compiles, _upQntx) && __traits(compiles, _upMacos)) {
    private static immutable _upMerged = mergeScopes(&_upBase, &_upMacos, &_upQntx);
    static immutable userPromptScopes = _upMerged.items[0 .. _upMerged.len];
} else static if (__traits(compiles, _upQntx)) {
    private static immutable _upMerged = mergeScopes(&_upBase, &_upQntx);
    static immutable userPromptScopes = _upMerged.items[0 .. _upMerged.len];
} else static if (__traits(compiles, _upMacos)) {
    private static immutable _upMerged = mergeScopes(&_upBase, &_upMacos);
    static immutable userPromptScopes = _upMerged.items[0 .. _upMerged.len];
} else {
    static immutable userPromptScopes = _upBase.items[0 .. _upBase.len];
}

// Stop
private static immutable _stopSet = buildScopes(baseParsed, "Stop");
static immutable stopScopes = _stopSet.items[0 .. _stopSet.len];

// SessionStart
private static immutable _ssSet = buildScopes!(resolveCheck)(baseParsed, "SessionStart");
static immutable sessionStartScopes = _ssSet.items[0 .. _ssSet.len];

// PostToolUse
private static immutable _ptuSet = buildScopes(baseParsed, "PostToolUse");
static immutable postToolUseScopes = _ptuSet.items[0 .. _ptuSet.len];

// PostToolUseDeferred
private static immutable _ptudSet = buildScopes!(resolveCheck, resolveDelay, resolveDeliver)(baseParsed, "PostToolUseDeferred");
static immutable postToolUseDeferredScopes = _ptudSet.items[0 .. _ptudSet.len];

// PostToolUseFailure
private static immutable _ptufSet = buildScopes(baseParsed, "PostToolUseFailure");
static immutable postToolUseFailureScopes = _ptufSet.items[0 .. _ptufSet.len];

// PreCompact
private static immutable _pcBase = buildScopes(baseParsed, "PreCompact");

static if (__traits(compiles, qntx.qntxPreCompactScopes)) {
    private static immutable _pcQntx = qntx.qntxPreCompactScopes;
    private static immutable _pcMerged = mergeScopes(&_pcBase, &_pcQntx);
    static immutable preCompactScopes = _pcMerged.items[0 .. _pcMerged.len];
} else {
    static immutable preCompactScopes = _pcBase.items[0 .. _pcBase.len];
}

// --- Handler functions ---

int ciDelay(const(char)[] cwd) {
    import deferred : getCIAvgDuration, computeDelay;
    import sqlite : getBranch;
    auto branch = getBranch(cwd);
    if (branch is null) return 60;
    return computeDelay(getCIAvgDuration(cwd, branch));
}

const(char)[] ciDeliver(const(char)[] cwd) {
    import deferred : checkCIStatus;
    import sqlite : getBranch;
    auto branch = getBranch(cwd);
    if (branch is null) return null;
    return checkCIStatus(cwd, branch);
}

// --- Check functions for sessionstart() controls ---

extern (C) int access(const(char)* path, int mode);
import core.stdc.stdio : FILE, fopen, fread, fclose;

bool binaryShadowed(const(char)[] cwd) {
    enum F_OK = 0;
    return access("/usr/local/bin/graunde\0".ptr, F_OK) == 0;
}

uint fnv1a(const(char)[] data) {
    uint h = 2166136261;
    foreach (b; data) { h ^= b; h *= 16777619; }
    return h;
}

enum CONTROLS_HASH = fnv1a(
    import("controls/controls.pbt")
    ~ import("controls/qntx.pbt")
    ~ import("controls/macos.pbt")
    ~ import("source/proto.d")
);

bool controlsAreStale(const(char)[] cwd) {
    if (cwd is null || cwd.length == 0) return false;

    __gshared char[4096] pathBuf;
    __gshared char[131072] concat;
    size_t total = 0;

    static foreach (suffix; [
        "/controls/controls.pbt",
        "/controls/qntx.pbt",
        "/controls/macos.pbt",
        "/source/proto.d",
    ]) {{
        if (cwd.length + suffix.length + 1 > pathBuf.length) return false;
        foreach (j, c; cwd) pathBuf[j] = c;
        foreach (j, c; suffix) pathBuf[cwd.length + j] = c;
        pathBuf[cwd.length + suffix.length] = 0;

        auto f = fopen(&pathBuf[0], "r");
        if (f is null) return false;
        auto n = fread(&concat[total], 1, concat.length - total, f);
        fclose(f);
        if (n == 0) return false;
        total += n;
    }}

    return fnv1a(concat[0 .. total]) != CONTROLS_HASH;
}
