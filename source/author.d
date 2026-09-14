module author;

// "and it should be called ground author"
// The author's tool serves the book's cases for editing and writes what was
// typed back into the module each came from. It is std.socket and the GC,
// which this binary cannot carry, so the command builds it and hands over.

import core.stdc.stdio : fputs, stderr;
import core.stdc.stdlib : system;

extern (C) int execv(const(char)* path, const(char)** argv);
extern (C) int access(const(char)* path, int mode);

enum BOOK_COMMAND = q"EOS
# the author's tool, in the ground checkout: every case editable in a browser
ground author
EOS";

int handleAuthor() {
    if (access("tools/editor.d", 0) != 0) {
        fputs("ground author: run it in the ground checkout, where tools/editor.d is\n", stderr);
        return 1;
    }
    auto built = system("make editor");
    if (built != 0) {
        fputs("ground author: make editor failed\n", stderr);
        return 1;
    }
    const(char)*[2] argv = ["./tools/editor".ptr, null];
    execv("./tools/editor", argv.ptr);
    fputs("ground author: could not start tools/editor\n", stderr);
    return 1;
}
