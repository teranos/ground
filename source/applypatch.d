module applypatch;

// codex edits files through apply_patch: one patch, any number of files, each
// added, updated (and perhaps moved), or deleted. Ground answers it a file at
// a time, as the Write or Edit Claude Code would have sent for that file.

struct PatchFile {
    const(char)[] tool; // Write for an added or deleted file, Edit for an updated one
    const(char)[] path; // as the patch names it, which may be relative
    size_t from, to;    // the file's lines in the patch, its header left out
}

private const(char)[] after(const(char)[] line, string head) {
    if (line.length <= head.length || line[0 .. head.length] != head) return null;
    return line[head.length .. $];
}

private const(char)[] lineAt(const(char)[] patch, ref size_t pos) {
    auto end = pos;
    while (end < patch.length && patch[end] != '\n') end++;
    auto line = patch[pos .. end];
    pos = end < patch.length ? end + 1 : end;
    return line;
}

// The next file in the patch, from pos on, and pos moved past it. false when
// no file is left.
bool nextFile(const(char)[] patch, ref size_t pos, ref PatchFile f) {
    while (pos < patch.length) {
        auto line = lineAt(patch, pos);
        const(char)[] p;
        if ((p = after(line, "*** Add File: ")) !is null) f.tool = "Write";
        else if ((p = after(line, "*** Update File: ")) !is null) f.tool = "Edit";
        else if ((p = after(line, "*** Delete File: ")) !is null) f.tool = "Write";
        else continue;
        f.path = p;
        f.from = pos;
        while (pos < patch.length) {
            auto at = pos;
            auto l = lineAt(patch, pos);
            if (l.length >= 4 && l[0 .. 4] == "*** " && after(l, "*** Move to: ") is null) {
                pos = at;
                break;
            }
        }
        f.to = pos;
        return true;
    }
    return false;
}

// The lines the file's part adds, their + taken off: what an added file will
// hold, and what an update writes in. Empty for a delete.
const(char)[] addedText(const(char)[] patch, PatchFile f, char[] dest) {
    size_t n;
    auto pos = f.from;
    while (pos < f.to) {
        auto line = lineAt(patch, pos);
        if (line.length == 0 || line[0] != '+') continue;
        if (n > 0 && n < dest.length) dest[n++] = '\n';
        foreach (c; line[1 .. $]) if (n < dest.length) dest[n++] = c;
    }
    return dest[0 .. n];
}

// The patch a shell command hands apply_patch, quoted or as a heredoc, from
// its Begin to its End line; null for a command that is not apply_patch.
// codex runs that command itself, so it edits as the tool would.
const(char)[] shellPatch(const(char)[] command) {
    enum verb = "apply_patch";
    enum begin = "*** Begin Patch";
    enum end = "*** End Patch";
    if (command.length <= verb.length || command[0 .. verb.length] != verb) return null;
    auto c = command[verb.length];
    if (c != ' ' && c != '\n' && c != '\t') return null;
    size_t from = command.length;
    foreach (i; verb.length .. command.length) {
        if (i + begin.length <= command.length && command[i .. i + begin.length] == begin) { from = i; break; }
    }
    if (from == command.length) return null;
    foreach (i; from .. command.length) {
        if (i + end.length <= command.length && command[i .. i + end.length] == end)
            return command[from .. i + end.length];
    }
    return null;
}

// Where an update moves the file, or null.
const(char)[] movedTo(const(char)[] patch, PatchFile f) {
    auto pos = f.from;
    while (pos < f.to) {
        auto p = after(lineAt(patch, pos), "*** Move to: ");
        if (p !is null) return p;
    }
    return null;
}
