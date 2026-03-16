module controls;

public import hooks;

static if (__traits(compiles, { import qntx; }))
    import qntx;

version (OSX)
    import macos;

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

static immutable postToolUse = [
    control("tag-push-reminder", cmd("git tag"),
        msg("Push the tag: git push origin <tag>")),
];

static immutable universalPreCompact = [
    control("branch-context", precompact(),
        msg("Current branch: "), cmd("git branch --show-current")),
];

static immutable graunde = [
    control("install-after-build", cmd("dub build"), bg(),
        msg("Run make install to update the live hook binary.")),
];

static immutable userPromptControls = [
    control("ax-reminder", userprompt("ax"),
        msg("AX — attestation query, a natural-language-like syntax (Tim is tester of QNTX by attestor)")),
    control("timer-reminder", userprompt("timer for"),
        msg("You can set a timer on macOS. Run in background: sleep <seconds> && say \"time\" &")),
    control("adr-reminder", userprompt("ADR"),
        msg("ADRs are in docs/adr/ in the QNTX repo")),
];

static immutable graundeExcludedPromptControls = [
    control("graunde-reminder", userprompt("graunde"),
        msg("Graunde — a hook that fires on every hook event, tracks what happened in this session. Can rewrite PreToolUse hooks on the fly, nudges Claude Code into the right direction; https://github.com/teranos/graunde/tree/main")),
];

static immutable qntxExcludedPromptControls = [
    control("qntx-reminder", userprompt("qntx"),
        msg("QNTX — Continuous Intelligence. Domain-agnostic knowledge system built on verifiable attestations (who said what, when, in what context). Core: Attestation Type System (ATS). Query with AX. Graunde shares its node db; https://github.com/teranos/QNTX")),
];

// TODO: stale binary correction on Stop — detect when installed binary doesn't match compiled version
// TODO: catch hardcoded URLs in error messages that claim to report runtime values
// TODO: catch entity IDs used as subjects — IDs belong in attributes, not subjects
// TODO: ego-death — confident claims about niche/untrained topics trigger grace and humility
// TODO: stop() trigger for inline Stop controls (ego-death, QNTX-scoped) — move from stop.d into controls/

static immutable allScopes = () {
    auto base = [
        Scope("", "allow", universal),
        Scope("", "ask", checkpoints),
        Scope("/graunde", "allow", graunde),
    ];
    static if (__traits(compiles, macos.commands))
        base = base ~ [Scope("/graunde", "deny", macos.commands)];
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

static immutable userPromptScopes = () {
    return [
        Scope("", "allow", userPromptControls),
        Scope("!/graunde", "allow", graundeExcludedPromptControls),
        Scope("!/QNTX", "allow", qntxExcludedPromptControls),
    ];
}();

static immutable postToolUseScopes = () {
    return [Scope("", "allow", postToolUse)];
}();

static immutable preCompactScopes = () {
    auto base = [Scope("", "allow", universalPreCompact)];
    static if (__traits(compiles, qntx.compaction))
        return base ~ [Scope("/QNTX", "allow", qntx.compaction)];
    else
        return base;
}();
