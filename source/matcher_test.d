module matcher_test;

import matcher : stripQuoted, checkCommand, checkAllCommands, commandMatch,
                 hasSegment, applyArg, applyOmit, wildcardContains, containsExact;

// --- stripQuoted tests ---

static assert(stripQuoted(`git commit -m "Migrate sed/awk"`).slice == `git commit -m `);
static assert(stripQuoted(`echo "hello world"`).slice == `echo `);
static assert(stripQuoted(`sleep 3 && say "time"`).slice == `sleep 3 && say `);
static assert(stripQuoted(`no quotes here`).slice == `no quotes here`);
// Single quotes preserved — URLs and paths stay intact
static assert(stripQuoted(`curl 'http://localhost:877/api'`).slice == `curl 'http://localhost:877/api'`);
static assert(stripQuoted(`sed -i 's/foo/bar/' file`).slice == `sed -i 's/foo/bar/' file`);
static assert(stripQuoted(`sed 's/a/b/' "my file.txt"`).slice == `sed 's/a/b/' `);

// --- Major Tom's test suite ---

enum QNTX = "/Users/dev/QNTX";
enum OTHER = "/Users/dev/other-project";

static if (__traits(compiles, { import qntx; })) {
    unittest {
        // Major Tom runs "go test" in QNTX — Ground Control catches it
        auto result = checkCommand("go test ./...", QNTX);
        assert(result.control !is null);
        assert(result.control.name == "go-test-args");
    }

    unittest {
        // Major Tom forgets build tags — Ground Control amends
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
    // Major Tom runs "go test" outside QNTX — Ground Control lets it pass
    auto result = checkCommand("go test ./...", OTHER);
    assert(result.control is null);
}

unittest {
    // Major Tom runs "ls -la" — Ground Control lets it pass
    auto result = checkCommand("ls -la", QNTX);
    assert(result.control is null);
}

unittest {
    // Major Tom tries --no-verify — Ground Control catches it (universal)
    auto result = checkCommand(`git commit --no-verify -m "fix bug"`, OTHER);
    assert(result.control !is null);
    assert(result.control.name == "no-skip-hooks");
}

unittest {
    // Major Tom tries --no-verify — Ground Control strips it
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
    // Major Tom runs normal git — Ground Control lets it pass
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
        // Prefix match — "go test" with trailing space matches
        assert(commandMatch("go test ./...", "go test"));
        assert(commandMatch("go testing", "go test"));
    }
}

unittest {
    // Universal controls fire in any project
    auto result = checkCommand("git push --no-verify", QNTX);
    assert(result.control !is null);
    assert(result.control.name == "no-skip-hooks");
}

unittest {
    // git commit without user requesting it — denied by commitNotRequested handler
    // Set dummy session so handler queries db (no matching data → deny)
    import control_handlers : g_sessionId;
    g_sessionId = "test-commit-check";
    scope(exit) g_sessionId = null;

    auto result = checkCommand("git commit -m \"hello\"", OTHER);
    assert(result.control !is null);
    assert(result.control.name == "commit-not-requested");
    assert(result.decision == "deny");
}

unittest {
    // git commit: deny wins over ask (commit-not-requested deny > git-commit ask)
    import control_handlers : g_sessionId;
    g_sessionId = "test-commit-check";
    scope(exit) g_sessionId = null;

    auto results = checkAllCommands("git commit -m \"hello\"", OTHER);
    assert(results.count == 1); // single segment = single match
    assert(results.matches[0].control.name == "commit-not-requested");
    assert(results.matches[0].decision == "deny");
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
    // Wildcard cmd — starts with * uses wildcardContains
    assert(commandMatch("curl -s 'http://localhost:877/api/query'", "*:877/*"));
    assert(!commandMatch("curl -s 'http://localhost:8772/api/query'", "*:877/*"));
    assert(commandMatch("curl http://localhost:8820/foo", "*:8820/*"));
    // Wildcard in compound command
    assert(hasSegment("echo ok && curl 'http://localhost:877/api' | jq .", "*:877/*"));
    // Non-wildcard still prefix-matches
    assert(commandMatch("curl http://localhost:877/api", "curl"));
    assert(!commandMatch("echo curl", "curl"));
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

// --- isCommitApproval tests ---

unittest {
    // Explicit "commit" in message — approved
    import control_handlers : isCommitApproval;
    assert(isCommitApproval("ok commit"));
}

unittest {
    // "ok" by itself — counts as approval (post-denial confirmation)
    import control_handlers : isCommitApproval;
    assert(isCommitApproval("ok"));
}

unittest {
    // "y" by itself — counts as approval
    import control_handlers : isCommitApproval;
    assert(isCommitApproval("y"));
}

unittest {
    // "ok" with whitespace — still counts
    import control_handlers : isCommitApproval;
    assert(isCommitApproval("  ok  "));
}

unittest {
    // "y" with whitespace — still counts
    import control_handlers : isCommitApproval;
    assert(isCommitApproval("  y\n"));
}

unittest {
    // "sure" by itself — counts as approval
    import control_handlers : isCommitApproval;
    assert(isCommitApproval("sure"));
}

unittest {
    // Random message without "commit" — not approved
    import control_handlers : isCommitApproval;
    assert(!isCommitApproval("fix the bug please"));
}

unittest {
    // "ok" inside a longer message — not a bare confirmation
    import control_handlers : isCommitApproval;
    assert(!isCommitApproval("ok fix the bug"));
}

unittest {
    // "yes" is not "y" — not a bare confirmation (and no "commit")
    import control_handlers : isCommitApproval;
    assert(!isCommitApproval("yes"));
}

// --- containsExact (case-sensitive) tests ---

static assert(containsExact("LICENSE", "LICENSE"));
static assert(!containsExact("Licenses & certifications", "LICENSE"));
static assert(containsExact("the LICENSE file", "LICENSE"));
static assert(!containsExact("license", "LICENSE"));
static assert(containsExact("README.md", "README.md"));
static assert(!containsExact("readme.md", "README.md"));

// --- Wildcard matching tests ---

unittest {
    // No wildcard — behaves like contains
    assert(wildcardContains("can you check the log", "check the log"));
    assert(!wildcardContains("check something", "check the log"));
}

unittest {
    // Wildcard matches gap between segments
    assert(wildcardContains("Can you check the server log for errors", "check the*log"));
    assert(wildcardContains("check the full error log", "check the*log"));
    assert(wildcardContains("check the log", "check the*log")); // zero-gap
}

unittest {
    // Case insensitive
    assert(wildcardContains("Check The Server Log", "check the*log"));
}

unittest {
    // Wildcard does NOT match when segments are out of order
    assert(!wildcardContains("log check the errors", "check the*log"));
}

unittest {
    // "check the*logs" matches plural too
    assert(wildcardContains("Can you check the server logs?", "check the*log"));
}

unittest {
    // Multiple wildcards
    assert(wildcardContains("check the server log for errors", "check*log*error"));
    assert(!wildcardContains("check the server for errors", "check*log*error"));
}
