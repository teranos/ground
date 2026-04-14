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
        case "strikethrough": return &control_handlers.strikethroughCheck;
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
        case "ciDeliver": return &control_handlers.ciDeliver;
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

// QNTX nodes and attestations — built at CTFE from qntx/attestation blocks
import proto : ParsedQntxNode, ParsedAttestation;
static immutable qntxNodes = allParsed.qntxNodes[0 .. allParsed.qntxNodeCount];
static immutable attestations = allParsed.attestations[0 .. allParsed.attestationCount];

