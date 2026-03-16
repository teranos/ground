module matcher;

import controls;

struct Match {
    const(Control)* control;
    const(char)[] segment;
    const(char)[] decision;
}

struct Buf {
    char[8192] data = 0;
    size_t len;

    void put(const(char)[] s) {
        foreach (c; s)
            if (len < data.length)
                data[len++] = c;
    }

    const(char)[] slice() {
        return data[0 .. len];
    }
}

bool contains(const(char)[] haystack, const(char)[] needle) {
    if (needle.length == 0) return true;
    if (needle.length > haystack.length) return false;
    foreach (i; 0 .. haystack.length - needle.length + 1)
        if (haystack[i .. i + needle.length] == needle)
            return true;
    return false;
}

bool containsCI(const(char)[] haystack, const(char)[] needle) {
    if (needle.length == 0) return true;
    if (needle.length > haystack.length) return false;
    foreach (i; 0 .. haystack.length - needle.length + 1) {
        bool match = true;
        foreach (j; 0 .. needle.length) {
            char a = haystack[i + j];
            char b = needle[j];
            if (a >= 'A' && a <= 'Z') a += 32;
            if (b >= 'A' && b <= 'Z') b += 32;
            if (a != b) { match = false; break; }
        }
        if (match) return true;
    }
    return false;
}

// Like contains, but the match must not be followed by a digit.
// "port 877" matches in "port 877 is" but not in "port 8773".
bool containsWord(const(char)[] haystack, const(char)[] needle) {
    if (needle.length == 0) return true;
    if (needle.length > haystack.length) return false;
    foreach (i; 0 .. haystack.length - needle.length + 1) {
        if (haystack[i .. i + needle.length] == needle) {
            auto after = i + needle.length;
            if (after < haystack.length && haystack[after] >= '0' && haystack[after] <= '9')
                continue;
            return true;
        }
    }
    return false;
}

ptrdiff_t indexOf(const(char)[] haystack, const(char)[] needle) {
    if (needle.length == 0) return 0;
    if (needle.length > haystack.length) return -1;
    foreach (i; 0 .. haystack.length - needle.length + 1)
        if (haystack[i .. i + needle.length] == needle)
            return cast(ptrdiff_t) i;
    return -1;
}

const(char)[] strip(const(char)[] s) {
    size_t start = 0;
    while (start < s.length && s[start] == ' ')
        start++;
    size_t end = s.length;
    while (end > start && s[end - 1] == ' ')
        end--;
    return s[start .. end];
}

// Strip "git -C <path> " prefix, returning the normalized segment.
// "git -C /some/path push origin" -> "git push origin"
const(char)[] stripGitDashC(const(char)[] segment) {
    // Must start with "git -C "
    if (segment.length < 7) return segment;
    if (segment[0 .. 7] != "git -C ") return segment;
    // Skip past the path argument
    size_t pos = 7;
    // Handle quoted path
    if (pos < segment.length && segment[pos] == '"') {
        pos++;
        while (pos < segment.length && segment[pos] != '"') pos++;
        if (pos < segment.length) pos++; // skip closing quote
    } else {
        while (pos < segment.length && segment[pos] != ' ') pos++;
    }
    // Skip space after path
    while (pos < segment.length && segment[pos] == ' ') pos++;
    if (pos >= segment.length) return segment;
    // Reconstruct: "git " + remainder
    __gshared char[8192] buf = 0;
    foreach (j, c; "git ") buf[j] = c;
    auto rest = segment[pos .. $];
    if (4 + rest.length > buf.length) return segment;
    foreach (j; 0 .. rest.length) buf[4 + j] = rest[j];
    return buf[0 .. 4 + rest.length];
}

// Matches cmd as a command prefix — not a substring anywhere in the segment.
// "go test" matches "go test ./..." but not "git commit -m 'go test'"
// Also handles "git -C <path>" by normalizing before matching.
bool commandMatch(const(char)[] segment, const(char)[] cmd) {
    auto s = stripGitDashC(segment);
    if (s.length < cmd.length) return false;
    if (s[0 .. cmd.length] != cmd) return false;
    if (s.length == cmd.length) return true;
    return s[cmd.length] == ' ';
}

// Returns true if any segment in a compound command matches cmd as a prefix.
bool hasSegment(const(char)[] command, const(char)[] cmd) {
    size_t start = 0;
    size_t i = 0;

    while (i <= command.length) {
        bool isSep = false;
        size_t skip = 0;

        if (i == command.length) {
            isSep = true;
        } else if (command[i] == '|' || command[i] == ';') {
            isSep = true;
            skip = 1;
        } else if (i + 1 < command.length && command[i] == '&' && command[i + 1] == '&') {
            isSep = true;
            skip = 2;
        }

        if (isSep) {
            auto segment = strip(command[start .. i]);
            if (segment.length > 0 && commandMatch(segment, cmd))
                return true;
            start = i + skip;
            if (skip > 0) { i += skip; continue; }
        }
        i++;
    }
    return false;
}

