module controls;

public import hooks;

static immutable universal = [
    control("no-skip-hooks", cmd("git"), omit("--no-verify"),
        msg("Git hooks must not be bypassed, ever..")),
    control("short-commit-message-reminder", cmd("git add"),
        msg("A commit typically follows. Start thinking about the commit message — focus on why, not what.")),
    control("sync-main", cmd("git checkout main"),
        msg("Summarize what happened upstream since the last pull.")),
    control("ci-check", cmd("gh run list"),
        msg("Examine the result and report whether CI passed or failed.")),
    control("ci-view", cmd("gh run view"),
        msg("")),
    control("ci-watch", cmd("gh run watch"),
        msg("")),
];

static immutable checkpoints = [
    control("commit-checkpoint", cmd("git commit"),
        msg("Commit requires manual approval")),
    control("push-checkpoint", cmd("git push"),
        msg("If you haven't pulled since the last commit, pull first and resolve conflicts before pushing")),
    control("tag-checkpoint", cmd("git tag"),
        msg("Check the latest tag first and ensure the new version follows semver")),
    control("pr-checkpoint", cmd("gh pr create"),
        msg("PR creation requires manual approval")),
    control("pr-edit-checkpoint", cmd("gh pr edit"),
        msg("Reference any docs edited or created in this PR")),
    control("branch-checkpoint", cmd("git checkout -b"),
        msg("Check main for unpushed commits and push them first. Update documentation to describe intended behavior. Ask critical design questions. Then open a PR.")),
    control("merge-checkpoint", cmd("gh pr merge"),
        msg("After merge, checkout main and pull to sync local.")),
];

static immutable qntx = [
    control("go-test-args", cmd("go test"), arg(`-tags "rustsqlite,qntxwasm" -short`),
        msg("Build tags and -short are required for go test in QNTX")),
];

// TODO: nix flake reminder — editing CI that touches a flake should prompt to check the flake
// TODO: version bump awareness — per-package in monorepos, needs to know which packages were touched

static immutable qntxFiles = [
    control("web-docs-reminder", filepath("/web/"),
        msg("Read web/CLAUDE.md before editing frontend files.")),
    control("web-ts-banned", filepath("/web/ts/"),
        msg("BANNED in frontend: alert(), confirm(), prompt(), toast(). Button component has built-in error handling (throw from onClick). Check component APIs before implementing.")),
];

static immutable graunde = [
    control("install-after-test", cmd("dub test"), bg(),
        msg("If tests pass, run make install to update the live hook binary.")),
];

// TODO: stale binary correction on Stop — detect when installed binary doesn't match compiled version
// TODO: catch hardcoded URLs in error messages that claim to report runtime values
// TODO: catch entity IDs used as subjects — IDs belong in attributes, not subjects
// TODO: ego-death — confident claims about niche/untrained topics trigger grace and humility

static immutable allScopes = [
    Scope("", "allow", universal),
    Scope("", "ask", checkpoints),
    Scope("/graunde", "allow", graunde),
    Scope("/QNTX", "allow", qntx),
];

static immutable fileScopes = [
    Scope("/QNTX", "allow", qntxFiles),
];
