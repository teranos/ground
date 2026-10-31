module builtin_sand;

public import hooks;
import proto : parsePbt, buildScopes, ScopeSet;
import permission : buildPermissions, PermissionSet;

// --- Parsed pbt (CTFE) ---
// Pre-build: cat controls/*.pbt > .ctfe/sand

// "only the compiled controls being their own thing shipped to the user"

// The sand is data: a control names its handlers, and the engine that holds
// them resolves the name. Nothing here imports the engine.

import sandtext : SAND_TEXT;
enum allParsed = parsePbt(SAND_TEXT);

// The parse, held once. A function that reads it at run time names this one:
// a static immutable copy of allParsed in each function that wanted it was
// fifteen copies of the same ParseResult in the binary.
static immutable parsedOnce = allParsed;

// --- Handler names (CTFE) ---

import handler_names : checkNames, delayNames, deliverNames, named;

// A name the engine holds, by kind; handlers.d holds the code for each.
bool holds(string kind, string name) {
    if (kind == "check") return named(checkNames, name);
    if (kind == "delay") return named(delayNames, name);
    if (kind == "deliver") return named(deliverNames, name);
    return false;
}

// --- Scope arrays (CTFE) ---

// TODO: catch hardcoded URLs in error messages that claim to report runtime values

private static immutable _preToolSet = buildScopes!holds(allParsed, "PreToolUse");
static immutable allScopes = _preToolSet.items[0 .. _preToolSet.len];

private static immutable _upSet = buildScopes(allParsed, "UserPromptSubmit");
static immutable userPromptScopes = _upSet.items[0 .. _upSet.len];

private static immutable _stopSet = buildScopes!holds(allParsed, "Stop");
static immutable stopScopes = _stopSet.items[0 .. _stopSet.len];

private static immutable _ssSet = buildScopes!holds(allParsed, "SessionStart");
static immutable sessionStartScopes = _ssSet.items[0 .. _ssSet.len];

private static immutable _ptuSet = buildScopes(allParsed, "PostToolUse");
static immutable postToolUseScopes = _ptuSet.items[0 .. _ptuSet.len];

private static immutable _ptudSet = buildScopes!holds(allParsed, "PostToolUseDeferred");
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

// Route vocabulary — built at CTFE from the route blocks wind writes into a
// project that names its OpenAPI spec.
import proto : extractProjectRoutes;
private static immutable _projRoutes = extractProjectRoutes(allParsed);
static immutable projectRoutes = _projRoutes.routes[0 .. _projRoutes.len];

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

// Attestations and where each is posted — built at CTFE from the attestation
// blocks and the qntx: of the projects. An attestation inside a project that
// names no backend fails the build here, naming itself.
import proto : ParsedAttestation;
import backend : postings, unbacked;
static immutable attestations = allParsed.attestations[0 .. allParsed.attestationCount];
private enum _unbacked = unbacked(allParsed);
static assert(_unbacked.length == 0,
    "attestation " ~ _unbacked ~ " sits in a project that names no qntx: backend");
private static immutable _postings = postings(allParsed);
static immutable postingList = _postings.items[0 .. _postings.len];

// Where a place reports. Only the paths and the dsns are kept: a second static
// copy of the whole parse costs the binary the parse again, for two strings.
import proto : ParsedSentry, ParsedOrg, validateOrgs;

// A project names an org that exists, or the build says which one does not.
private enum _orgCheck = validateOrgs(allParsed).text();
static assert(_orgCheck.length == 0, _orgCheck);

static immutable allOrgs = allParsed.orgs[0 .. allParsed.orgCount];

// The one node, as the top-level qntx block names it. url empty is no node.
import proto : ParsedQntx;
static immutable ParsedQntx qntxNode = allParsed.qntx;

// Global strop pool. Control.stropIdx is a 1-based index into this array.
// Only strop-using controls consume a slot — non-strop controls carry just
// an 8-byte size_t on Control instead of an embedded Strop.
import strop : Strop;
static immutable Strop[allParsed.stropPoolLen + 1] globalStropPool = () {
    Strop[allParsed.stropPoolLen + 1] pool;
    foreach (i; 0 .. allParsed.stropPoolLen) pool[i] = allParsed.stropPool[i];
    return pool;
}();

// --- The sand, as the engine and a sand library both hand it over ---

import sandview : Sand, viewOf, SAND_ABI;

static immutable Sand builtinSand = Sand(SAND_ABI, viewOf(parsedOnce),
    allScopes, userPromptScopes, stopScopes, sessionStartScopes, postToolUseScopes,
    postToolUseDeferredScopes, postToolUseFailureScopes, preCompactScopes, permissionScopes,
    projectFiles, projectRoutes, postingList, globalStropPool[]);