// Iterates over pipe/chain segments and returns the first matching control.
// Scopes filter by cwd — empty scope path matches everywhere.
Match checkCommand(const(char)[] command, const(char)[] cwd) {
    size_t start = 0;
    size_t i = 0;

    while (i <= command.length) {
        bool isSep = false;
        size_t skip = 0;

        if (i == command.length) {
            isSep = true;
        } else if (command[i] == '|' || command[i] == ';') {
            isSep = true;
            skip = 1;
        } else if (i + 1 < command.length && command[i] == '&' && command[i + 1] == '&') {
            isSep = true;
            skip = 2;
        }

        if (isSep) {
            auto segment = strip(command[start .. i]);
            if (segment.length > 0) {
                // Scan all scopes — collect amendment and most restrictive decision
                const(Control)* amendment = null;
                const(Control)* fallback = null;
                const(char)[] decision;

                foreach (ref sc; allScopes) {
                    if (sc.path.length > 0 && !contains(cwd, sc.path))
                        continue;
                    foreach (ref c; sc.controls) {
                        if (commandMatch(segment, c.cmd.value)) {
                            if (c.omit.value.length > 0 && !contains(segment, c.omit.value))
                                continue;

                            // First amendment control (has arg or omit)
                            if (amendment is null && (c.arg.value.length > 0 || c.omit.value.length > 0))
                                amendment = &c;

                            // First match of any kind
                            if (fallback is null)
                                fallback = &c;

                            // "ask" beats "allow"
                            if (sc.decision == "ask")
                                decision = "ask";
                            else if (decision.length == 0)
                                decision = sc.decision;
                        }
                    }
                }

                if (amendment !is null)
                    return Match(amendment, segment, decision);
                if (fallback !is null)
                    return Match(fallback, segment, decision);
            }
            start = i + skip;
            if (skip > 0) {
                i += skip;
                continue;
            }
        }
        i++;
    }

    return Match(null, "", "");
}

struct MatchSet {
    Match[8] matches;
    size_t count;
}

// Returns all matching controls across all segments of a compound command.
MatchSet checkAllCommands(const(char)[] command, const(char)[] cwd) {
    MatchSet result;
    size_t start = 0;
    size_t i = 0;

    while (i <= command.length) {
        bool isSep = false;
        size_t skip = 0;

        if (i == command.length) {
            isSep = true;
        } else if (command[i] == '|' || command[i] == ';') {
            isSep = true;
            skip = 1;
        } else if (i + 1 < command.length && command[i] == '&' && command[i + 1] == '&') {
            isSep = true;
            skip = 2;
        }

        if (isSep) {
            auto segment = strip(command[start .. i]);
            if (segment.length > 0) {
                const(Control)* amendment = null;
                const(Control)* fallback = null;
                const(char)[] decision;

                foreach (ref sc; allScopes) {
                    if (sc.path.length > 0 && !contains(cwd, sc.path))
                        continue;
                    foreach (ref c; sc.controls) {
                        if (commandMatch(segment, c.cmd.value)) {
                            if (c.omit.value.length > 0 && !contains(segment, c.omit.value))
                                continue;
                            if (amendment is null && (c.arg.value.length > 0 || c.omit.value.length > 0))
                                amendment = &c;
                            if (fallback is null)
                                fallback = &c;
                            if (sc.decision == "ask")
                                decision = "ask";
                            else if (decision.length == 0)
                                decision = sc.decision;
                        }
                    }
                }

                auto matched = amendment !is null ? amendment : fallback;
                if (matched !is null && result.count < result.matches.length) {
                    result.matches[result.count] = Match(matched, segment, decision);
                    result.count++;
                }
            }
            start = i + skip;
            if (skip > 0) {
                i += skip;
                continue;
            }
        }
        i++;
    }

    return result;
}

// Builds the amended command in a static buffer.
// Inserts control.arg.value right after the matched cmd substring.
Buf applyArg(const(Control)* c, const(char)[] segment) {
    Buf buf;
    auto idx = indexOf(segment, c.cmd.value);
    if (idx < 0) {
        buf.put(segment);
        return buf;
    }

    auto insertAt = cast(size_t) idx + c.cmd.value.length;
    buf.put(segment[0 .. insertAt]);
    buf.put(" ");
    buf.put(c.arg.value);
    buf.put(segment[insertAt .. $]);
    return buf;
}

