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
    control("issue-list", cmd("gh issue list"),
        msg("")),
    control("issue-view", cmd("gh issue view"),
        msg("")),
    control("pr-list", cmd("gh pr list"),
        msg("")),
    control("pr-view", cmd("gh pr view"),
        msg("")),
    control("pr-ready", cmd("gh pr ready"),
        msg("This means the pr is ready to merge")),
];

static immutable checkpoints = [
    control("git-commit", cmd("git commit"),
        msg("Commit requires manual approval")),
    control("git-push-pull-first", cmd("git push"),
        msg("If you haven't pulled since the last commit, pull first and resolve conflicts before pushing")),
    control("git-tag-semver", cmd("git tag"),
        msg("Check the latest tag first and ensure the new version follows semver")),
    control("pr-create", cmd("gh pr create"),
        msg("PR creation requires manual approval")),
    control("pr-edit-ref-reminder", cmd("gh pr edit"),
        msg("Reference any docs edited or created in this PR")),
    control("git-checkout-b", cmd("git checkout -b"),
        msg("Check main for unpushed commits and push them first. Update documentation to describe intended behavior. Ask critical design questions. Then open a PR.")),
    control("pr-merge-checkout-main", cmd("gh pr merge"),
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
    control("plugin-install", filepath("/qntx-plugins/"),
        msg("The user prefers not having to run make <plugin-name>-plugin every time you finish working on one, do it for them.")),
    control("web-testing-docs", filepath(".test.ts"),
        msg("Read web/TESTING.md before writing or editing tests. CI uses USE_JSDOM=1. .dom.test.ts files use JSDOM skip pattern. happy-dom is the local default.")),
];

static immutable universalPreCompact = [
    control("branch-context", precompact(),
        msg("Current branch: "), cmd("git branch --show-current")),
];

static immutable qntxPreCompact = [
    control("qntx-am-toml", precompact(),
        msg("am.toml in the project root has the db path and node configuration. Check it before assuming database locations.")),
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

static immutable preCompactScopes = [
    Scope("", "allow", universalPreCompact),
    Scope("/QNTX", "allow", qntxPreCompact),
];
