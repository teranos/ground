module matcher;

import controls;
import hooks : scopeMatches;

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
    foreach (i; 0 .. haystack.length - needle.length + 1) {
        bool match = true;
        foreach (j; 0 .. needle.length) {
            char a = haystack[i + j];
            char b = needle[j];
            if (a >= 'A' && a <= 'Z') a += 32;
            if (b >= 'A' && b <= 'Z') b += 32;
            if (a != b) { match = false; break; }
        }
        if (match) {
            auto after = i + needle.length;
            if (after < haystack.length && haystack[after] >= '0' && haystack[after] <= '9')
                continue;
            return true;
        }
    }
    return false;
}


bool containsExact(const(char)[] haystack, const(char)[] needle) {
    if (needle.length == 0) return true;
    if (needle.length > haystack.length) return false;
    foreach (i; 0 .. haystack.length - needle.length + 1) {
        if (haystack[i .. i + needle.length] == needle)
            return true;
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

ptrdiff_t lastIndexOf(const(char)[] haystack, const(char)[] needle) {
    if (needle.length == 0) return 0;
    if (needle.length > haystack.length) return -1;
    size_t i = haystack.length - needle.length;
    while (true) {
        if (haystack[i .. i + needle.length] == needle)
            return cast(ptrdiff_t) i;
        if (i == 0) break;
        i--;
    }
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
// Extract the path from a leading `cd <path> && ...` in a chained
// bash command. Returns the target dir, or "" if the command doesn't
// start with `cd`. Used so scope-path filters match against the
// command's effective working dir, not the parent shell's cwd
// (otherwise `cd /tsot-roam && git commit` from a sibling dir slips
// past a `path: "!/tsot-roam"` exclusion). Handles quoted targets
// containing spaces.
const(char)[] extractLeadingCd(const(char)[] command) {
    if (command.length < 3 || command[0 .. 3] != "cd ") return "";
    size_t pos = 3;
    // Skip any extra spaces after `cd`
    while (pos < command.length && command[pos] == ' ') pos++;
    if (pos >= command.length) return "";
    size_t start;
    size_t end;
    if (command[pos] == '"') {
        pos++;
        start = pos;
        while (pos < command.length && command[pos] != '"') pos++;
        end = pos;
        if (pos < command.length) pos++; // consume closing quote
    } else {
        start = pos;
        while (pos < command.length && command[pos] != ' ') pos++;
        end = pos;
    }
    // Whatever follows must be either end-of-command or `&& ...`.
    // Anything else (e.g. `cd /x cmd` with no `&&`) is malformed for
    // our purposes; treat as no-cd-prefix to stay conservative.
    while (pos < command.length && command[pos] == ' ') pos++;
    if (pos < command.length) {
        if (pos + 1 >= command.length || command[pos] != '&' || command[pos + 1] != '&')
            return "";
    }
    return command[start .. end];
}

const(char)[] stripGitDashC(const(char)[] segment) {
    // Returns the subcommand portion after "git " and any number of
    // `-C <arg>` or `-c <arg>` pairs. CTFE-safe (pure slicing — no
    // buffer rebuild). For non-git segments, returns the segment as-is.
    //   "git push origin main"           → "push origin main"
    //   "git -C /path push origin main"  → "push origin main"
    //   "git -c user.email=x push"       → "push"
    //   "git -c x.y=z -C /path push"     → "push"
    //   "go test ./..."                  → "go test ./..."
    if (segment.length < 4 || segment[0 .. 4] != "git ") return segment;
    size_t pos = 4;
    while (pos + 3 <= segment.length && segment[pos] == '-' &&
           (segment[pos + 1] == 'C' || segment[pos + 1] == 'c') &&
           segment[pos + 2] == ' ') {
        pos += 3;
        // Skip the arg (quoted or unquoted)
        if (pos < segment.length && segment[pos] == '"') {
            pos++;
            while (pos < segment.length && segment[pos] != '"') pos++;
            if (pos < segment.length) pos++;
        } else {
            while (pos < segment.length && segment[pos] != ' ') pos++;
        }
        // Skip whitespace after arg
        while (pos < segment.length && segment[pos] == ' ') pos++;
    }
    return segment[pos .. $];
}

// Returns true if segment matches any cmd in the Cmd array.
bool cmdMatchesAny(const(char)[] segment, const Cmd cmd) {
    foreach (ref v; cmd.values)
        if (commandMatch(segment, v)) return true;
    return false;
}

// Matches cmd as a command prefix — not a substring anywhere in the segment.
// "go test" matches "go test ./..." but not "git commit -m 'go test'"
// Also handles "git -C <path>" by normalizing before matching.
// If cmd starts with '*', uses wildcardContains for substring/wildcard matching.
// If cmd starts with '=', requires exact match (no trailing content).
bool commandMatch(const(char)[] segment, const(char)[] cmd) {
    if (cmd.length == 0) return false;
    if (cmd[0] == '*')
        return wildcardContains(segment, cmd);

    bool exactMatch = (cmd[0] == '=');
    if (exactMatch) cmd = cmd[1 .. $];

    // If cmd starts with "git ", normalize segment by stripping -C/-c args
    // and compare against the subcommand portion of cmd. Otherwise plain
    // prefix-match.
    const(char)[] s;
    const(char)[] target;
    if (cmd.length >= 4 && cmd[0 .. 4] == "git ") {
        if (segment.length < 4 || segment[0 .. 4] != "git ") return false;
        s = stripGitDashC(segment);
        target = cmd[4 .. $];
    } else {
        s = segment;
        target = cmd;
    }

    if (exactMatch) return s == target;
    if (s.length < target.length) return false;
    return s[0 .. target.length] == target;
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
        } else if (command[i] == '|' || command[i] == ';' || command[i] == '\n') {
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
        } else if (command[i] == '|' || command[i] == ';' || command[i] == '\n') {
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
                const(Control)* denyCtrl = null;
                const(char)[] decision;

                foreach (ref sc; allScopes) {
                    if (!scopeMatches(sc, cwd))
                        continue;
                    foreach (ref c; sc.controls) {
                        if (!cmdMatchesAny(segment, c.cmd))
                            continue;
                        if (c.omit.value.length > 0 && !contains(segment, c.omit.value))
                            continue;
                        if (c.sessionstart.check !is null && !c.sessionstart.check(cwd, null))
                            continue;

                        // First amendment control (has arg or omit)
                        if (amendment is null && (c.arg.value.length > 0 || c.omit.value.length > 0))
                            amendment = &c;

                        // First match of any kind
                        if (fallback is null)
                            fallback = &c;

                        // deny > ask > allow
                        if (sc.decision == "deny") {
                            decision = "deny";
                            if (denyCtrl is null) denyCtrl = &c;
                        }
                        else if (sc.decision == "ask" && decision != "deny")
                            decision = "ask";
                        else if (decision.length == 0)
                            decision = sc.decision;
                    }
                }

                // Deny control takes priority
                auto matched = denyCtrl !is null ? denyCtrl :
                    amendment !is null ? amendment : fallback;
                if (matched !is null)
                    return Match(matched, segment, decision);
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
    // Effective cwd tracks `cd <path>` segments so subsequent segments
    // in a chain like `pwd && cd /tsot-roam && git commit` evaluate
    // against the cd target, not the parent shell's cwd. See
    // extractLeadingCd doc.
    const(char)[] effCwd = cwd;

    while (i <= command.length) {
        bool isSep = false;
        size_t skip = 0;

        if (i == command.length) {
            isSep = true;
        } else if (command[i] == '|' || command[i] == ';' || command[i] == '\n') {
            isSep = true;
            skip = 1;
        } else if (i + 1 < command.length && command[i] == '&' && command[i + 1] == '&') {
            isSep = true;
            skip = 2;
        }

        if (isSep) {
            auto segment = strip(command[start .. i]);
            if (segment.length > 0) {
                // If the segment is `cd <path>`, it's a cwd-change
                // step in the chain — update effCwd for subsequent
                // segments and emit no control matches for this one.
                auto cdTarget = extractLeadingCd(segment);
                if (cdTarget.length > 0) {
                    effCwd = cdTarget;
                    start = i + skip;
                    i += (skip > 0 ? skip : 1);
                    continue;
                }

                const(Control)* amendment = null;
                const(Control)* fallback = null;
                const(Control)* denyCtrl = null;
                const(char)[] decision;

                foreach (ref sc; allScopes) {
                    if (!scopeMatches(sc, effCwd))
                        continue;
                    foreach (ref c; sc.controls) {
                        if (!cmdMatchesAny(segment, c.cmd))
                            continue;
                        if (c.omit.value.length > 0 && !contains(segment, c.omit.value))
                            continue;
                        if (c.sessionstart.check !is null && !c.sessionstart.check(cwd, null))
                            continue;
                        // Strop controls always fire — they don't compete with amendment/fallback.
                        // Append directly to result; skip the single-per-segment competition.
                        if (c.stropIdx > 0) {
                            if (result.count < result.matches.length) {
                                result.matches[result.count] = Match(&c, segment, sc.decision);
                                result.count++;
                            }
                            continue;
                        }
                        if (amendment is null && (c.arg.value.length > 0 || c.omit.value.length > 0))
                            amendment = &c;
                        if (fallback is null)
                            fallback = &c;
                        if (sc.decision == "deny") {
                            decision = "deny";
                            if (denyCtrl is null) denyCtrl = &c;
                        }
                        else if (sc.decision == "ask" && decision != "deny")
                            decision = "ask";
                        else if (decision.length == 0)
                            decision = sc.decision;
                    }
                }

                // Deny control takes priority over amendment/fallback
                auto matched = denyCtrl !is null ? denyCtrl :
                    amendment !is null ? amendment : fallback;
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
// Inserts control.arg.value right after the matched cmd substring,
// unless arg.value is already present in the segment — then return
// segment unchanged. Avoids duplicate flags when the user (or another
// control) has already supplied the value.
Buf applyArg(const(Control)* c, const(char)[] segment) {
    Buf buf;
    auto idx = indexOf(segment, c.cmd.value);
    if (idx < 0) {
        buf.put(segment);
        return buf;
    }

    if (contains(segment, c.arg.value)) {
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

// Floor-clamp a numeric flag value.
//
// Spec shape: "<prefix>N>=<min>" — e.g. "tail -N>=40". The `N` is a
// placeholder marking where the integer lives in matched input; `>=`
// names the relation; the trailing decimal is the floor.
//
// Behavior: find the first occurrence of `<prefix>` in `segment`. If
// followed by a non-negative integer K, and K < min, replace K with
// min. K >= min, no integer, or prefix absent → segment unchanged.
//
// Purpose: prevent suppression-of-suppression. Claude truncates cargo
// test output via `| tail -8`, discarding failure detail. Raising the
// floor preserves enough trailing context to keep panic messages
// intact. CLAUDE.md: "never | tail -N or | head -N the live stream."
Buf applyClamp(string spec, const(char)[] segment) {
    Buf buf;

    // Parse spec.
    auto gtIdx = indexOf(spec, ">=");
    if (gtIdx < 0) { buf.put(segment); return buf; }

    auto left = spec[0 .. cast(size_t) gtIdx];
    auto right = spec[cast(size_t) gtIdx + 2 .. $];
    if (left.length == 0 || left[$ - 1] != 'N') { buf.put(segment); return buf; }
    auto prefix = left[0 .. $ - 1];

    // Parse min value (decimal, non-negative).
    if (right.length == 0) { buf.put(segment); return buf; }
    int minValue = 0;
    foreach (c; right) {
        if (c < '0' || c > '9') { buf.put(segment); return buf; }
        minValue = minValue * 10 + (c - '0');
    }

    // Find prefix in segment.
    auto idx = indexOf(segment, prefix);
    if (idx < 0) { buf.put(segment); return buf; }

    // Parse number after prefix.
    size_t numStart = cast(size_t) idx + prefix.length;
    size_t numEnd = numStart;
    int n = 0;
    while (numEnd < segment.length && segment[numEnd] >= '0' && segment[numEnd] <= '9') {
        n = n * 10 + (segment[numEnd] - '0');
        numEnd++;
    }
    if (numEnd == numStart) { buf.put(segment); return buf; }

    if (n >= minValue) { buf.put(segment); return buf; }

    // Replace [numStart..numEnd] with minValue's decimal form.
    buf.put(segment[0 .. numStart]);

    char[20] tbuf = 0;
    int tlen = 0;
    int v = minValue;
    if (v == 0) { tbuf[0] = '0'; tlen = 1; }
    else {
        while (v > 0 && tlen < 19) { tbuf[tlen++] = cast(char)('0' + v % 10); v /= 10; }
        // Reverse in place.
        foreach (i; 0 .. tlen / 2) {
            auto tmp = tbuf[i];
            tbuf[i] = tbuf[tlen - 1 - i];
            tbuf[tlen - 1 - i] = tmp;
        }
    }
    buf.put(tbuf[0 .. tlen]);

    buf.put(segment[numEnd .. $]);
    return buf;
}

// Strips the entire line containing the needle.
Buf applyOmitLine(const(char)[] segment, const(char)[] needle) {
    Buf buf;
    auto idx = indexOf(segment, needle);
    if (idx < 0) {
        buf.put(segment);
        return buf;
    }

    // Find line start (after previous \n)
    size_t lineStart = cast(size_t) idx;
    while (lineStart > 0 && segment[lineStart - 1] != '\n')
        lineStart--;

    // Find line end (up to and including \n)
    size_t lineEnd = cast(size_t) idx + needle.length;
    while (lineEnd < segment.length && segment[lineEnd] != '\n')
        lineEnd++;
    if (lineEnd < segment.length)
        lineEnd++; // include the \n
    else if (lineStart > 0 && segment[lineStart - 1] == '\n')
        lineStart--; // last line with no trailing \n: strip preceding \n

    buf.put(segment[0 .. lineStart]);
    buf.put(segment[lineEnd .. $]);
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
    import controls : allScopes;

    __gshared Buf msgBuf;
    msgBuf = Buf.init;

    const(char)[] decision;
    const(char)[] firstName;

    foreach (ref sc; allScopes) {
        if (!scopeMatches(sc, cwd))
            continue;
        foreach (ref c; sc.controls) {
            if (c.filepath.value.length > 0 && contains(filePath, c.filepath.value)) {
                if (firstName.length == 0)
                    firstName = c.name;

                if (msgBuf.len > 0)
                    msgBuf.put(" ");
                msgBuf.put(envSubst(c.msg.value, cwd));

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

// Wildcard match — "check the*log" matches "check the server log".
// Splits pattern on '*', each part must appear in order (case-insensitive).
// No '*' = plain contains.
bool wildcardContains(const(char)[] haystack, const(char)[] pattern) {
    // = prefix: case-sensitive substring match
    if (pattern.length > 0 && pattern[0] == '=')
        return containsExact(haystack, pattern[1 .. $]);

    // Fast path: no wildcard
    bool hasWild = false;
    foreach (c; pattern)
        if (c == '*') { hasWild = true; break; }
    if (!hasWild)
        return contains(haystack, pattern);

    // Split on '*' and match segments in order
    size_t pos = 0; // current position in haystack
    size_t segStart = 0;
    foreach (i; 0 .. pattern.length + 1) {
        bool atEnd = (i == pattern.length);
        bool atStar = !atEnd && pattern[i] == '*';
        if (atStar || atEnd) {
            auto seg = pattern[segStart .. i];
            if (seg.length > 0) {
                // Find seg in haystack starting from pos (case-insensitive)
                bool found = false;
                if (seg.length <= haystack.length) {
                    foreach (j; pos .. haystack.length - seg.length + 1) {
                        bool match = true;
                        foreach (k; 0 .. seg.length) {
                            char a = haystack[j + k];
                            char b = seg[k];
                            if (a >= 'A' && a <= 'Z') a += 32;
                            if (b >= 'A' && b <= 'Z') b += 32;
                            if (a != b) { match = false; break; }
                        }
                        if (match) {
                            pos = j + seg.length;
                            found = true;
                            break;
                        }
                    }
                }
                if (!found) return false;
            }
            segStart = i + 1;
        }
    }
    return true;
}

// --- Strip double-quoted content from commands ---
// Only strips double quotes — single quotes preserve content (URLs, paths).
// "git commit -m "Migrate sed/awk"" → "git commit -m "
// "curl 'http://localhost:877'"      → "curl 'http://localhost:877'" (preserved)

struct StripBuf {
    char[8192] data = 0;
    size_t len;
    const(char)[] slice() const return { return data[0 .. len]; }
}

StripBuf stripQuoted(const(char)[] cmd) {
    StripBuf result;
    size_t i = 0;
    while (i < cmd.length && result.len < result.data.length) {
        char c = cmd[i];
        if (c == '"') {
            // Skip until matching close double quote
            i++;
            while (i < cmd.length && cmd[i] != '"') i++;
            if (i < cmd.length) i++; // skip closing quote
        } else {
            result.data[result.len++] = c;
            i++;
        }
    }
    return result;
}

// --- Environment variable substitution ---
// Replaces ${key} placeholders in msg using the env block from the project
// whose path matches cwd. Longest-path-wins for multiple matches.

const(char)[] envSubst(const(char)[] msg, const(char)[] cwd) {
    // Fast path: no ${} in message
    bool hasDollar = false;
    foreach (i; 0 .. msg.length) {
        if (i + 1 < msg.length && msg[i] == '$' && msg[i + 1] == '{') {
            hasDollar = true;
            break;
        }
    }
    if (!hasDollar) return msg;

    // Find matching env block — longest path wins
    import controls : allParsed;
    static immutable parsed = allParsed;

    int bestIdx = -1;
    size_t bestLen = 0;
    foreach (i; 0 .. parsed.envCount) {
        if (parsed.envs[i].path.length > 0 && contains(cwd, parsed.envs[i].path)) {
            if (parsed.envs[i].path.length > bestLen) {
                bestLen = parsed.envs[i].path.length;
                bestIdx = cast(int) i;
            }
        }
    }
    if (bestIdx < 0) return msg;

    // Substitute ${key} with values from the matching env block
    __gshared Buf envBuf;
    envBuf.len = 0;

    size_t pos = 0;
    while (pos < msg.length) {
        if (pos + 1 < msg.length && msg[pos] == '$' && msg[pos + 1] == '{') {
            auto keyStart = pos + 2;
            auto keyEnd = keyStart;
            while (keyEnd < msg.length && msg[keyEnd] != '}') keyEnd++;
            if (keyEnd >= msg.length) {
                envBuf.put(msg[pos .. $]);
                break;
            }
            auto key = msg[keyStart .. keyEnd];

            bool found = false;
            foreach (k; 0 .. parsed.envs[bestIdx].count) {
                if (parsed.envs[bestIdx].keys[k] == key) {
                    envBuf.put(parsed.envs[bestIdx].values[k]);
                    found = true;
                    break;
                }
            }
            if (!found) {
                envBuf.put(msg[pos .. keyEnd + 1]);
            }
            pos = keyEnd + 1;
        } else {
            envBuf.data[envBuf.len++] = msg[pos];
            pos++;
        }
    }
    return envBuf.slice();
}

