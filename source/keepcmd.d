module keepcmd;

// ground keep: every line of every transcript under ~/.claude/projects, main and
// subagent, kept as an attestation for the sky to stream to the node; then what
// was kept, file by file against its bytes on disk. Exit 1 when a file's lines
// were not all kept, or what was kept is not what the file holds.
// "i dont want to come back, and find out i missed something"

import core.stdc.stdio : stderr, stdout, fputs, fprintf;

enum BOOK_COMMAND = q"EOS
# every transcript's lines kept, and each file checked against what was kept:
ground keep
EOS";

int handleKeep() {
    import db : openDb, sqlite3_close;
    import transcript : keepAll, projectsRoot, provenAll;

    auto db = openDb();
    if (db is null) { fputs("ground keep: the store would not open\n", stderr); return 1; }
    scope (exit) sqlite3_close(db);

    auto root = projectsRoot();
    if (root.length == 0) { fputs("ground keep: no HOME, so no ~/.claude/projects\n", stderr); return 1; }
    const(char)[][1] roots = [root];

    auto swept = keepAll(db, roots[]);
    fprintf(stdout, "ground keep: %zu files, %zu lines kept now, %zu files not kept\n",
            swept.files, swept.lines, swept.failed);

    auto proof = provenAll(db, roots[]);
    fprintf(stdout, "ground keep: %zu files hold exactly what was kept, %zu do not\n",
            proof.same, proof.differ);
    foreach (i; 0 .. proof.shown)
        fprintf(stderr, "ground keep: differs: %.*s\n", cast(int) proof.paths[i].length, proof.paths[i].ptr);

    return swept.ok && proof.differ == 0 ? 0 : 1;
}
