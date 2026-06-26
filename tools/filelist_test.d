module filelist_test;

// CTFE tests for renderFileList — the pure formatting helper that
// renders a list of project file paths into the wind's `files: [...]`
// block content. Failure shows as compile error from static_assert.

import filelist : renderFileList;

// Single file
enum single = renderFileList(["foo.d"]);
static assert(single == `    "foo.d"`);

// Two files — comma + newline + four-space indent between entries
enum two = renderFileList(["a.d", "b/c.d"]);
static assert(two == "    \"a.d\",\n    \"b/c.d\"");

// Three files — same shape
enum three = renderFileList(["a", "b", "c"]);
static assert(three == "    \"a\",\n    \"b\",\n    \"c\"");

// Empty input — empty output (no leading/trailing whitespace)
enum empty = renderFileList([]);
static assert(empty == "");
