module filelist;

// Pure formatting helper — renders a list of project-relative paths into
// the body of wind's `files: [...]` block.
//
// Format:
//   `    "a",\n    "b",\n    "c"`
//
// Wind wraps this in `  files: [\n` ... `\n  ]\n` when injecting into the
// project block. Empty input → empty output (no entries to render).

string renderFileList(const(string)[] paths) {
    string result;
    foreach (i, p; paths) {
        if (i > 0) result ~= ",\n";
        result ~= "    \"" ~ p ~ "\"";
    }
    return result;
}
