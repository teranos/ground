module stamp_test;

import stamp : revStamp;

// 「[Opus 5.5] The commit an engine names is the one its tree is at: HEAD's whole id in a repository, and」
// 「[Opus 5.5] nothing in a tree that is none, whatever .rev it was copied with.」
static assert(revStamp(true, "0123456789abcdef0123456789abcdef01234567") == "0123456789abcdef0123456789abcdef01234567\n");
static assert(revStamp(true, null) == "");
static assert(revStamp(false, null) == "");
