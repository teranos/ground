module controls;

public import hooks;

static if (__traits(compiles, { import qntx; }))
    import qntx;

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

static immutable universalPreCompact = [
    control("branch-context", precompact(),
        msg("Current branch: "), cmd("git branch --show-current")),
];

static immutable graunde = [
    control("install-after-test", cmd("dub test"), bg(),
        msg("If tests pass, run make install to update the live hook binary.")),
];

// TODO: stale binary correction on Stop — detect when installed binary doesn't match compiled version
// TODO: catch hardcoded URLs in error messages that claim to report runtime values
// TODO: catch entity IDs used as subjects — IDs belong in attributes, not subjects
// TODO: ego-death — confident claims about niche/untrained topics trigger grace and humility
// TODO: userprompt() trigger — move keyword controls from userprompt.d into controls/
// TODO: stop() trigger for inline Stop controls (ego-death, QNTX-scoped) — move from stop.d into controls/

static immutable allScopes = () {
    auto base = [
        Scope("", "allow", universal),
        Scope("", "ask", checkpoints),
        Scope("/graunde", "allow", graunde),
    ];
    static if (__traits(compiles, qntx.commands))
        return base ~ [Scope("/QNTX", "allow", qntx.commands)];
    else
        return base;
}();

static immutable fileScopes = () {
    static if (__traits(compiles, qntx.files))
        return [Scope("/QNTX", "allow", qntx.files)];
    else
        return cast(immutable(Scope)[])[];
}();

static immutable preCompactScopes = () {
    auto base = [Scope("", "allow", universalPreCompact)];
    static if (__traits(compiles, qntx.compaction))
        return base ~ [Scope("/QNTX", "allow", qntx.compaction)];
    else
        return base;
}();