// Strips the omit string from the segment and cleans up whitespace.
Buf applyOmit(const(Control)* c, const(char)[] segment) {
    Buf buf;
    auto idx = indexOf(segment, c.omit.value);
    if (idx < 0) {
        buf.put(segment);
        return buf;
    }

    size_t beforeEnd = cast(size_t) idx;
    size_t afterStart = cast(size_t) idx + c.omit.value.length;

    // Trim trailing space from before, leading space from after
    while (beforeEnd > 0 && segment[beforeEnd - 1] == ' ')
        beforeEnd--;
    while (afterStart < segment.length && segment[afterStart] == ' ')
        afterStart++;

    buf.put(segment[0 .. beforeEnd]);
    if (beforeEnd > 0 && afterStart < segment.length)
        buf.put(" ");
    buf.put(segment[afterStart .. $]);

    return buf;
}

struct FileMatch {
    bool matched;
    const(char)[] decision;
    // Combined message from all matching controls, built in static buffer
    const(char)[] msg;
    // Name of first matching control (for attestation)
    const(char)[] name;
}

// Scans file-path controls. Composes all matching controls — concatenates messages,
// most restrictive decision wins.
FileMatch checkFilePath(const(char)[] filePath, const(char)[] cwd) {
    import controls : fileScopes;

    __gshared Buf msgBuf;
    msgBuf = Buf.init;

    const(char)[] decision;
    const(char)[] firstName;

    foreach (ref sc; fileScopes) {
        if (sc.path.length > 0 && !contains(cwd, sc.path))
            continue;
        foreach (ref c; sc.controls) {
            if (c.filepath.value.length > 0 && contains(filePath, c.filepath.value)) {
                if (firstName.length == 0)
                    firstName = c.name;

                if (msgBuf.len > 0)
                    msgBuf.put(" ");
                msgBuf.put(c.msg.value);

                if (sc.decision == "ask")
                    decision = "ask";
                else if (decision.length == 0)
                    decision = sc.decision;
            }
        }
    }

    if (msgBuf.len > 0)
        return FileMatch(true, decision, msgBuf.slice(), firstName);
    return FileMatch(false, "", "", "");
}

// --- Major Tom's test suite ---

enum QNTX = "/Users/dev/QNTX";
enum OTHER = "/Users/dev/other-project";

static if (__traits(compiles, { import qntx; })) {
    unittest {
        // Major Tom runs "go test" in QNTX — Graunde Control catches it
        auto result = checkCommand("go test ./...", QNTX);
        assert(result.control !is null);
        assert(result.control.name == "go-test-args");
    }

    unittest {
        // Major Tom forgets build tags — Graunde Control amends
        auto result = checkCommand("go test ./...", QNTX);
        auto amended = applyArg(result.control, result.segment);
        assert(amended.slice() == `go test -tags "rustsqlite,qntxwasm" -short ./...`);
    }

    unittest {
        // Major Tom hides "go test" in a pipe — still caught, args preserved
        auto result = checkCommand("echo hello | go test -v ./cmd/qntx", QNTX);
        assert(result.control !is null);
        auto amended = applyArg(result.control, result.segment);
        assert(amended.slice() == `go test -tags "rustsqlite,qntxwasm" -short -v ./cmd/qntx`);
    }

    unittest {
        // Major Tom chains with && — segments split correctly
        auto result = checkCommand("make build && go test ./... && echo done", QNTX);
        assert(result.control !is null);
        assert(result.segment == "go test ./...");
    }

    unittest {
        // Major Tom uses semicolons — segments split correctly
        auto result = checkCommand("echo start; go test -race ./...", QNTX);
        assert(result.control !is null);
        assert(result.segment == "go test -race ./...");
    }
}

unittest {
    // Major Tom runs "go test" outside QNTX — Graunde Control lets it pass
    auto result = checkCommand("go test ./...", OTHER);
    assert(result.control is null);
}

unittest {
    // Major Tom runs "ls -la" — Graunde Control lets it pass
    auto result = checkCommand("ls -la", QNTX);
    assert(result.control is null);
}

unittest {
    // Major Tom tries --no-verify — Graunde Control catches it (universal)
    auto result = checkCommand(`git commit --no-verify -m "fix bug"`, OTHER);
    assert(result.control !is null);
    assert(result.control.name == "no-skip-hooks");
}

unittest {
    // Major Tom tries --no-verify — Graunde Control strips it
    auto result = checkCommand(`git commit --no-verify -m "fix bug"`, OTHER);
    auto amended = applyOmit(result.control, result.segment);
    assert(amended.slice() == `git commit -m "fix bug"`);
}

