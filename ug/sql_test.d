module sql_test;

// CTFE tests — failure shows as a compile error.

import sql : dbPathInto, PERFORMANCE_SQL, MAX_PERFORMANCES;
import sql : NEWS_SQL, NEWS_SEEN_SQL, newsIdInto, newsContextsInto, newsPredicates;

// The item the node left is written once whatever the poll count: the id is
// the node's, prefixed so it cannot collide with the row that caused it.
static assert(contains(NEWS_SQL, "INSERT OR IGNORE"));
static assert(contains(NEWS_SEEN_SQL, "SELECT 1 FROM attestations WHERE id = ?1"));
static assert(newsPredicates == `["immediate:news"]`);

char[160] idOf(const(char)[] id)() {
    char[160] buf = 0;
    newsIdInto(id, buf[]);
    return buf;
}
static assert(idOf!("ground:ci-status:s1:002f1ea")()[0 .. 34] == "immediate:news:ground:ci-status:s1");

// Addressed to the session that pushed when the node says which; to the
// project when it does not, so every session there hears it.
char[256] ctxOf(const(char)[] session, const(char)[] repo)() {
    char[256] buf = 0;
    newsContextsInto(session, repo, buf[]);
    return buf;
}
static assert(ctxOf!("sess-1", "teranos/ground")()[0 .. 18] == `["session:sess-1"]`);
static assert(ctxOf!("", "teranos/ground")()[0 .. 26] == `["project:teranos/ground"]`);

// The read stops at MAX_PERFORMANCES, so the order decides which ones a frame
// can ever see. Oldest first meant the eight taken were the eight most expired
// and the live performance, always last, was never read at all.
static assert(contains(PERFORMANCE_SQL, "ORDER BY updated_at DESC"));

// Ordering on the id sorts ritual names, not time: `willow` outranks
// `q-deploy` whatever hour either ran.
static assert(!contains(PERFORMANCE_SQL, "ORDER BY id"));

private bool contains(const(char)[] haystack, const(char)[] needle) {
    if (needle.length > haystack.length) return false;
    foreach (i; 0 .. haystack.length - needle.length + 1)
        if (haystack[i .. i + needle.length] == needle) return true;
    return false;
}

char[128] built(const(char)[] home)() {
    char[128] buf = 0;
    dbPathInto(home, buf[]);
    return buf;
}

enum want = "/Users/x/.local/share/ground/ground.db";
static assert(dbPathInto("/Users/x", new char[128]) == want.length);
static assert(built!"/Users/x"()[0 .. want.length] == want);

// A HOME that already ends in a separator does not produce a doubled one.
static assert(built!"/Users/x/"()[0 .. want.length] == want);

// The path is written with a terminating zero, because sqlite3_open_v2 takes
// a C string and a slice is not one.
static assert(built!"/Users/x"()[want.length] == 0);

// Nowhere to look is nothing, rather than a path rooted at the filesystem.
static assert(dbPathInto("", new char[128]) == 0);
