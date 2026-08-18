module binary_test;

import proto : parsePbt, buildScopes;
import binary : binaryGateApplies;

// A repo whose content IS the binaries declares itself. Everywhere else the
// gate stands, including when no pbt says anything at all.
enum contentInput = `
scope {
  path: "/dossier"
  event: "PreToolUse"
  control {
    name: "binaries-are-content"
    msg: "This repo exists to hold the documents themselves."
  }
}
`;
enum contentParsed = parsePbt(contentInput);
enum contentScopes = buildScopes(contentParsed, "PreToolUse");

static assert(binaryGateApplies(contentScopes[], "/home/me/dossier") == false);
static assert(binaryGateApplies(contentScopes[], "/home/me/dossier/nested") == false);
static assert(binaryGateApplies(contentScopes[], "/home/me/app") == true);

// checkGitAddForBinary asks this once per segment, against the cwd a `cd`
// segment put in force, so reaching out of the dossier answers on the target.
static assert(binaryGateApplies(contentScopes[], "nested") == true);

// Fails closed. An empty control set is not an exemption, it is the absence
// of one, so deleting the pbt above turns the gate back on rather than off.
enum silentInput = `
scope {
  path: "/dossier"
  event: "PreToolUse"
  control {
    name: "unrelated"
    cmd: "make"
    msg: "something else entirely"
  }
}
`;
enum silentParsed = parsePbt(silentInput);
enum silentScopes = buildScopes(silentParsed, "PreToolUse");

static assert(binaryGateApplies(silentScopes[], "/home/me/dossier") == true);
