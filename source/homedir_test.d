module homedir_test;

// CTFE tests — failure shows as a compile error.

import homedir : replaceAll, rewriteField, Rewrite;

enum FROM = "/Users/x";
enum TO = "/home/golem";

char[512] all(const(char)[] text)() {
    char[512] buf = 0;
    replaceAll(text, FROM, TO, buf[]);
    return buf;
}

Rewrite allR(const(char)[] text, const(char)[] from = FROM) {
    char[512] buf = 0;
    return replaceAll(text, from, TO, buf[]);
}

// The whole point: the string goes, the rest of the line stands.
enum one = "COLLET=/Users/x/bin/c";
enum oneWant = "COLLET=" ~ TO ~ "/bin/c";
static assert(allR(one).found == 1);
static assert(all!one()[0 .. oneWant.length] == oneWant);

// Every occurrence, not the first.
enum two = "a /Users/x/one b /Users/x/two";
enum twoWant = "a " ~ TO ~ "/one b " ~ TO ~ "/two";
static assert(allR(two).found == 2);
static assert(all!two()[0 .. twoWant.length] == twoWant);

// Nothing to replace comes back whole and says nothing happened.
static assert(allR("no path here").found == 0);
static assert(all!"no path here"()[0 .. 12] == "no path here");

// An empty needle matches everywhere or nowhere; nowhere is the safe reading.
static assert(allR("anything", "").found == 0);

// A destination too small is not a truncated answer, it is no answer: a Write
// cut short would land a truncated file on disk.
Rewrite tight(const(char)[] text, size_t room) {
    char[512] buf = 0;
    return replaceAll(text, FROM, TO, buf[0 .. room]);
}

static assert(!tight(one, 4).fit);
static assert(tight(one, 4).found == 0);
static assert(tight(one, 4).len == 0);
static assert(tight(one, oneWant.length).fit);

char[512] field(const(char)[] region, const(char)[] key)() {
    char[512] buf = 0;
    rewriteField(region, key, FROM, TO, buf[]);
    return buf;
}

Rewrite fieldR(const(char)[] region, const(char)[] key) {
    char[512] buf = 0;
    return rewriteField(region, key, FROM, TO, buf[]);
}

// The named field is rewritten and file_path is left exactly as it was, or the
// write lands somewhere the caller never asked for.
enum write = `{"file_path":"/Users/x/a.d","content":"x = \"/Users/x/b\";"}`;
enum writeWant = `{"file_path":"/Users/x/a.d","content":"x = \"` ~ TO ~ `/b\";"}`;
static assert(fieldR(write, "content").found == 1);
static assert(field!(write, "content")()[0 .. writeWant.length] == writeWant);

// A value carrying an escaped quote does not end at that quote.
enum quoted = `{"content":"say \"/Users/x\" out loud","z":1}`;
enum quotedWant = `{"content":"say \"` ~ TO ~ `\" out loud","z":1}`;
static assert(fieldR(quoted, "content").found == 1);
static assert(field!(quoted, "content")()[0 .. quotedWant.length] == quotedWant);

// Every other field survives byte for byte, including ones after the target.
enum edit = `{"file_path":"/Users/x/a.d","old_string":"p","new_string":"/Users/x/q","replace_all":true}`;
enum editWant = `{"file_path":"/Users/x/a.d","old_string":"p","new_string":"` ~ TO ~ `/q","replace_all":true}`;
static assert(field!(edit, "new_string")()[0 .. editWant.length] == editWant);

// A field that is not there, or a value with nothing to replace, changes
// nothing and reports nothing.
static assert(fieldR(write, "nope").found == 0);
static assert(fieldR(`{"content":"clean"}`, "content").found == 0);

// Too small for the object is no answer, same rule as above.
Rewrite tightField(const(char)[] region, size_t room) {
    char[512] buf = 0;
    return rewriteField(region, "content", FROM, TO, buf[0 .. room]);
}

static assert(!tightField(write, 10).fit);
static assert(tightField(write, 10).found == 0);
