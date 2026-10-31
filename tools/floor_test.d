module floor_test;

// "but the floor is always the same, everyonne get;s the same nice things by default. but you get way more with the real sand"

import floor : floorNames;

// The floor is ground's tracked controls/*.pbt, in name order: nothing a machine keeps beside them.
static assert(floorNames(["controls.pbt", "mine.pbt", "permissions.pbt", "notes.txt"],
    ["controls/permissions.pbt", "controls/controls.pbt", "controls/local/.gitkeep", "controls/controls.d", "README.md"],
    true) == ["controls.pbt", "permissions.pbt"]);

// A tree that is no repository holds only what was tracked: a flake's source, or a node's tarball.
static assert(floorNames(["permissions.pbt", "controls.pbt", "notes.txt"], null, false)
    == ["controls.pbt", "permissions.pbt"]);
