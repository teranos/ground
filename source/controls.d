module controls;

public import hooks;
import proto : parsePbt, buildScopes, ScopeSet;
import permission : buildPermissions, PermissionSet;

// --- Parsed pbt (CTFE) ---
// Pre-build: cat controls/*.pbt > .ctfe/sand

enum allParsed = parsePbt(import(".ctfe/sand"));

// --- Handler resolvers (CTFE) ---

import control_handlers;

CheckFn resolveCheck(string name) {
    switch (name) {
        case "binaryShadowed": return &control_handlers.binaryShadowed;
        case "commitNotRequested": return &control_handlers.commitNotRequested;
        case "mergeNotRequested": return &control_handlers.mergeNotRequested;
        case "killNotRequested": return &control_handlers.killNotRequested;
        case "branchNotRequested": return &control_handlers.branchNotRequested;
        case "prNotRequested": return &control_handlers.prNotRequested;
        case "quoteProvenance": return &control_handlers.quoteProvenance;
        case "quoteStandsAlone": return &control_handlers.quoteStandsAlone;
        case "quoteChronology": return &control_handlers.quoteChronology;
        case "strikethrough": return &control_handlers.strikethroughCheck;
        case "unanalyzableBash": return &control_handlers.unanalyzableBash;
        case "deepAndChain": return &control_handlers.deepAndChain;
        default: return null;
    }
}

DelayFn resolveDelay(string name) {
    switch (name) {
        case "ciDelay": return &control_handlers.ciDelay;
        default: return null;
    }
}

DeliverFn resolveDeliver(string name) {
    switch (name) {
        case "upstreamBriefingDeliver": return &control_handlers.upstreamBriefingDeliver;
        default: return null;
    }
}

// --- Scope arrays (CTFE) ---

// TODO: catch hardcoded URLs in error messages that claim to report runtime values

private static immutable _preToolSet = buildScopes!(resolveCheck, resolveDelay, resolveDeliver)(allParsed, "PreToolUse");
static immutable allScopes = _preToolSet.items[0 .. _preToolSet.len];

private static immutable _upSet = buildScopes(allParsed, "UserPromptSubmit");
static immutable userPromptScopes = _upSet.items[0 .. _upSet.len];

private static immutable _stopSet = buildScopes!(resolveCheck, resolveDelay, resolveDeliver)(allParsed, "Stop");
static immutable stopScopes = _stopSet.items[0 .. _stopSet.len];

private static immutable _ssSet = buildScopes!(resolveCheck, resolveDelay, resolveDeliver)(allParsed, "SessionStart");
static immutable sessionStartScopes = _ssSet.items[0 .. _ssSet.len];

private static immutable _ptuSet = buildScopes(allParsed, "PostToolUse");
static immutable postToolUseScopes = _ptuSet.items[0 .. _ptuSet.len];

private static immutable _ptudSet = buildScopes!(resolveCheck, resolveDelay, resolveDeliver)(allParsed, "PostToolUseDeferred");
static immutable postToolUseDeferredScopes = _ptudSet.items[0 .. _ptudSet.len];

private static immutable _ptufSet = buildScopes(allParsed, "PostToolUseFailure");
static immutable postToolUseFailureScopes = _ptufSet.items[0 .. _ptufSet.len];

private static immutable _pcSet = buildScopes(allParsed, "PreCompact");
static immutable preCompactScopes = _pcSet.items[0 .. _pcSet.len];

private static immutable _permSet = buildPermissions(allParsed);
static immutable permissionScopes = _permSet.items[0 .. _permSet.len];

// Project file vocabulary — built at CTFE from project { files: [...] } blocks
import proto : extractProjectFiles;
private static immutable _projFiles = extractProjectFiles(allParsed);
static immutable projectFiles = _projFiles.files[0 .. _projFiles.len];

// Rites and rituals — built at CTFE from rites/ritual blocks.
// The validation runs here so a malformed ritual fails the build.
import proto : ParsedRites, ParsedRitual, validateRituals;
static immutable allRites = allParsed.rites[0 .. allParsed.ritesCount];
static immutable allRituals = allParsed.rituals[0 .. allParsed.ritualCount];
private enum _ritualCheck = validateRituals(allParsed).text();
static assert(_ritualCheck.length == 0, _ritualCheck);

// Informational, and the build carries on. pragma(msg) is how a CTFE value
// reaches a person without failing the compile.
import proto : warnRituals;
private enum _ritualWarn = warnRituals(allParsed).text();
static if (_ritualWarn.length > 0) pragma(msg, "ground: " ~ _ritualWarn);

// QNTX nodes and attestations — built at CTFE from qntx/attestation blocks
import proto : ParsedQntxNode, ParsedAttestation;
static immutable qntxNodes = allParsed.qntxNodes[0 .. allParsed.qntxNodeCount];
static immutable attestations = allParsed.attestations[0 .. allParsed.attestationCount];

// Global strop pool. Control.stropIdx is a 1-based index into this array.
// Only strop-using controls consume a slot — non-strop controls carry just
// an 8-byte size_t on Control instead of an embedded Strop.
import strop : Strop;
static immutable Strop[allParsed.stropPoolLen + 1] globalStropPool = () {
    Strop[allParsed.stropPoolLen + 1] pool;
    foreach (i; 0 .. allParsed.stropPoolLen) pool[i] = allParsed.stropPool[i];
    return pool;
}();

