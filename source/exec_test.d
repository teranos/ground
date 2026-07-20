module exec_test;

import exec : mergeEnv, MergedEnv;

// mergeEnv layers control-declared env on top of project-declared env.
// Control wins on collision. Precedence rule from CLAUDE.md-adjacent
// design: control > project > GROUND_ floor (GROUND_ is prepended at
// runtime, not by this pure function).

// Both empty → empty result.
enum MergedEnv empty1 = mergeEnv([], [], [], []);
static assert(empty1.count == 0);

// Only project → returned unchanged.
enum MergedEnv onlyProj = mergeEnv([], [], ["port"], ["8770"]);
static assert(onlyProj.count == 1);
static assert(onlyProj.keys[0] == "port");
static assert(onlyProj.values[0] == "8770");

// Only control → returned unchanged.
enum MergedEnv onlyCtrl = mergeEnv(["target"], ["prod"], [], []);
static assert(onlyCtrl.count == 1);
static assert(onlyCtrl.keys[0] == "target");
static assert(onlyCtrl.values[0] == "prod");

// Disjoint keys → union. Project pairs first (they arrived first), control
// pairs appended after.
enum MergedEnv disjoint = mergeEnv(
    ["target"], ["prod"],
    ["port"], ["8770"],
);
static assert(disjoint.count == 2);
static assert(disjoint.keys[0] == "port");
static assert(disjoint.values[0] == "8770");
static assert(disjoint.keys[1] == "target");
static assert(disjoint.values[1] == "prod");

// Collision → control's value overwrites project's, position stays where
// project put it. count does not grow.
enum MergedEnv collision = mergeEnv(
    ["port"], ["9999"],
    ["port"], ["8770"],
);
static assert(collision.count == 1);
static assert(collision.keys[0] == "port");
static assert(collision.values[0] == "9999");
