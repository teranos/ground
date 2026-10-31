module floor_test;

// "a true agnostic ground, and then only the compiled controls being their own thing shipped to the user"

// An engine is built from the floor: it names no project, no node, no org and posts nothing.
// The user's controls arrive as the sand landed for the repository (sandload.d).
version (Floor) unittest {
    import builtin_sand : allParsed;
    static assert(allParsed.projectCount == 0, "the floor names no project");
    static assert(!allParsed.qntx.present, "the floor names no node");
    static assert(allParsed.orgCount == 0, "the floor names no org");
    static assert(allParsed.attestationCount == 0, "the floor posts no attestation");
    static assert(allParsed.envCount == 0, "the floor sets no env");
}
