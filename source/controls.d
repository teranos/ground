module controls;

// "but the floor is always the same, everyonne get;s the same nice things by default. but you get way more with the real sand"

// The engine reads every control from the sand it holds: the built-in one,
// or the one that landed for this repository when its ABI is the engine's.

public import hooks;
import sand.view : Sand, ParsedView;
import permission : PermissionScope;
import proto : ParsedRites, ParsedRitual, ParsedAttestation, ParsedOrg, ParsedRoute, ParsedQntx;
import backend : Posting;
import strop : Strop;
import sand.builtin : builtinSand;

// Compile-time readers (checks.d, playbill.d) read the floor's parse, as they always did.
public import sand.builtin : allParsed, holds;

private __gshared const(Sand)* landed = &builtinSand;
private __gshared bool heldOnce = false;

// "why isnt everything that needs sand loading it."
// 「[Opus 5.5] The first read in a process holds the landed sand, so no process can read the」
// 「[Opus 5.5] floor by forgetting to ask. A unittest reads the floor it was built with.」
private const(Sand)* held() {
    version (unittest) {} else {
        if (!heldOnce) {
            heldOnce = true;
            import sand.load : holdLandedHere;
            holdLandedHere();
        }
    }
    return landed;
}

const(Sand)* sand() { return held; }

// What the engine answers from from here on; null is the built-in sand again.
void holdSand(const(Sand)* s) {
    heldOnce = true;
    landed = s is null ? &builtinSand : s;
}

ref const(ParsedView) parsedOnce() { return held.parsed; }
const(Scope)[] allScopes() { return held.preToolUse; }
const(Scope)[] userPromptScopes() { return held.userPrompt; }
const(Scope)[] stopScopes() { return held.stop; }
const(Scope)[] sessionStartScopes() { return held.sessionStart; }
const(Scope)[] postToolUseScopes() { return held.postToolUse; }
const(Scope)[] postToolUseDeferredScopes() { return held.postToolUseDeferred; }
const(Scope)[] postToolUseFailureScopes() { return held.postToolUseFailure; }
const(Scope)[] preCompactScopes() { return held.preCompact; }
const(PermissionScope)[] permissionScopes() { return held.permission; }
const(string)[] projectFiles() { return held.projectFiles; }
const(ParsedRoute)[] projectRoutes() { return held.projectRoutes; }
const(ParsedRites)[] allRites() { return held.parsed.rites; }
const(ParsedRitual)[] allRituals() { return held.parsed.rituals; }
const(ParsedAttestation)[] attestations() { return held.parsed.attestations; }
const(Posting)[] postingList() { return held.postings; }
const(ParsedOrg)[] allOrgs() { return held.parsed.orgs; }
ref const(ParsedQntx) qntxNode() { return held.parsed.qntx; }
const(Strop)[] globalStropPool() { return held.stropPool; }

const(char)[] dsnHere(const(char)[] cwd) {
    import ritual.resolve : dsnAt;
    return dsnAt(held.parsed, cwd);
}
