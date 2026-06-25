module push_test;

import push : hasPathStartingWith;

// Empty input — no match.
static assert(!hasPathStartingWith("", "universe/"));

// Single-line match at line start.
static assert(hasPathStartingWith("universe/src/lib.rs\n", "universe/"));

// Single-line no match.
static assert(!hasPathStartingWith("roam/Cargo.toml\n", "universe/"));

// Multi-line — match anywhere in the list.
static assert(hasPathStartingWith("universe/src/lib.rs\nroam/Cargo.toml\n", "universe/"));
static assert(hasPathStartingWith("roam/Cargo.toml\nuniverse/src/lib.rs\n", "universe/"));

// Multi-line — none match.
static assert(!hasPathStartingWith("roam/Cargo.toml\nccg/x.rs\n", "universe/"));

// Substring inside path — must NOT match (prefix is line-anchored).
static assert(!hasPathStartingWith("docs/universe/about.md\n", "universe/"));

// No trailing newline on last line still works.
static assert(hasPathStartingWith("roam/Cargo.toml\nuniverse/src/lib.rs", "universe/"));

// All four monorepo subdirs.
static assert(hasPathStartingWith("relayer/src/main.rs\n", "relayer/"));
static assert(hasPathStartingWith("ccg/src/lib.rs\n", "ccg/"));
static assert(hasPathStartingWith("roam/src/lib.rs\n", "roam/"));
static assert(hasPathStartingWith("universe/src/lib.rs\n", "universe/"));
