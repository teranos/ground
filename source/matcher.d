module matcher;

import controls;

struct Match {
    const(Control)* control;
    const(char)[] segment;
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

// Iterates over pipe/chain segments and returns the first matching control.
// No dynamic arrays — segments are slices into the original command string.
Match checkCommand(const(char)[] command) {
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
                foreach (ref c; allControls) {
                    if (contains(segment, c.cmd.value)) {
                        // Omit controls only match when the omit string is present
                        if (c.omit.value.length > 0 && !contains(segment, c.omit.value))
                            continue;
                        return Match(&c, segment);
                    }
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

    return Match(null, "");
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

// --- Major Tom's test suite ---

unittest {
    // Major Tom runs "go test" — Graunde Control catches it
    auto result = checkCommand("go test ./...");
    assert(result.control !is null);
    assert(result.control.name == "go-test-args");
}

unittest {
    // Major Tom runs "ls -la" — Graunde Control lets it pass
    auto result = checkCommand("ls -la");
    assert(result.control is null);
}

unittest {
    // Major Tom forgets build tags — Graunde Control amends
    auto result = checkCommand("go test ./...");
    auto amended = applyArg(result.control, result.segment);
    assert(amended.slice() == `go test -tags "rustsqlite,qntxwasm" -short ./...`);
}

unittest {
    // Major Tom hides "go test" in a pipe — still caught, args preserved
    auto result = checkCommand("echo hello | go test -v ./cmd/qntx");
    assert(result.control !is null);
    auto amended = applyArg(result.control, result.segment);
    assert(amended.slice() == `go test -tags "rustsqlite,qntxwasm" -short -v ./cmd/qntx`);
}

unittest {
    // Major Tom chains with && — segments split correctly
    auto result = checkCommand("make build && go test ./... && echo done");
    assert(result.control !is null);
    assert(result.segment == "go test ./...");
}

unittest {
    // Major Tom uses semicolons — segments split correctly
    auto result = checkCommand("echo start; go test -race ./...");
    assert(result.control !is null);
    assert(result.segment == "go test -race ./...");
}

unittest {
    // Major Tom tries --no-verify — Graunde Control catches it
    auto result = checkCommand(`git commit --no-verify -m "fix bug"`);
    assert(result.control !is null);
    assert(result.control.name == "no-skip-hooks");
}

unittest {
    // Major Tom tries --no-verify — Graunde Control strips it
    auto result = checkCommand(`git commit --no-verify -m "fix bug"`);
    auto amended = applyOmit(result.control, result.segment);
    assert(amended.slice() == `git commit -m "fix bug"`);
}

unittest {
    // Major Tom puts --no-verify at the end — still stripped
    auto result = checkCommand("git push --no-verify");
    assert(result.control !is null);
    auto amended = applyOmit(result.control, result.segment);
    assert(amended.slice() == "git push");
}

unittest {
    // Major Tom runs normal git — Graunde Control lets it pass
    auto result = checkCommand("git status");
    assert(result.control is null);
}
