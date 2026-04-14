module count;

// Pass 1: count pbt blocks to size arrays for pass 2.
// No data structures built — just totals and maxes.

struct PbtCounts {
    int totalScopes;
    int maxControlsPerScope;
    int maxPermsPerScope;
    int totalControls;
    int totalPerms;
    int totalProjects;
    int totalEnvs;
}

PbtCounts countPbt(string input) {
    import lexer : skipWS, skipLine, readWord, splitMode, expect, readValue;
    PbtCounts r;
    size_t pos = 0;

    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }

        auto word = readWord(input, pos);
        auto wm = splitMode(word);
        if (wm.base == "scope") {
            skipWS(input, pos);
            expect(input, pos, '{');
            countScope(input, pos, r);
        } else if (wm.base == "control") {
            skipWS(input, pos);
            expect(input, pos, '{');
            skipBlock(input, pos);
            r.totalScopes++;
            r.totalControls++;
            if (r.maxControlsPerScope < 1) r.maxControlsPerScope = 1;
        } else if (wm.base == "permission") {
            skipWS(input, pos);
            expect(input, pos, '{');
            skipBlock(input, pos);
            r.totalScopes++;
            r.totalPerms++;
            if (r.maxPermsPerScope < 1) r.maxPermsPerScope = 1;
        } else if (wm.base == "project") {
            skipWS(input, pos);
            expect(input, pos, '{');
            r.totalProjects++;
            countProject(input, pos, r);
        } else if (wm.base == "qntx" || wm.base == "attestation") {
            skipWS(input, pos);
            expect(input, pos, '{');
            skipBlock(input, pos);
        }
    }
    return r;
}

private:

void countScope(ref string input, ref size_t pos, ref PbtCounts r) {
    import lexer : skipWS, skipLine, readWord, splitMode, expect, readValue;
    int ctrls = 0, perms = 0;
    bool hasChildren = false;

    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }
        if (input[pos] == '}') {
            pos++;
            if (!hasChildren || ctrls > 0 || perms > 0) {
                r.totalScopes++;
                r.totalControls += ctrls;
                r.totalPerms += perms;
                if (ctrls > r.maxControlsPerScope) r.maxControlsPerScope = ctrls;
                if (perms > r.maxPermsPerScope) r.maxPermsPerScope = perms;
            }
            return;
        }
        auto key = readWord(input, pos);
        auto wm = splitMode(key);
        if (wm.base == "scope") {
            skipWS(input, pos);
            expect(input, pos, '{');
            hasChildren = true;
            countScope(input, pos, r);
        } else if (wm.base == "control") {
            skipWS(input, pos);
            expect(input, pos, '{');
            skipBlock(input, pos);
            ctrls++;
        } else if (wm.base == "permission") {
            skipWS(input, pos);
            expect(input, pos, '{');
            skipBlock(input, pos);
            perms++;
        } else if (wm.base == "project") {
            skipWS(input, pos);
            expect(input, pos, '{');
            hasChildren = true;
            r.totalProjects++;
            countProject(input, pos, r);
        } else {
            // Field: key: value
            skipWS(input, pos);
            expect(input, pos, ':');
            skipWS(input, pos);
            auto val = readValue(input, pos);
            if (val is null) {
                // List — skip to ]
                while (pos < input.length && input[pos] != ']') {
                    skipWS(input, pos);
                    if (pos < input.length && input[pos] == ']') break;
                    readValue(input, pos);
                    skipWS(input, pos);
                    if (pos < input.length && input[pos] == ',') pos++;
                }
                if (pos < input.length) pos++;
            }
        }
    }
}

// Count inside a project block — delegates to countScope for scopes,
// counts controls/permissions directly (project can contain all three).
void countProject(ref string input, ref size_t pos, ref PbtCounts r) {
    import lexer : skipWS, skipLine, readWord, splitMode, expect, readValue;

    while (pos < input.length) {
        skipWS(input, pos);
        if (pos >= input.length) break;
        if (input[pos] == '#') { skipLine(input, pos); continue; }
        if (input[pos] == '}') { pos++; return; }

        auto key = readWord(input, pos);
        auto wm = splitMode(key);
        if (wm.base == "scope") {
            skipWS(input, pos);
            expect(input, pos, '{');
            countScope(input, pos, r);
        } else if (wm.base == "control") {
            skipWS(input, pos);
            expect(input, pos, '{');
            skipBlock(input, pos);
            r.totalScopes++;
            r.totalControls++;
            if (r.maxControlsPerScope < 1) r.maxControlsPerScope = 1;
        } else if (wm.base == "permission") {
            skipWS(input, pos);
            expect(input, pos, '{');
            skipBlock(input, pos);
            r.totalScopes++;
            r.totalPerms++;
            if (r.maxPermsPerScope < 1) r.maxPermsPerScope = 1;
        } else if (wm.base == "env") {
            skipWS(input, pos);
            expect(input, pos, '{');
            skipBlock(input, pos);
            r.totalEnvs++;
        } else {
            // Field: key: value
            skipWS(input, pos);
            expect(input, pos, ':');
            skipWS(input, pos);
            auto val = readValue(input, pos);
            if (val is null) {
                while (pos < input.length && input[pos] != ']') {
                    skipWS(input, pos);
                    if (pos < input.length && input[pos] == ']') break;
                    readValue(input, pos);
                    skipWS(input, pos);
                    if (pos < input.length && input[pos] == ',') pos++;
                }
                if (pos < input.length) pos++;
            }
        }
    }
}

// Skip to matching } — handles quoted strings
void skipBlock(ref string input, ref size_t pos) {
    int depth = 1;
    while (pos < input.length && depth > 0) {
        auto c = input[pos];
        if (c == '"') { pos++; while (pos < input.length && input[pos] != '"') pos++; if (pos < input.length) pos++; }
        else if (c == '`') { pos++; while (pos < input.length && input[pos] != '`') pos++; if (pos < input.length) pos++; }
        else if (c == '{') { depth++; pos++; }
        else if (c == '}') { depth--; if (depth == 0) { pos++; return; } pos++; }
        else pos++;
    }
}
