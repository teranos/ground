module git_test;

// CTFE tests — failure shows as a compile error.

import git : branchOf;

// What git writes for a checked-out branch, newline and all.
static assert(branchOf("ref: refs/heads/ref-test\n") == "ref-test");
static assert(branchOf("ref: refs/heads/underground\n") == "underground");
static assert(branchOf("ref: refs/heads/main") == "main");

// A branch name may carry slashes of its own, and all of them belong to it.
static assert(branchOf("ref: refs/heads/feature/one/two\n") == "feature/one/two");

// Detached: a hash names no branch.
static assert(branchOf("2169cab9e0f1a2b3c4d5e6f708192a3b4c5d6e7f\n") is null);
static assert(branchOf("") is null);
static assert(branchOf("ref: refs/heads/\n") is null);
