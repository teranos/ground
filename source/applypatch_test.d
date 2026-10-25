module applypatch_test;

import applypatch : PatchFile, nextFile, addedText, movedTo;

// What codex 0.163.0 sent ground for a file it created with apply_patch.
enum add = "*** Begin Patch\n*** Add File: /r/notes.txt\n+hello\n+world\n*** End Patch";

static assert(() {
    size_t pos;
    PatchFile f;
    char[64] b;
    return nextFile(add, pos, f) && f.tool == "Write" && f.path == "/r/notes.txt"
        && addedText(add, f, b[]) == "hello\nworld" && movedTo(add, f) is null
        && !nextFile(add, pos, f);
}());

// One patch, three files: an update moved elsewhere, a delete, an add.
enum three = "*** Begin Patch\n"
    ~ "*** Update File: src/a.d\n*** Move to: src/b.d\n@@ fn\n keep\n-old\n+new\n"
    ~ "*** Delete File: gone.bin\n"
    ~ "*** Add File: c.txt\n+c\n"
    ~ "*** End Patch";

static assert(() {
    size_t pos;
    PatchFile f;
    char[64] b;
    if (!nextFile(three, pos, f) || f.tool != "Edit" || f.path != "src/a.d") return false;
    if (addedText(three, f, b[]) != "new" || movedTo(three, f) != "src/b.d") return false;
    if (!nextFile(three, pos, f) || f.tool != "Write" || f.path != "gone.bin") return false;
    if (addedText(three, f, b[]).length != 0) return false;
    if (!nextFile(three, pos, f) || f.tool != "Write" || f.path != "c.txt") return false;
    if (addedText(three, f, b[]) != "c") return false;
    return !nextFile(three, pos, f);
}());
