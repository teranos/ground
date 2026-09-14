module fmtcmd_test;

// ground fmt on a .d file sets the backtick fixtures that are pbt and
// touches nothing else in the file.

import fmtcmd : formatLiterals;

struct Set {
    char[4096] buf = 0;
    char[4096] scratch = 0;
    size_t len;
    const(char)[] text() const return { return buf[0 .. len]; }
}

Set setLiterals(const(char)[] src) {
    Set s;
    auto n = formatLiterals(src, s.buf[], s.scratch[]);
    s.len = n < 0 ? 0 : cast(size_t) n;
    return s;
}

// A one-line fixture is set the way fmt sets it, between its own backticks,
// and the D around it is as it was.
enum before = "enum x = `rites a { one { eval: \"true\" } }`;\nstatic assert(x.length > 0);\n";
enum after = "enum x = `rites a {\n  one {\n    eval: \"true\"\n  }\n}`;\nstatic assert(x.length > 0);\n";
static assert(setLiterals(before).text() == after);

// A fixture opening on the line after its backtick keeps that line.
enum led = "enum x = `\nscope { path: \"/\" }\n`;\n";
static assert(setLiterals(led).text() == "enum x = `\nscope {\n  path: \"/\"\n}\n`;\n");

// A pair of backticks in a comment is prose, whatever stands between them.
// Reading one as a fixture rewrote the comment into code.
enum commented = "// Same shape as `project { env { x } }`, but on a control.\nenum y = 1;\n";
static assert(setLiterals(commented).text() == commented);

// A backtick literal that is not pbt is not touched: a rite's command.
enum command = "enum c = `make parity | grep \"$row\"`;\n";
static assert(setLiterals(command).text() == command);
