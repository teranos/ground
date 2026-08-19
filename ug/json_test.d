module json_test;

// CTFE tests — failure shows as a compile error.

import json : jsonString, baseName;

enum capture = import("captures/grove/in.json");

// Read out of the real payload, not a sample of one.
static assert(jsonString(capture, "cwd") == "/home/golem/SBVH/sbvh-nl/grove");
static assert(jsonString(capture, "session_id") == "95ceeb1e-71b4-4a07-9b3b-8c57464c65d7");

// A key that is not there is null rather than empty, so a caller can tell a
// missing field from a field carrying no characters.
static assert(jsonString(capture, "vim") is null);
static assert(jsonString("{}", "cwd") is null);

// The key has to be the whole key, and a key appearing inside a value is not
// the key.
static assert(jsonString(`{"a":"cwd","cwd":"x"}`, "cwd") == "x");
static assert(jsonString(`{"cwder":"no"}`, "cwd") is null);

// Escapes are left as written; nothing on the row needs them decoded yet.
static assert(jsonString(`{"k":"a\/b"}`, "k") == `a\/b`);

static assert(baseName("/home/golem/SBVH/sbvh-nl/grove") == "grove");
static assert(baseName("/a/b/") == "b");
static assert(baseName("grove") == "grove");
static assert(baseName("/") is null);
static assert(baseName("") is null);
