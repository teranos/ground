module exec_test;

import exec : mergeEnv, MergedEnv;

// mergeEnv layers control-declared env on top of project-declared env.
// Control wins on collision. Precedence rule: control > project > GROUND_
// floor (GROUND_ is prepended at runtime, not by this pure function).
//
// Env var keys are UPPER_CASE by convention (they become real env vars in
// the child process). The parser doesn't enforce this — it's a doc rule.

// Both empty → empty result.
enum MergedEnv empty1 = mergeEnv([], [], [], []);
static assert(empty1.count == 0);

// Only project → returned unchanged.
enum MergedEnv onlyProj = mergeEnv([], [], ["PORT"], ["8770"]);
static assert(onlyProj.count == 1);
static assert(onlyProj.keys[0] == "PORT");
static assert(onlyProj.values[0] == "8770");

// Only control → returned unchanged.
enum MergedEnv onlyCtrl = mergeEnv(["TARGET"], ["prod"], [], []);
static assert(onlyCtrl.count == 1);
static assert(onlyCtrl.keys[0] == "TARGET");
static assert(onlyCtrl.values[0] == "prod");

// Disjoint keys → union. Project pairs first (they arrived first), control
// pairs appended after.
enum MergedEnv disjoint = mergeEnv(
    ["TARGET"], ["prod"],
    ["PORT"], ["8770"],
);
static assert(disjoint.count == 2);
static assert(disjoint.keys[0] == "PORT");
static assert(disjoint.values[0] == "8770");
static assert(disjoint.keys[1] == "TARGET");
static assert(disjoint.values[1] == "prod");

// Collision → control's value overwrites project's, position stays where
// project put it. count does not grow.
enum MergedEnv collision = mergeEnv(
    ["PORT"], ["9999"],
    ["PORT"], ["8770"],
);
static assert(collision.count == 1);
static assert(collision.keys[0] == "PORT");
static assert(collision.values[0] == "9999");

// --- prepareChildEnv ---
// Extends mergeEnv with the GROUND_ floor: session id, cwd, tool input
// JSON. GROUND_ vars come first (positions 0..2), then merged (project +
// control) pairs. Never fewer than 3 entries — the floor is guaranteed.
import exec : prepareChildEnv, ChildEnv;

enum ChildEnv floorOnly = prepareChildEnv(
    [], [], [], [],
    "sid-xyz", "/tmp/cwd", "{}"
);
static assert(floorOnly.count == 3);
static assert(floorOnly.keys[0] == "GROUND_SESSION_ID");
static assert(floorOnly.values[0] == "sid-xyz");
static assert(floorOnly.keys[1] == "GROUND_CWD");
static assert(floorOnly.values[1] == "/tmp/cwd");
static assert(floorOnly.keys[2] == "GROUND_TOOL_INPUT");
static assert(floorOnly.values[2] == "{}");

// Floor + project env only.
enum ChildEnv withProj = prepareChildEnv(
    [], [], ["PORT"], ["8770"],
    "s", "/c", "in"
);
static assert(withProj.count == 4);
static assert(withProj.keys[3] == "PORT");
static assert(withProj.values[3] == "8770");

// Floor + control env, collision with project (control still wins).
enum ChildEnv withMerge = prepareChildEnv(
    ["PORT"], ["9999"],
    ["PORT"], ["8770"],
    "s", "/c", "in"
);
static assert(withMerge.count == 4);
static assert(withMerge.keys[3] == "PORT");
static assert(withMerge.values[3] == "9999");
