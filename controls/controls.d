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
    control("use-read-not-cat", cmd("cat"),
        msg("Use the Read tool instead of cat.")),
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

static immutable stopControls = [
    control("lazy-verify", stop("Ready for you to verify"),
        msg("Do not ask the user to verify what you can verify yourself. Use your tools to verify as much as possible first. Only flag things that genuinely require human judgment or manual interaction.")),
    control("ego-death-effective-fix", stop("The most effective fix is"),
        msg("You made a strong claim — according to whom? Ground it in verification or real facts.")),
    control("ego-death-feeling-probably", stop("feeling is probably"),
        msg("Do not attribute subjective impressions to the user. They observe and report facts. Restate based on what was actually measured or said.")),
    control("ego-death-likely-because", stop("likely because"),
        msg("That's a guess, not a diagnosis. Check the data before proposing a cause.")),
    control("ego-death-nothing-left", stop("Nothing left to do"),
        msg("You made a completeness claim. What specifically was not verified?")),
];

static immutable qntxStopControls = [
    control("make-dev-includes-wasm", stop("make wasm"),
        msg(`"make dev" also rebuilds the wasm, see the Makefile.`)),
    control("no-stale-binary-speculation-might", stop("binary might be stale"),
        msg("The developer is always running the latest version. Do not speculate about stale binaries.")),
    control("no-stale-binary-speculation-may", stop("binary may be stale"),
        msg("The developer is always running the latest version. Do not speculate about stale binaries.")),
    control("port-check-am-toml-877", stop("port 877"),
        msg("You mentioned a default port. Check am.toml in the project root for the actual port configuration.")),
    control("port-check-am-toml-8820", stop("8820"),
        msg("You mentioned a default port. Check am.toml in the project root for the actual port configuration.")),
];

static immutable sessionStartControls = [
    control("stale-binary-shadow", sessionstart(&binaryShadowed),
        msg("/usr/local/bin/graunde exists and shadows ~/.local/bin/graunde — remove it with: rm /usr/local/bin/graunde")),
    control("stale-controls", sessionstart(&controlsAreStale),
        msg("graunde binary is out of date with source — recompile with dub test && make install")),
];

static immutable qntxSessionStartControls = [
    control("am-toml-reminder", sessionstart(),
        msg("am.toml in the project root has the db path and node configuration. Check it before assuming database locations.")),
];

// TODO: catch hardcoded URLs in error messages that claim to report runtime values
// TODO: catch entity IDs used as subjects — IDs belong in attributes, not subjects

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

static immutable stopScopes = () {
    return [
        Scope("", "allow", stopControls),
        Scope("/QNTX", "allow", qntxStopControls),
    ];
}();

static immutable sessionStartScopes = () {
    return [
        Scope("", "allow", sessionStartControls),
        Scope("/QNTX", "allow", qntxSessionStartControls),
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

// --- Check functions for sessionstart() controls ---

extern (C) int access(const(char)* path, int mode);
import core.stdc.stdio : FILE, fopen, fread, fclose;

bool binaryShadowed(const(char)[] cwd) {
    enum F_OK = 0;
    return access("/usr/local/bin/graunde\0".ptr, F_OK) == 0;
}

uint fnv1a(const(char)[] data) {
    uint h = 2166136261;
    foreach (b; data) { h ^= b; h *= 16777619; }
    return h;
}

enum CONTROLS_HASH = fnv1a(import("controls/controls.d") ~ import("source/hooks.d"));

bool controlsAreStale(const(char)[] cwd) {
    if (cwd is null || cwd.length == 0) return false;

    __gshared char[4096] pathBuf;
    __gshared char[131072] concat;
    size_t total = 0;

    static foreach (suffix; ["/controls/controls.d", "/source/hooks.d"]) {{
        if (cwd.length + suffix.length + 1 > pathBuf.length) return false;
        foreach (j, c; cwd) pathBuf[j] = c;
        foreach (j, c; suffix) pathBuf[cwd.length + j] = c;
        pathBuf[cwd.length + suffix.length] = 0;

        auto f = fopen(&pathBuf[0], "r");
        if (f is null) return false;
        auto n = fread(&concat[total], 1, concat.length - total, f);
        fclose(f);
        if (n == 0) return false;
        total += n;
    }}

    return fnv1a(concat[0 .. total]) != CONTROLS_HASH;
}