unittest {
    // Major Tom puts --no-verify at the end — still stripped
    auto result = checkCommand("git push --no-verify", OTHER);
    assert(result.control !is null);
    auto amended = applyOmit(result.control, result.segment);
    assert(amended.slice() == "git push");
}

unittest {
    // Major Tom runs normal git — Graunde Control lets it pass
    auto result = checkCommand("git status", OTHER);
    assert(result.control is null);
}

unittest {
    // The Ïúíþ incident — "go test" in a commit message must not match
    auto result = checkCommand(`git commit -m "run go test before merging"`, QNTX);
    assert(result.control is null || result.control.name != "go-test-args");
}

static if (__traits(compiles, { import qntx; })) {
    unittest {
        // Prefix match only — "go test" as a command matches in QNTX
        auto result = checkCommand("go test -v ./...", QNTX);
        assert(result.control !is null);
        assert(result.control.name == "go-test-args");
    }

    unittest {
        // Prefix match only — "go testing" is not "go test"
        auto result = checkCommand("go testing", QNTX);
        assert(result.control is null);
    }
}

unittest {
    // Universal controls fire in any project
    auto result = checkCommand("git push --no-verify", QNTX);
    assert(result.control !is null);
    assert(result.control.name == "no-skip-hooks");
}

unittest {
    // git commit triggers checkpoint with "ask" decision
    auto result = checkCommand("git commit -m \"hello\"", OTHER);
    assert(result.control !is null);
    assert(result.control.name == "git-commit");
    assert(result.decision == "ask");
}

unittest {
    // gh pr create triggers checkpoint with "ask" decision
    auto result = checkCommand("gh pr create --title \"fix\"", OTHER);
    assert(result.control !is null);
    assert(result.control.name == "pr-create");
    assert(result.decision == "ask");
}

static if (__traits(compiles, { import qntx; })) {
    unittest {
        // go test in QNTX gets "allow" decision from scope
        auto result = checkCommand("go test ./...", QNTX);
        assert(result.control !is null);
        assert(result.decision == "allow");
    }
}

unittest {
    // git commit --no-verify: omit stripped AND checkpoint upgrades to "ask"
    auto result = checkCommand("git commit --no-verify -m \"hello\"", OTHER);
    assert(result.control !is null);
    assert(result.control.name == "no-skip-hooks");
    assert(result.decision == "ask");
}

unittest {
    // git push triggers checkpoint with "ask" decision
    auto result = checkCommand("git push origin main", OTHER);
    assert(result.control !is null);
    assert(result.control.name == "git-push-pull-first");
    assert(result.decision == "ask");
}

unittest {
    // git push --no-verify: omit wins for amendment, ask wins for decision
    auto result = checkCommand("git push --no-verify", OTHER);
    assert(result.control !is null);
    assert(result.control.name == "no-skip-hooks");
    assert(result.decision == "ask");
}

unittest {
    // git tag triggers checkpoint with "ask" decision
    auto result = checkCommand("git tag -a v1.0.0 -m \"release\"", OTHER);
    assert(result.control !is null);
    assert(result.control.name == "git-tag-semver");
    assert(result.decision == "ask");
}

unittest {
    // git checkout -b triggers branch checkpoint with "ask" decision
    auto result = checkCommand("git checkout -b feature-branch", OTHER);
    assert(result.control !is null);
    assert(result.control.name == "git-checkout-b");
    assert(result.decision == "ask");
}

unittest {
    // hasSegment finds "git push" in compound command
    assert(hasSegment("git add -A && git commit -m \"done\" && git push", "git push"));
    assert(hasSegment("git push origin main", "git push"));
    assert(!hasSegment(`git commit -m "run git push later"`, "git push"));
    assert(hasSegment("echo ok; git push", "git push"));
}

unittest {
    // git -C <path> is normalized for matching
    assert(commandMatch("git -C /some/path push origin main", "git push"));
    assert(commandMatch("git -C /some/path commit -m \"hello\"", "git commit"));
    assert(hasSegment("git -C /some/path push origin main", "git push"));
    // quoted path
    assert(commandMatch(`git -C "/path with spaces" push`, "git push"));
    // non-git commands unaffected
    assert(commandMatch("go test ./...", "go test"));
    assert(!commandMatch("go test ./...", "git push"));
}

unittest {
    // Compound command: git push && git checkout -b should match BOTH controls
    auto results = checkAllCommands("git push origin main && git checkout -b feature-branch", OTHER);
    assert(results.count == 2);
    assert(results.matches[0].control.name == "git-push-pull-first");
    assert(results.matches[1].control.name == "git-checkout-b");
}
