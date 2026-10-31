module sandview;

// "A comet is one sand for one user, one project and one platform."

// What crosses between an engine and a sand built apart from it: slices of
// types whose layout no control changes. A ParseResult is sized by its controls.

import hooks : Scope, Control;
import permission : PermissionScope, Permission;
import proto : ParsedRites, ParsedRitual, ParsedScope, ParsedControl, ParsedPermission,
    ParsedProject, ParsedEnv, ParsedRoute, ParsedAttestation, ParsedModels, ParsedSentry,
    ParsedQntx, ParsedOrg;
import strop : Strop;
import backend : Posting;

// The parse, as the engine reads it at run time: each array the slice of what was parsed.
struct ParsedView {
    const(ParsedRites)[] rites;
    size_t ritesCount;
    const(ParsedRitual)[] rituals;
    size_t ritualCount;
    const(ParsedScope)[] scopes;
    size_t scopeCount;
    const(ParsedControl)[] ctrlPool;
    size_t ctrlPoolLen;
    const(ParsedPermission)[] permPool;
    size_t permPoolLen;
    const(ParsedProject)[] projects;
    size_t projectCount;
    const(ParsedEnv)[] envs;
    size_t envCount;
    const(ParsedRoute)[] routes;
    size_t routeCount;
    const(ParsedAttestation)[] attestations;
    size_t attestationCount;
    const(Strop)[] stropPool;
    size_t stropPoolLen;
    ParsedModels models;
    ParsedSentry sentry;
    ParsedQntx qntx;
    const(ParsedOrg)[] orgs;
    size_t orgCount;
}

ParsedView viewOf(PR)(ref immutable PR r) {
    return ParsedView(
        r.rites[0 .. r.ritesCount], r.ritesCount,
        r.rituals[0 .. r.ritualCount], r.ritualCount,
        r.scopes[0 .. r.scopeCount], r.scopeCount,
        r.ctrlPool[0 .. r.ctrlPoolLen], r.ctrlPoolLen,
        r.permPool[0 .. r.permPoolLen], r.permPoolLen,
        r.projects[0 .. r.projectCount], r.projectCount,
        r.envs[0 .. r.envCount], r.envCount,
        r.routes[0 .. r.routeCount], r.routeCount,
        r.attestations[0 .. r.attestationCount], r.attestationCount,
        r.stropPool[0 .. r.stropPoolLen], r.stropPoolLen,
        r.models, r.sentry, r.qntx,
        r.orgs[0 .. r.orgCount], r.orgCount);
}

// Everything a sand gives the engine, each set of scopes by the event that collects it.
struct Sand {
    ulong abi;
    ParsedView parsed;
    const(Scope)[] preToolUse;
    const(Scope)[] userPrompt;
    const(Scope)[] stop;
    const(Scope)[] sessionStart;
    const(Scope)[] postToolUse;
    const(Scope)[] postToolUseDeferred;
    const(Scope)[] postToolUseFailure;
    const(Scope)[] preCompact;
    const(PermissionScope)[] permission;
    const(string)[] projectFiles;
    const(ParsedRoute)[] projectRoutes;
    const(Posting)[] postings;
    const(Strop)[] stropPool;
}

// The layout of every type that crosses, field by field, folded to one number at compile time.
private string layoutOf(T)() {
    import std.conv : to;
    string s = T.stringof ~ ":" ~ to!string(T.sizeof) ~ "{";
    static foreach (i, field; T.tupleof)
        s ~= __traits(identifier, field) ~ "@" ~ to!string(T.tupleof[i].offsetof) ~ ":"
            ~ typeof(field).stringof ~ ";";
    return s ~ "}";
}

private ulong fnv1a(string s) {
    ulong h = 0xcbf29ce484222325;
    foreach (c; s) {
        h ^= cast(ubyte) c;
        h *= 0x100000001b3;
    }
    return h;
}

enum SAND_ABI = fnv1a(layoutOf!Sand ~ layoutOf!ParsedView ~ layoutOf!Scope ~ layoutOf!Control
    ~ layoutOf!PermissionScope ~ layoutOf!Permission ~ layoutOf!ParsedRites ~ layoutOf!ParsedRitual
    ~ layoutOf!ParsedScope ~ layoutOf!ParsedControl ~ layoutOf!ParsedPermission ~ layoutOf!ParsedProject
    ~ layoutOf!ParsedEnv ~ layoutOf!ParsedRoute ~ layoutOf!ParsedAttestation ~ layoutOf!ParsedModels
    ~ layoutOf!ParsedSentry ~ layoutOf!ParsedQntx ~ layoutOf!ParsedOrg ~ layoutOf!Strop ~ layoutOf!Posting);
